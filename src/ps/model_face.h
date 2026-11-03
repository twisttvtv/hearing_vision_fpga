#ifndef MODEL_FACE_H
#define MODEL_FACE_H
#include <stddef.h>
#include <stdint.h>
#define MODEL_FACE_BLOB_CAPACITY 262144U
#define MODEL_FACE_WORK_FLOATS 2000000U
#define MODEL_FACE_MAX_CANDIDATES 1260U
typedef struct {
    const uint8_t *payload;
    uint32_t bytes,nodes,workspace_floats,heads[9];
} ModelFace;
typedef struct {float x,y,w,h,score;} ModelFaceBox;
typedef struct {ModelFaceBox box;uint32_t active,generation;} ModelFaceTrack;
int model_face_load(ModelFace *model,const void *blob,size_t bytes);
int model_face_detect(const ModelFace *model,const uint16_t *rgb565,
    float *workspace,size_t capacity,ModelFaceBox *boxes,size_t max_boxes);
/* Packs each stride's cells as cls,obj,dx,dy,dw,dh for numerical ONNX comparison. */
int model_face_debug_heads(const ModelFace *model,const float *workspace,float *values,size_t capacity);
float model_face_iou(const ModelFaceBox *a,const ModelFaceBox *b);
/* Select one persistent face, or a central large face when acquiring a new track. */
int model_face_track(ModelFaceTrack *track,const ModelFaceBox *boxes,int count);
void model_face_crop(const uint16_t *rgb565,const ModelFaceBox *box,uint8_t *gray112);
#endif
