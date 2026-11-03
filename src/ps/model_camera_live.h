#ifndef MODEL_CAMERA_LIVE_H
#define MODEL_CAMERA_LIVE_H
#include <stddef.h>
#include <stdint.h>
#define MODEL_CAMERA_AUDIO_SAMPLES 480U
#define MODEL_CAMERA_AUDIO_SLOTS 64U
typedef struct {
    uint64_t ticks,first_sample;
    uint32_t sequence,valid;
    int16_t pcm[MODEL_CAMERA_AUDIO_SAMPLES];
} ModelCameraAudio;
typedef struct {
    uint32_t phase,acquired,processed,batches,window_restarts,frame_vad_count;
    uint32_t audio_blocks,audio_gaps,audio_next,audio_peak,audio_clipped;
    int32_t audio_dc;
    uint64_t audio_mean_power,acquire_ticks,compute_ticks,last_result_age_ticks;
} ModelCameraStats;
extern ModelCameraStats model_camera_state;
extern ModelCameraAudio model_camera_audio[MODEL_CAMERA_AUDIO_SLOTS];
int model_camera_start(const void *visual,size_t visual_bytes,const void *face,size_t face_bytes);
int model_camera_step(void);
#endif
