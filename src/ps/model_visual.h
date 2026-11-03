#ifndef MODEL_VISUAL_H
#define MODEL_VISUAL_H
#include <stddef.h>
#include <stdint.h>

#define MODEL_MAX_FRAMES 32U
#define MODEL_WEIGHT_FLOATS 545282U
#define MODEL_HEADER_BYTES 64U
#define MODEL_WEIGHTS_CAPACITY (MODEL_HEADER_BYTES+4U*MODEL_WEIGHT_FLOATS)
#define MODEL_FRAMES_CAPACITY (MODEL_HEADER_BYTES+MODEL_MAX_FRAMES*112U*112U)
#define MODEL_REFERENCE_CAPACITY (MODEL_HEADER_BYTES+8U+MODEL_MAX_FRAMES*131U*4U)
#define MODEL_MAX_WORKSPACE_FLOATS (3U*MODEL_MAX_FRAMES*32U*56U*56U)

enum { MODEL_OK=0, MODEL_BAD_FORMAT=-1, MODEL_BAD_CRC=-2,
       MODEL_NO_SPACE=-3, MODEL_NOT_FINITE=-4, MODEL_MISMATCH=-5, MODEL_BAD_TIMER=-6 };
typedef struct {
    const uint8_t *weight[15], *scale[15], *bias[15];
    const uint8_t *head_weight, *head_bias;
    uint32_t crc;
} ModelVisual;
typedef struct { const uint8_t *pixels; uint32_t count,crc; } ModelFrames;
typedef struct { const uint8_t *data; uint32_t count,weights_crc,frames_crc; } ModelReference;
typedef struct {
    float embeddings[MODEL_MAX_FRAMES*128U];
    float logits[MODEL_MAX_FRAMES*2U];
    float scores[MODEL_MAX_FRAMES];
} ModelPrediction;

/* blobs must be 4-byte aligned, little endian, and remain alive during inference. */
int model_visual_load(ModelVisual *model,const void *blob,size_t bytes);
int model_frames_load(ModelFrames *frames,const void *blob,size_t bytes);
int model_reference_load(ModelReference *reference,const void *blob,size_t bytes);
size_t model_visual_workspace_floats(uint32_t frames);
int model_visual_predict(const ModelVisual *model,const ModelFrames *frames,
    float *workspace,size_t workspace_floats,ModelPrediction *prediction);
int model_visual_compare(const ModelVisual *model,const ModelFrames *frames,
    const ModelPrediction *prediction,const ModelReference *reference,float tolerance,
    float *embedding_max_error,float *logit_max_error,float *score_max_error);
#endif
