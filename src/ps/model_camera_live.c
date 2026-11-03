/* Real mic VAD/TDOA -> servos -> consecutive camera window -> existing visual
 * network. This is rule-based coordination, NOT a learned AV fusion model.
 */
#include "model_camera_live.h"
#include "model_live.h"
#include "model_visual.h"
#include "model_face.h"
#include "xil_io.h"
#include <string.h>
#ifndef MODEL_CAMERA_BASE
#define MODEL_CAMERA_BASE 0x43C00000U
#endif
#ifndef MODEL_CAMERA_PREVIEW
#define MODEL_CAMERA_PREVIEW 0
#endif
#ifndef MODEL_CAMERA_VISUAL_ONLY
#define MODEL_CAMERA_VISUAL_ONLY 0
#endif
#ifndef MC_BARRIER
#define MC_BARRIER() __asm__ volatile("dmb sy" ::: "memory")
#endif
#define CLOCK_HZ 100000000U
#define PIXELS (320U*180U)
#define MODEL_CAMERA_VAD_MIN_FRAMES 1U
enum {IDLE=0,LOCK=1,COLLECT=2,COMPUTE=3,TRANSMIT=4,PREVIEW=5};
ModelCameraStats model_camera_state;
ModelCameraAudio model_camera_audio[MODEL_CAMERA_AUDIO_SLOTS] __attribute__((aligned(64)));
static uint16_t batch[MODEL_LIVE_FRAMES][PIXELS] __attribute__((aligned(64)));
static uint32_t sequences[MODEL_LIVE_FRAMES],window_epoch,have_audio,last_aseq,started,time_fault;
static uint64_t times[MODEL_LIVE_FRAMES],phase_start,last_time,expected_sample;
#if MODEL_CAMERA_PREVIEW
static uint32_t preview_sent,have_preview_epoch,last_preview_epoch;
static uint32_t trigger_pending,trigger_direction,window_audio_trigger;
static uint64_t trigger_ticks;
#endif
static uint32_t rd(uint32_t offset) {return Xil_In32((UINTPTR)MODEL_CAMERA_BASE+offset);}
static void wr(uint32_t offset,uint32_t value) {Xil_Out32((UINTPTR)MODEL_CAMERA_BASE+offset,value);MC_BARRIER();}
static uint64_t rd64(uint32_t offset) {
    uint32_t hi,lo,again;
    do {hi=rd(offset+4);lo=rd(offset);again=rd(offset+4);}while(hi!=again);
    return ((uint64_t)hi<<32)|lo;
}
static uint64_t clock_ticks(void) {
    uint64_t now=rd64(0x4C);
    if(started && now<last_time)time_fault=1;
    last_time=now;return now;
}
static void release(uint32_t bits) {wr(0x0C,bits);(void)rd(8);MC_BARRIER();}
static int audio_poll(void) {
    ModelCameraAudio *slot;uint32_t i,word,seq,peak=0,clipped=0;int32_t sum=0,value;
    uint64_t ticks,first,power=0;
    if(!(rd(8)&2U))return 0;
    seq=rd(0x34);ticks=rd64(0x38);first=rd64(0x40);
    slot=&model_camera_audio[model_camera_state.audio_next];slot->valid=0;
    for(i=0;i<MODEL_CAMERA_AUDIO_SAMPLES;i+=2) {
        word=rd(0x40000+2*i);slot->pcm[i]=(int16_t)(uint16_t)word;
        slot->pcm[i+1]=(int16_t)(uint16_t)(word>>16);
    }
    if(!(rd(8)&2U) || rd(0x34)!=seq || rd64(0x38)!=ticks || rd64(0x40)!=first)return -11;
    if(have_audio && (seq!=last_aseq+1U || first!=expected_sample))++model_camera_state.audio_gaps;
    for(i=0;i<MODEL_CAMERA_AUDIO_SAMPLES;++i) {
        value=slot->pcm[i];sum+=value;power+=(uint64_t)((int64_t)value*value);
        if(value==32767 || value==-32768)++clipped;
        if(value<0)value=-value;
        if((uint32_t)value>peak)peak=(uint32_t)value;
    }
    model_camera_state.audio_peak=peak;model_camera_state.audio_clipped=clipped;
    model_camera_state.audio_dc=sum/(int32_t)MODEL_CAMERA_AUDIO_SAMPLES;
    model_camera_state.audio_mean_power=power/MODEL_CAMERA_AUDIO_SAMPLES;
    slot->sequence=seq;slot->ticks=ticks;slot->first_sample=first;MC_BARRIER();slot->valid=1;
    ++model_camera_state.audio_blocks;
    model_camera_state.audio_next=(model_camera_state.audio_next+1U)%MODEL_CAMERA_AUDIO_SLOTS;
    last_aseq=seq;expected_sample=first+MODEL_CAMERA_AUDIO_SAMPLES;have_audio=1;release(2);
    return 0;
}
static void service_uart(void) {
#if MODEL_CAMERA_PREVIEW
    unsigned i;uint8_t byte;
    for(i=0;i<16;++i) {
        if(!(rd(0x60)&1U) || !model_live_tx_next(&byte))break;
        wr(0x64,byte);
    }
#endif
}
static void restart_window(void) {
    wr(0x7C,0);model_live_begin_window();model_camera_state.phase=IDLE;
    model_camera_state.acquired=0;model_camera_state.processed=0;
    model_camera_state.frame_vad_count=0;++model_camera_state.window_restarts;
}
int model_camera_start(const void *v,size_t vb,const void *f,size_t fb) {
    int result;
    started=0;time_fault=0;have_audio=0;
#if MODEL_CAMERA_PREVIEW
    preview_sent=0;have_preview_epoch=0;last_preview_epoch=0;
    trigger_pending=0;trigger_direction=0;trigger_ticks=0;window_audio_trigger=0;
#endif
    if(rd(0)!=0x4D434156U || rd(4)!=0x00030000U || rd(0x10)!=CLOCK_HZ ||
       rd(0x18)!=((180U<<16)|320U) || rd(0x1C)!=MODEL_CAMERA_AUDIO_SAMPLES || rd(0xA8)!=2048U)return -10;
#if MODEL_CAMERA_PREVIEW
    if(!(rd(0x60)&4U))return -13;
#endif
    wr(0x7C,0);
    memset(&model_camera_state,0,sizeof(model_camera_state));memset(model_camera_audio,0,sizeof(model_camera_audio));
    result=model_live_init(v,vb,f,fb);if(result)return result;
    model_live_set_clock(clock_ticks);last_time=clock_ticks();started=1;return 0;
}
int model_camera_step(void) {
    ModelCameraStats *state=&model_camera_state;
    uint32_t status,seq,i,word,epoch;uint64_t ticks,now;int result;
    if(!started)return -10;
    now=clock_ticks();if(time_fault)return -11;
    result=audio_poll();if(result)return result;
    service_uart();status=rd(0x70);
#if MODEL_CAMERA_PREVIEW
    /* Latch an already confirmed target while the servo is moving. A short
     * utterance must not be discarded just because preview transmission ends
     * after VAD releases. Never turn this latch into live VAD/evidence. */
    uint32_t current_target=(rd(0x74)>>8)&7U;
    if(state->phase==IDLE) {
        if(trigger_pending && now-trigger_ticks>(uint64_t)CLOCK_HZ*10U)trigger_pending=0;
        if((status&0x23U)==0x23U) {
            trigger_pending=1;trigger_direction=current_target;trigger_ticks=now;
        }
    } else if((state->phase==LOCK || state->phase==COLLECT || state->phase==PREVIEW) &&
              (status&0x23U)==0x23U)window_audio_trigger=1;
#endif
    switch(state->phase) {
    case IDLE:
        /* Normal mode waits for a stable microphone target; diagnostic mode
         * can check the camera at home without microphones or alerts.
         */
#if MODEL_CAMERA_PREVIEW
        /* Preview every new settled view. A confirmed recent sound target
         * starts one inference job even if speech ends before preview does. */
        if(model_live_tx_pending() || (rd(0x60)&2U) || !(status&8U))break;
        if(!MODEL_CAMERA_VISUAL_ONLY && have_preview_epoch && rd(0x78)==last_preview_epoch &&
           !(trigger_pending && trigger_direction==current_target))break;
        window_audio_trigger=trigger_pending && trigger_direction==current_target;
        if(window_audio_trigger)trigger_pending=0;
#else
        if(!MODEL_CAMERA_VISUAL_ONLY && (status&0x2BU)!=0x2BU)break;
#endif
        wr(0x7C,1);state->phase=LOCK;
        break;
    case LOCK:
#if !MODEL_CAMERA_PREVIEW
        if(!MODEL_CAMERA_VISUAL_ONLY && (status&0x23U)!=0x23U) {restart_window();break;}
#endif
        if(!(status&8U))break;
        for(i=0;i<4 && (rd(8)&1U);++i)release(1);
        if(rd(8)&1U)return -12;
        window_epoch=rd(0x78);phase_start=clock_ticks();state->acquired=0;
        state->frame_vad_count=0;model_live_begin_window();state->phase=COLLECT;
#if MODEL_CAMERA_PREVIEW
        preview_sent=0;
#endif
        break;
    case COLLECT:
        if(rd(0x78)!=window_epoch || !(status&8U)) {restart_window();break;}
        if(!(rd(8)&1U))break;
        seq=rd(0x20);ticks=rd64(0x24);epoch=rd(0x78);
        if(ticks<phase_start) {release(1);break;}
        for(i=0;i<PIXELS;i+=2) {
            word=rd(0x20000+2*i);batch[state->acquired][i]=(uint16_t)word;
            batch[state->acquired][i+1]=(uint16_t)(word>>16);
            if((i&511U)==510U) {result=audio_poll();if(result)return result;service_uart();}
        }
        if(!(rd(8)&1U) || rd(0x20)!=seq || rd64(0x24)!=ticks)return -11;
        release(1);
        if(epoch!=window_epoch || rd(0x78)!=window_epoch) {restart_window();break;}
        if(state->acquired && (seq!=sequences[state->acquired-1]+1U || ticks<=times[state->acquired-1] ||
           ticks-times[state->acquired-1]>CLOCK_HZ/10U)) {
            memcpy(batch[0],batch[state->acquired],sizeof(batch[0]));state->acquired=0;
            state->frame_vad_count=0;++state->window_restarts;
        }
        sequences[state->acquired]=seq;times[state->acquired]=ticks;
        if(rd(0x70)&1U)++state->frame_vad_count;
        ++state->acquired;
#if MODEL_CAMERA_PREVIEW
        if(!preview_sent) {state->phase=PREVIEW;break;}
#endif
        if(state->acquired==MODEL_LIVE_FRAMES) {
            now=clock_ticks();state->acquire_ticks=now-phase_start;phase_start=now;
            state->processed=0;state->phase=COMPUTE;
        }
        break;
#if MODEL_CAMERA_PREVIEW
    case PREVIEW:
        if(rd(0x78)!=window_epoch || !(status&8U)) {restart_window();break;}
        if(!preview_sent) {
            result=model_live_preview(batch[0],sequences[0],times[0]);
            if(result<0)return result;
            if(!result)break;
            preview_sent=1;have_preview_epoch=1;last_preview_epoch=window_epoch;
        }
        /* Finish the raw image before entering a blocking neural kernel. */
        if(model_live_tx_pending() || (rd(0x60)&2U))break;
        if(!MODEL_CAMERA_VISUAL_ONLY && !window_audio_trigger) {restart_window();break;}
        /* UART transmission introduces a gap. Collect a fresh consecutive
         * recognition window instead of mixing preview and later frames. */
        for(i=0;i<4 && (rd(8)&1U);++i)release(1);
        if(rd(8)&1U)return -12;
        state->acquired=0;state->frame_vad_count=0;phase_start=clock_ticks();
        state->phase=COLLECT;
        break;
#endif
    case COMPUTE:
        if(rd(0x78)!=window_epoch || !(status&8U)) {restart_window();break;}
        result=model_live_push(batch[state->processed],sequences[state->processed],times[state->processed]);
        if(result<0)return result;
        now=clock_ticks();if(time_fault)return -11;
        if(result>0) {
            state->last_result_age_ticks=now-model_live_state.last_result_ticks;
            wr(0x80,(uint32_t)(model_live_state.last_score*1000.f));wr(0x84,window_epoch);
            wr(0x88,(uint32_t)model_live_state.last_result_ticks);wr(0x8C,(uint32_t)(model_live_state.last_result_ticks>>32));
            wr(0xB0,model_live_state.last_result_sequence);
            /* VAD observed during collection is a candidate gate, not an
             * audio-network probability or exact physical AV alignment.
             */
            wr(0x7C,3U|((!MODEL_CAMERA_VISUAL_ONLY && state->frame_vad_count>=MODEL_CAMERA_VAD_MIN_FRAMES) ? 4U : 0U));
        }
        if(++state->processed==MODEL_LIVE_FRAMES) {
            state->compute_ticks=now-phase_start;++state->batches;wr(0x7C,0);state->phase=TRANSMIT;
        }
        return result;
    case TRANSMIT:
#if MODEL_CAMERA_PREVIEW
        if(model_live_tx_pending() || (rd(0x60)&2U))break;
#endif
        state->phase=IDLE;
        break;
    default:return -10;
    }
    return 0;
}

#ifndef MODEL_CAMERA_NO_MAIN
#include "xil_cache.h"
#include "xil_mmu.h"
#include "xil_printf.h"
unsigned char model_camera_visual_blob[MODEL_WEIGHTS_CAPACITY] __attribute__((aligned(64)));
unsigned char model_camera_face_blob[MODEL_FACE_BLOB_CAPACITY] __attribute__((aligned(64)));
volatile uint32_t model_camera_ready;
volatile int model_camera_status;
__attribute__((noinline)) void model_camera_wait(void) {while(!model_camera_ready)__asm__ volatile("nop");}
static size_t blob_bytes(const unsigned char *p,size_t capacity) {
    uint32_t n=(uint32_t)p[24]|((uint32_t)p[25]<<8)|((uint32_t)p[26]<<16)|((uint32_t)p[27]<<24);
    return n<=capacity-MODEL_HEADER_BYTES ? MODEL_HEADER_BYTES+(size_t)n : 0;
}
static unsigned long ms(uint64_t ticks) {return (unsigned long)(ticks/(CLOCK_HZ/1000U));}
int main(void) {
    int result;uint64_t now,last_log=0;uint32_t last_windows=0;
    Xil_DCacheDisable();Xil_ICacheEnable();
    xil_printf("MODEL_CAMERA: stop at model_camera_wait; load weights after startup.\r\n");
    xil_printf("dow -data {D:/FPGA/hearing_vision/integrate/weights/model_weights.bin} 0x%08lx\r\n",(unsigned long)(uintptr_t)model_camera_visual_blob);
    xil_printf("dow -data {D:/FPGA/hearing_vision/integrate/weights/model_face_weights.bin} 0x%08lx\r\n",(unsigned long)(uintptr_t)model_camera_face_blob);
    xil_printf("mwr 0x%08lx 1\r\ncon\r\n",(unsigned long)(uintptr_t)&model_camera_ready);
    model_camera_wait();Xil_DCacheEnable();Xil_SetTlbAttributes((INTPTR)MODEL_CAMERA_BASE,DEVICE_MEMORY);MC_BARRIER();
    result=model_camera_start(model_camera_visual_blob,blob_bytes(model_camera_visual_blob,sizeof(model_camera_visual_blob)),
        model_camera_face_blob,blob_bytes(model_camera_face_blob,sizeof(model_camera_face_blob)));
    if(result) {model_camera_status=result;xil_printf("MODEL_CAMERA: init failed %d\r\n",result);return 1;}
    model_camera_status=1;
    xil_printf("MODEL_CAMERA: mic VAD/TDOA -> servo -> visual ASD; preview=%d diagnostic=%d frames=%u vad_min=%u\r\n",MODEL_CAMERA_PREVIEW,MODEL_CAMERA_VISUAL_ONLY,(unsigned)MODEL_LIVE_FRAMES,(unsigned)MODEL_CAMERA_VAD_MIN_FRAMES);
    for(;;) {
        result=model_camera_step();
        if(result<0) {wr(0x7C,0);model_camera_status=result;xil_printf("MODEL_CAMERA stopped %d; reload ARM after PL reset\r\n",result);return 1;}
        now=clock_ticks();
        if(now-last_log>=CLOCK_HZ || last_windows!=model_live_state.windows) {
            last_log=now;last_windows=model_live_state.windows;
            xil_printf("phase=%lu mic=%lx epoch=%lu frames=%lu windows=%lu noface=%lu visual_milli=%lu result_seq=%lu age_ms=%lu alerts=%lu flags=%lx\r\n",
                (unsigned long)model_camera_state.phase,(unsigned long)rd(0x70),(unsigned long)rd(0x78),
                (unsigned long)model_live_state.frames_seen,(unsigned long)model_live_state.windows,
                (unsigned long)model_live_state.no_face,(unsigned long)(model_live_state.last_score*1000.f),
                (unsigned long)model_live_state.last_result_sequence,ms(model_camera_state.last_result_age_ticks),
                (unsigned long)rd(0xAC),(unsigned long)rd(0xB8));
            xil_printf("audio=%lu gaps=%lu drops=%lu peak=%lu dc=%ld clip=%lu acquire_ms=%lu compute_ms=%lu face_total_ms=%lu visual_total_ms=%lu\r\n",
                (unsigned long)model_camera_state.audio_blocks,(unsigned long)model_camera_state.audio_gaps,(unsigned long)rd(0x48),
                (unsigned long)model_camera_state.audio_peak,(long)model_camera_state.audio_dc,(unsigned long)model_camera_state.audio_clipped,
                ms(model_camera_state.acquire_ticks),ms(model_camera_state.compute_ticks),ms(model_live_state.face_ticks),ms(model_live_state.visual_ticks));
        }
    }
}
#endif
