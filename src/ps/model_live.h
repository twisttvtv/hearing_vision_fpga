#ifndef MODEL_LIVE_H
#define MODEL_LIVE_H
#include <stddef.h>
#include <stdint.h>
#ifndef MODEL_LIVE_FRAMES
#define MODEL_LIVE_FRAMES 10U
#endif
#if MODEL_LIVE_FRAMES < 1U || MODEL_LIVE_FRAMES > 32U
#error MODEL_LIVE_FRAMES_must_be_between_1_and_32
#endif
#define MODEL_LIVE_PACKET_BYTES (64U+320U*180U*2U+4U)
typedef struct {
    uint32_t frames_seen,windows,incomplete_resets,no_face,track_changes;
    uint32_t snapshots_queued,snapshots_skipped,tx_completed;
    uint32_t last_sequence,last_result_sequence,last_result_track;
    uint64_t last_ticks,last_result_ticks;
    float last_score;
    uint32_t pending_frames;
    uint64_t face_ticks,visual_ticks;
} ModelLiveStats;
extern ModelLiveStats model_live_state;
int model_live_init(const void *visual_weights,size_t visual_bytes,const void *face_weights,size_t face_bytes);
/* 320x180 canonical numeric RGB565; real FPGA sequence/timestamps, 100-MHz units. */
int model_live_push(const uint16_t *pixels,uint32_t sequence,uint64_t ticks);
/* Consume a byte only when the AXI UART status says ready. No more than one caller. */
int model_live_tx_next(uint8_t *byte);
void model_live_begin_window(void);
int model_live_tx_pending(void);
/* Test preview only: no face box or classification. 1 queued, 0 busy, negative error. */
int model_live_preview(const uint16_t *pixels,uint32_t sequence,uint64_t ticks);
void model_live_set_clock(uint64_t (*clock)(void));
#endif
