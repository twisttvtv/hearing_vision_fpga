/* Live camera -> learned YuNet -> one tracked face -> actual visual Light-ASD
 * -> same-center-frame snapshot -> UART. CPU0 only; no microphone or PC inference.
 */
#include "model_live.h"
#include "model_visual.h"
#include "model_face.h"
#include <math.h>
#include <string.h>
#ifndef MODEL_LIVE_SEND_ALL
#define MODEL_LIVE_SEND_ALL 0
#endif
#ifndef MODEL_CAMERA_PREVIEW
#define MODEL_CAMERA_PREVIEW 0
#endif
#ifndef MODEL_LIVE_BARRIER
#define MODEL_LIVE_BARRIER() __asm__ volatile("dmb sy" ::: "memory")
#endif
#define PIXELS (320U*180U)
#define CLOCK_HZ 100000000U
static ModelVisual visual;
static ModelFace detector;
static ModelFaceTrack track;
static ModelPrediction prediction;
static float visual_work[3U*MODEL_LIVE_FRAMES*32U*56U*56U] __attribute__((aligned(64)));
static float face_work[700000] __attribute__((aligned(64)));
static uint8_t face_sequence[MODEL_LIVE_FRAMES*112U*112U] __attribute__((aligned(64)));
static uint16_t center_image[PIXELS],tx_image[PIXELS];
static ModelFaceBox center_box;
static uint32_t center_sequence,center_track,have_last,initialized;
static uint64_t center_ticks;
static uint8_t tx_header[64],tx_trailer[4];
static uint32_t tx_position=MODEL_LIVE_PACKET_BYTES;
ModelLiveStats model_live_state;
static uint64_t (*live_clock)(void);
void model_live_set_clock(uint64_t (*clock)(void)) {live_clock=clock;}
static uint64_t live_ticks(void) {return live_clock ? live_clock() : 0;}
void model_live_begin_window(void) {
    model_live_state.pending_frames=0;have_last=0;track.active=0;++track.generation;
}
int model_live_tx_pending(void) {return initialized && tx_position<MODEL_LIVE_PACKET_BYTES;}
static void put16(uint8_t *p,uint16_t v) {p[0]=(uint8_t)v;p[1]=(uint8_t)(v>>8);}
static void put32(uint8_t *p,uint32_t v) {put16(p,(uint16_t)v);put16(p+2,(uint16_t)(v>>16));}
static void put64(uint8_t *p,uint64_t v) {put32(p,(uint32_t)v);put32(p+4,(uint32_t)(v>>32));}
static uint32_t crc_byte(uint32_t c,uint8_t b) {unsigned j;c^=b;for(j=0;j<8;++j)c=(c>>1)^((c&1)?0xEDB88320U:0);return c;}
static int queue_image(const uint16_t *image,uint32_t sequence,uint64_t ticks,
                       const ModelFaceBox *box,uint32_t track_id,float score,uint32_t flags) {
    uint32_t crc=~0U,i,bits;
    if(tx_position<MODEL_LIVE_PACKET_BYTES) {++model_live_state.snapshots_skipped;return 0;}
    memcpy(tx_image,image,sizeof(tx_image));memset(tx_header,0,sizeof(tx_header));
    memcpy(tx_header,"MLIVE001",8);tx_header[8]=1;tx_header[9]=1;put16(tx_header+10,64);
    put16(tx_header+12,320);put16(tx_header+14,180);put32(tx_header+16,PIXELS*2);
    put32(tx_header+20,sequence);put64(tx_header+24,ticks);
    memcpy(&bits,&score,4);put32(tx_header+32,bits);
    if(box) {
        put16(tx_header+36,(uint16_t)box->x);put16(tx_header+38,(uint16_t)box->y);
        put16(tx_header+40,(uint16_t)box->w);put16(tx_header+42,(uint16_t)box->h);
    }
    put32(tx_header+44,track_id);put32(tx_header+48,flags);put32(tx_header+52,CLOCK_HZ);
    for(i=0;i<60;++i)crc=crc_byte(crc,tx_header[i]);
    put32(tx_header+60,~crc);
    crc=~0U;
    for(i=0;i<PIXELS;++i) {crc=crc_byte(crc,(uint8_t)tx_image[i]);crc=crc_byte(crc,(uint8_t)(tx_image[i]>>8));}
    put32(tx_trailer,~crc);tx_position=0;++model_live_state.snapshots_queued;return 1;
}
int model_live_preview(const uint16_t *image,uint32_t sequence,uint64_t ticks) {
    if(!initialized || !image)return MODEL_BAD_FORMAT;
    return queue_image(image,sequence,ticks,NULL,0,0.f,2U);
}
static void queue_snapshot(float score) {
    (void)queue_image(center_image,center_sequence,center_ticks,&center_box,center_track,
                      score,score>=.5f ? 1U : 0U);
}
int model_live_init(const void *w,size_t wb,const void *f,size_t fb) {
    int result;initialized=0;memset(&model_live_state,0,sizeof(model_live_state));
    memset(&track,0,sizeof(track));have_last=0;tx_position=MODEL_LIVE_PACKET_BYTES;
    result=model_visual_load(&visual,w,wb);if(result)return result;
    result=model_face_load(&detector,f,fb);if(result)return result;
    if(detector.workspace_floats>sizeof(face_work)/sizeof(float))return MODEL_NO_SPACE;
    initialized=1;return 0;
}
int model_live_push(const uint16_t *image,uint32_t sequence,uint64_t ticks) {
    ModelFaceBox boxes[32];ModelFrames frames;uint32_t generation,index;int count,chosen,result;
    uint64_t started;
    if(!initialized || !image)return MODEL_BAD_FORMAT;
    if(have_last && (sequence!=model_live_state.last_sequence+1U || ticks<=model_live_state.last_ticks ||
                    ticks-model_live_state.last_ticks>CLOCK_HZ/10U)) {
        model_live_state.pending_frames=0;track.active=0;++track.generation;++model_live_state.incomplete_resets;
    }
    have_last=1;model_live_state.last_sequence=sequence;model_live_state.last_ticks=ticks;++model_live_state.frames_seen;
    started=live_ticks();
    count=model_face_detect(&detector,image,face_work,sizeof(face_work)/sizeof(float),boxes,32);
    model_live_state.face_ticks+=live_ticks()-started;
    if(count<0)return MODEL_BAD_FORMAT;
    generation=track.generation;chosen=model_face_track(&track,boxes,count);
    if(chosen<0) {model_live_state.pending_frames=0;++model_live_state.no_face;return 0;}
    if(track.generation!=generation) {model_live_state.pending_frames=0;++model_live_state.track_changes;}
    index=model_live_state.pending_frames;
    model_face_crop(image,&track.box,face_sequence+index*112*112);
    if(index==MODEL_LIVE_FRAMES/2) {
        memcpy(center_image,image,sizeof(center_image));center_box=track.box;
        center_sequence=sequence;center_ticks=ticks;center_track=track.generation;
    }
    if(++model_live_state.pending_frames<MODEL_LIVE_FRAMES)return 0;
    frames.pixels=face_sequence;frames.count=MODEL_LIVE_FRAMES;frames.crc=0;
    started=live_ticks();
    result=model_visual_predict(&visual,&frames,visual_work,sizeof(visual_work)/sizeof(float),&prediction);
    model_live_state.visual_ticks+=live_ticks()-started;
    model_live_state.pending_frames=0;if(result)return result;
    ++model_live_state.windows;model_live_state.last_score=prediction.scores[MODEL_LIVE_FRAMES/2];
    model_live_state.last_result_sequence=center_sequence;model_live_state.last_result_ticks=center_ticks;
    model_live_state.last_result_track=center_track;
    if(MODEL_CAMERA_PREVIEW && (MODEL_LIVE_SEND_ALL || model_live_state.last_score>=.5f))queue_snapshot(model_live_state.last_score);
    return 1;
}
int model_live_tx_next(uint8_t *byte) {
    uint32_t pos;
    if(!initialized || !byte || tx_position>=MODEL_LIVE_PACKET_BYTES)return 0;
    pos=tx_position++;
    if(pos<64)*byte=tx_header[pos];
    else if(pos<64+PIXELS*2) {
        uint16_t pixel=tx_image[(pos-64)/2];*byte=(pos&1)?(uint8_t)(pixel>>8):(uint8_t)pixel;
    } else *byte=tx_trailer[pos-64-PIXELS*2];
    if(tx_position==MODEL_LIVE_PACKET_BYTES)++model_live_state.tx_completed;
    return 1;
}

