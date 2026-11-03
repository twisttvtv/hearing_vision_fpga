/* Portable FP32 implementation of the official trained VISUAL branch only.
 * No Python/runtime dependency, audio, GRU, VAD or hand-written mouth threshold.
 * NCTHW layout and temporal padding match the original visual encoder.
 */
#include "model_visual.h"
#include <math.h>
#include <string.h>

static uint32_t u32le(const uint8_t *p)
{
    return (uint32_t)p[0]|((uint32_t)p[1]<<8)|((uint32_t)p[2]<<16)|((uint32_t)p[3]<<24);
}
static float f32le(const uint8_t *p)
{
    uint32_t bits=u32le(p); float value;
    memcpy(&value,&bits,4); return value;
}
static uint32_t crc32_bytes(const uint8_t *p,size_t n)
{
    uint32_t crc=0xFFFFFFFFU; size_t i; unsigned bit;
    for(i=0;i<n;++i) {
        crc^=p[i];
        for(bit=0;bit<8;++bit) crc=(crc>>1)^((crc&1U)?0xEDB88320U:0U);
    }
    return crc^0xFFFFFFFFU;
}
static int header(const void *blob,size_t bytes,const char *magic,const uint8_t **p)
{
    const uint8_t *b=(const uint8_t *)blob;
    if(!b || bytes<MODEL_HEADER_BYTES || ((uintptr_t)b&3U) || sizeof(float)!=4 ||
       memcmp(b,magic,8) || u32le(b+8)!=1U) return MODEL_BAD_FORMAT;
    if((size_t)u32le(b+24)!=bytes-MODEL_HEADER_BYTES) return MODEL_BAD_FORMAT;
    if(crc32_bytes(b+MODEL_HEADER_BYTES,bytes-MODEL_HEADER_BYTES)!=u32le(b+28)) return MODEL_BAD_CRC;
    *p=b+MODEL_HEADER_BYTES;
    return MODEL_OK;
}
int model_visual_load(ModelVisual *m,const void *blob,size_t bytes)
{
    const uint8_t *p,*b=(const uint8_t *)blob;
    const unsigned ins[3]={1,32,64},outs[3]={32,64,128};
    size_t i,offset=0; unsigned block,op,layer=0,in,out,kernel; int result;
    if(!m) return MODEL_BAD_FORMAT;
    memset(m,0,sizeof(*m));
    if(bytes!=MODEL_WEIGHTS_CAPACITY) return MODEL_BAD_FORMAT;
    result=header(blob,bytes,"MVISW001",&p); if(result) return result;
    if(u32le(b+12)!=MODEL_WEIGHT_FLOATS || u32le(b+16)!=15 || u32le(b+20)!=128) return MODEL_BAD_FORMAT;
    for(i=0;i<MODEL_WEIGHT_FLOATS;++i) if(!isfinite(f32le(p+4*i))) return MODEL_NOT_FINITE;
    for(block=0;block<3;++block) for(op=0;op<5;++op) {
        out=outs[block]; in=(op==0 || op==2)?ins[block]:out;
        kernel=op==0?9U:op==1?3U:op==2?25U:op==3?5U:1U;
        m->weight[layer]=p+4*offset; offset+=(size_t)in*out*kernel;
        m->scale[layer]=p+4*offset; offset+=out;
        m->bias[layer]=p+4*offset; offset+=out;
        ++layer;
    }
    m->head_weight=p+4*offset; offset+=256;
    m->head_bias=p+4*offset; offset+=2;
    if(offset!=MODEL_WEIGHT_FLOATS) {memset(m,0,sizeof(*m));return MODEL_BAD_FORMAT;}
    m->crc=u32le(b+28); return MODEL_OK;
}
int model_frames_load(ModelFrames *f,const void *blob,size_t bytes)
{
    const uint8_t *p,*b=(const uint8_t *)blob; uint32_t count; int result;
    if(!f) return MODEL_BAD_FORMAT;
    memset(f,0,sizeof(*f));
    if(bytes>MODEL_FRAMES_CAPACITY) return MODEL_BAD_FORMAT;
    result=header(blob,bytes,"MVISF001",&p); if(result) return result;
    count=u32le(b+12);
    if(!count || count>MODEL_MAX_FRAMES || u32le(b+16)!=112 || u32le(b+20)!=112 ||
       bytes!=MODEL_HEADER_BYTES+(size_t)count*112*112) return MODEL_BAD_FORMAT;
    f->count=count; f->pixels=p; f->crc=u32le(b+28); return MODEL_OK;
}
int model_reference_load(ModelReference *r,const void *blob,size_t bytes)
{
    const uint8_t *p,*b=(const uint8_t *)blob; uint32_t count; size_t i; int result;
    if(!r) return MODEL_BAD_FORMAT;
    memset(r,0,sizeof(*r));
    if(bytes>MODEL_REFERENCE_CAPACITY) return MODEL_BAD_FORMAT;
    result=header(blob,bytes,"MVISR001",&p); if(result) return result;
    count=u32le(b+12);
    if(!count || count>MODEL_MAX_FRAMES || u32le(b+16)!=131 || u32le(b+20)!=0 ||
       bytes!=MODEL_HEADER_BYTES+8+(size_t)count*131*4) return MODEL_BAD_FORMAT;
    for(i=0;i<(size_t)count*131;++i) if(!isfinite(f32le(p+8+i*4))) return MODEL_NOT_FINITE;
    r->weights_crc=u32le(p); r->frames_crc=u32le(p+4); r->count=count; r->data=p+8;
    return MODEL_OK;
}

/* Channel planes are contiguous: C x T x H x W. Accumulation order is
 * input-channel, kernel-time, kernel-y, kernel-x. Inner loops permit vectorization
 * without -ffast-math or a different floating-point reduction order.
 */
static void spatial(const float *input,float *output,const uint8_t *weight,
    int ci,int co,int t,int h,int w,int kernel,int stride)
{
    int oh=(h+stride-1)/stride,ow=(w+stride-1)/stride;
    int oc,ic,ky,kx,ti,y,x,iy,dy,dx,begin,end;
    size_t ip=(size_t)t*h*w,op=(size_t)t*oh*ow;
    for(oc=0;oc<co;++oc) {
        float *dst=output+(size_t)oc*op;
        memset(dst,0,op*sizeof(float));
        for(ic=0;ic<ci;++ic) for(ky=0;ky<kernel;++ky) for(kx=0;kx<kernel;++kx) {
            float a=f32le(weight+4*((((size_t)oc*ci+ic)*kernel+ky)*kernel+kx));
            dy=ky-kernel/2;dx=kx-kernel/2;
            begin=dx<0?(-dx+stride-1)/stride:0;
            end=(w-1-dx)/stride+1;if(end>ow) end=ow;
            for(ti=0;ti<t;++ti) for(y=0;y<oh;++y) {
                const float *src; float *row;
                iy=y*stride+dy;if(iy<0 || iy>=h) continue;
                src=input+(size_t)ic*ip+((size_t)ti*h+iy)*w;
                row=dst+((size_t)ti*oh+y)*ow;
                for(x=begin;x<end;++x) row[x]+=a*src[x*stride+dx];
            }
        }
    }
}
static void temporal(const float *input,float *output,const uint8_t *weight,
    int channels,int t,int h,int w,int kernel)
{
    int oc,ic,kt,ti,it; size_t i,spatial_size=(size_t)h*w,plane=(size_t)t*h*w;
    for(oc=0;oc<channels;++oc) {
        float *dst=output+(size_t)oc*plane;
        memset(dst,0,plane*sizeof(float));
        for(ic=0;ic<channels;++ic) for(kt=0;kt<kernel;++kt) {
            float a=f32le(weight+4*(((size_t)oc*channels+ic)*kernel+kt));
            for(ti=0;ti<t;++ti) {
                const float *src;float *row;
                it=ti+kt-kernel/2;if(it<0 || it>=t) continue;
                src=input+(size_t)ic*plane+(size_t)it*spatial_size;
                row=dst+(size_t)ti*spatial_size;
                for(i=0;i<spatial_size;++i) row[i]+=a*src[i];
            }
        }
    }
}
static void pointwise(const float *input,float *output,const uint8_t *weight,int channels,size_t plane)
{
    int oc,ic;size_t i;
    for(oc=0;oc<channels;++oc) {
        float *dst=output+(size_t)oc*plane;
        memset(dst,0,plane*sizeof(float));
        for(ic=0;ic<channels;++ic) {
            const float *src=input+(size_t)ic*plane;
            float a=f32le(weight+4*((size_t)oc*channels+ic));
            for(i=0;i<plane;++i) dst[i]+=a*src[i];
        }
    }
}
static void batch_relu(float *data,const ModelVisual *m,unsigned layer,int channels,size_t plane)
{
    int c;size_t i;
    for(c=0;c<channels;++c) {
        float a=f32le(m->scale[layer]+4*c),b=f32le(m->bias[layer]+4*c);
        float *p=data+(size_t)c*plane;
        for(i=0;i<plane;++i) {float v=p[i]*a+b;p[i]=v>0?v:0;}
    }
}
static void pool(const float *input,float *output,int channels,int t,int h,int w)
{
    int oh=(h+1)/2,ow=(w+1)/2,c,ti,y,x,dy,dx,iy,ix;
    for(c=0;c<channels;++c) for(ti=0;ti<t;++ti) for(y=0;y<oh;++y) for(x=0;x<ow;++x) {
        float best=-INFINITY;
        for(dy=-1;dy<=1;++dy) for(dx=-1;dx<=1;++dx) {
            float v;iy=y*2+dy;ix=x*2+dx;
            if(iy<0 || iy>=h || ix<0 || ix>=w) continue;
            v=input[(((size_t)c*t+ti)*h+iy)*w+ix];if(v>best) best=v;
        }
        output[(((size_t)c*t+ti)*oh+y)*ow+x]=best;
    }
}
size_t model_visual_workspace_floats(uint32_t frames)
{
    return frames && frames<=MODEL_MAX_FRAMES?(size_t)3*frames*32*56*56:0;
}
int model_visual_predict(const ModelVisual *m,const ModelFrames *f,
    float *work,size_t capacity,ModelPrediction *prediction)
{
    const int ins[3]={1,32,64},outs[3]={32,64,128};
    float *a,*b,*c;size_t plane,bank,i;int block,h=112,w=112,co,t,j,channel;
    if(!m || !f || !work || !prediction || !m->head_weight || !f->pixels ||
       !f->count || f->count>MODEL_MAX_FRAMES) return MODEL_BAD_FORMAT;
    if(capacity<model_visual_workspace_floats(f->count)) return MODEL_NO_SPACE;
    t=(int)f->count;bank=(size_t)t*32*56*56;a=work;b=a+bank;c=b+bank;
    for(i=0;i<(size_t)t*112*112;++i) c[i]=((float)f->pixels[i]/255.0f-0.4161f)/0.1688f;
    for(block=0;block<3;++block) {
        unsigned layer=(unsigned)block*5;
        int stride=block==0?2:1;
        co=outs[block];
        spatial(c,a,m->weight[layer],ins[block],co,t,h,w,3,stride);
        plane=(size_t)t*((h+stride-1)/stride)*((w+stride-1)/stride);
        batch_relu(a,m,layer,co,plane);
        temporal(a,b,m->weight[layer+1],co,t,(h+stride-1)/stride,(w+stride-1)/stride,3);
        batch_relu(b,m,layer+1,co,plane);
        spatial(c,a,m->weight[layer+2],ins[block],co,t,h,w,5,stride);
        batch_relu(a,m,layer+2,co,plane);
        h=(h+stride-1)/stride;w=(w+stride-1)/stride;
        temporal(a,c,m->weight[layer+3],co,t,h,w,5);
        batch_relu(c,m,layer+3,co,plane);
        for(i=0;i<(size_t)co*plane;++i) b[i]+=c[i];
        pointwise(b,a,m->weight[layer+4],co,plane);
        batch_relu(a,m,layer+4,co,plane);
        if(block<2) {pool(a,c,co,t,h,w);h=(h+1)/2;w=(w+1)/2;}
    }
    for(j=0;j<t;++j) {
        float logits[2];
        for(channel=0;channel<128;++channel) {
            float best=-INFINITY;
            const float *p=a+((size_t)channel*t+j)*h*w;
            for(i=0;i<(size_t)h*w;++i) if(p[i]>best) best=p[i];
            if(!isfinite(best)) return MODEL_NOT_FINITE;
            prediction->embeddings[j*128+channel]=best;
        }
        for(channel=0;channel<2;++channel) {
            float sum=f32le(m->head_bias+channel*4);int k;
            for(k=0;k<128;++k) sum+=prediction->embeddings[j*128+k]*f32le(m->head_weight+4*(channel*128+k));
            if(!isfinite(sum)) return MODEL_NOT_FINITE;
            logits[channel]=sum;prediction->logits[j*2+channel]=sum;
        }
        {
            float d=logits[1]-logits[0],e=expf(-fabsf(d));
            prediction->scores[j]=d>=0?1.0f/(1.0f+e):e/(1.0f+e);
        }
    }
    return MODEL_OK;
}
int model_visual_compare(const ModelVisual *m,const ModelFrames *f,const ModelPrediction *p,
    const ModelReference *r,float tolerance,float *embed_error,float *logit_error,float *score_error)
{
    uint32_t t,k;float em=0,lm=0,sm=0;
    if(!m || !f || !p || !r || !r->data || !f->count || f->count>MODEL_MAX_FRAMES ||
       !isfinite(tolerance) || tolerance<=0 ||
       f->count!=r->count || m->crc!=r->weights_crc || f->crc!=r->frames_crc) return MODEL_MISMATCH;
    for(t=0;t<f->count;++t) for(k=0;k<131;++k) {
        float expected=f32le(r->data+4*((size_t)t*131+k));
        float actual=k<128?p->embeddings[t*128+k]:k<130?p->logits[t*2+k-128]:p->scores[t];
        float difference=fabsf(actual-expected);
        if(!isfinite(actual) || !isfinite(difference)) return MODEL_NOT_FINITE;
        if(k<128) {if(difference>em) em=difference;}
        else if(k<130) {if(difference>lm) lm=difference;}
        else if(difference>sm) sm=difference;
    }
    if(embed_error) *embed_error=em;
    if(logit_error) *logit_error=lm;
    if(score_error) *score_error=sm;
    return em<=tolerance && lm<=tolerance && sm<=tolerance?MODEL_OK:MODEL_MISMATCH;
}
