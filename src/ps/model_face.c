/* Fixed-shape YuNet FP32 runtime. Learned weights come from the existing ONNX;
 * no image threshold/face heuristic substitutes for detection. 320x180 -> pad192.
 */
#include "model_face.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>
static uint32_t u32(const uint8_t *p) {return p[0]|((uint32_t)p[1]<<8)|((uint32_t)p[2]<<16)|((uint32_t)p[3]<<24);}
static float f32(const uint8_t *p) {uint32_t v=u32(p);float f;memcpy(&f,&v,4);return f;}
static uint32_t crc32(const uint8_t *p,size_t n) {
    size_t i;unsigned j;uint32_t c=~0U;
    for(i=0;i<n;++i) {c^=p[i];for(j=0;j<8;++j)c=(c>>1)^((c&1)?0xEDB88320U:0);}
    return ~c;
}
static void desc(const ModelFace *m,uint32_t id,uint32_t *d) {
    unsigned i;for(i=0;i<24;++i)d[i]=u32(m->payload+64+(id-1)*96+i*4);
}
static uint32_t offset(const ModelFace *m,uint32_t id) {
    return id?u32(m->payload+64+(id-1)*96+16*4):0;
}
int model_face_load(ModelFace *m,const void *blob,size_t bytes) {
    const uint8_t *b=(const uint8_t *)blob;uint32_t n,i,d[24],src[24];
    if(!m)return -1;
    memset(m,0,sizeof(*m));
    if(!b || bytes<128 || bytes>MODEL_FACE_BLOB_CAPACITY || memcmp(b,"MVISY001",8) || u32(b+8)!=1 ||
        u32(b+16)!=320 || u32(b+20)!=192 || u32(b+24)!=bytes-64 || crc32(b+64,bytes-64)!=u32(b+28))return -1;
    n=u32(b+12);if(!n || n>96 || 128+(size_t)n*96>bytes)return -1;
    m->payload=b+64;m->bytes=(uint32_t)bytes-64;m->nodes=n;m->workspace_floats=u32(m->payload);
    if(m->workspace_floats<3*192*320 || m->workspace_floats>MODEL_FACE_WORK_FLOATS || u32(m->payload+40)!=96)goto bad;
    for(i=0;i<9;++i) {
        uint32_t h,w,c;
        m->heads[i]=u32(m->payload+4+i*4);
        if(!m->heads[i] || m->heads[i]>n)goto bad;
        desc(m,m->heads[i],d);c=(i%3==2)?4:1;h=192U/(8U<<(i/3));w=320U/(8U<<(i/3));
        if(d[4]!=c || d[7]!=h || d[8]!=w)goto bad;
    }
    for(i=1;i<=n;++i) {
        size_t length,weights,j;desc(m,i,d);
        if(d[0]<1 || d[0]>5 || d[1]>=i || (d[0]==5 && d[2]>=i) ||
           !d[3] || !d[4] || d[3]>64 || d[4]>64 || !d[5] || !d[6] || !d[7] || !d[8] ||
           d[5]>192 || d[7]>192 || d[6]>320 || d[8]>320)goto bad;
        length=(size_t)d[4]*d[7]*d[8];
        if(length!=d[17] || d[16]+length>m->workspace_floats)goto bad;
        if(d[1]) {desc(m,d[1],src);if(src[4]!=d[3] || src[7]!=d[5] || src[8]!=d[6])goto bad;}
        else if(d[3]!=3 || d[5]!=192 || d[6]!=320)goto bad;
        if(d[0]==1) {
            if((d[9]!=1 && d[9]!=3) || (d[10]!=1 && d[10]!=2) || d[11]>1 || !d[12] ||
               d[3]%d[12] || d[4]%d[12] || d[7]!=(d[5]+2*d[11]-d[9])/d[10]+1 ||
               d[8]!=(d[6]+2*d[11]-d[9])/d[10]+1)goto bad;
            weights=(size_t)d[4]*(d[3]/d[12])*d[9]*d[9];
            if(d[14]<64+n*96 || d[15]<64+n*96 || d[14]+weights*4>m->bytes || d[15]+d[4]*4>m->bytes)goto bad;
            for(j=0;j<weights;++j)if(!isfinite(f32(m->payload+d[14]+j*4)))goto bad;
            for(j=0;j<d[4];++j)if(!isfinite(f32(m->payload+d[15]+j*4)))goto bad;
        }
    }
    return 0;
bad:memset(m,0,sizeof(*m));return -1;
}
static void conv(const float *in,float *out,const uint8_t *weights,const uint8_t *bias,const uint32_t *d) {
    int ci=(int)d[3],co=(int)d[4],ih=(int)d[5],iw=(int)d[6],oh=(int)d[7],ow=(int)d[8];
    int k=(int)d[9],s=(int)d[10],pad=(int)d[11],group=(int)d[12];
    int oc,ic,ky,kx,y,x,iy,dx,begin,end;size_t j,plane=(size_t)oh*ow;
    for(oc=0;oc<co;++oc) {
        float *dst=out+(size_t)oc*plane;float b=f32(bias+oc*4);
        for(j=0;j<plane;++j)dst[j]=b;
        for(ic=0;ic<ci/group;++ic) for(ky=0;ky<k;++ky) for(kx=0;kx<k;++kx) {
            int channel=(oc/(co/group))*(ci/group)+ic;
            float a=f32(weights+4*((((size_t)oc*(ci/group)+ic)*k+ky)*k+kx));
            dx=kx-pad;begin=dx<0?(-dx+s-1)/s:0;end=(iw-1-dx)/s+1;if(end>ow)end=ow;
            for(y=0;y<oh;++y) {
                const float *src;float *row;
                iy=y*s+ky-pad;if(iy<0 || iy>=ih)continue;
                src=in+((size_t)channel*ih+iy)*iw;row=dst+(size_t)y*ow;
                for(x=begin;x<end;++x)row[x]+=a*src[x*s+dx];
            }
        }
    }
}
static int forward(const ModelFace *m,const uint16_t *image,float *work,size_t capacity) {
    uint32_t i,c,y,x,d[24];
    if(!m || !m->payload || !image || !work || capacity<m->workspace_floats)return -1;
    memset(work,0,3*192*320*sizeof(float));
    for(y=0;y<180;++y)for(x=0;x<320;++x) {
        uint16_t p=image[y*320+x];unsigned r=p>>11,g=(p>>5)&63,b=p&31;
        work[y*320+x]=(float)((b<<3)|(b>>2));
        work[192*320+y*320+x]=(float)((g<<2)|(g>>4));
        work[2*192*320+y*320+x]=(float)((r<<3)|(r>>2));
    }
    for(i=1;i<=m->nodes;++i) {
        float *out;const float *in;desc(m,i,d);out=work+d[16];in=work+offset(m,d[1]);
        if(d[0]==1)conv(in,out,m->payload+d[14],m->payload+d[15],d);
        else if(d[0]==2)for(x=0;x<d[17];++x)out[x]=in[x]>0?in[x]:0;
        else if(d[0]==3)for(c=0;c<d[4];++c)for(y=0;y<d[7];++y)for(x=0;x<d[8];++x) {
            size_t p=((size_t)c*d[5]+2*y)*d[6]+2*x;
            float best=fmaxf(in[p],in[p+1]);best=fmaxf(best,in[p+d[6]]);best=fmaxf(best,in[p+d[6]+1]);
            out[((size_t)c*d[7]+y)*d[8]+x]=best;
        }
        else if(d[0]==4)for(c=0;c<d[4];++c)for(y=0;y<d[7];++y)for(x=0;x<d[8];++x)
            out[((size_t)c*d[7]+y)*d[8]+x]=in[((size_t)c*d[5]+y/2)*d[6]+x/2];
        else {const float *other=work+offset(m,d[2]);for(x=0;x<d[17];++x)out[x]=in[x]+other[x];}
    }
    return 0;
}
static float sigmoid(float a) {float e=expf(-fabsf(a));return a>=0?1/(1+e):e/(1+e);}
int model_face_debug_heads(const ModelFace *m,const float *work,float *values,size_t capacity) {
    unsigned level,i,k,at=0;
    if(!m || !m->payload || !work || !values || capacity<1260*6)return -1;
    for(level=0;level<3;++level) {
        unsigned size=(192U/(8U<<level))*(320U/(8U<<level));
        const float *cls=work+offset(m,m->heads[level*3]);
        const float *obj=work+offset(m,m->heads[level*3+1]);
        const float *box=work+offset(m,m->heads[level*3+2]);
        for(i=0;i<size;++i) {
            values[at++]=sigmoid(cls[i]);values[at++]=sigmoid(obj[i]);
            for(k=0;k<4;++k)values[at++]=box[k*size+i];
        }
    }
    return (int)at;
}
float model_face_iou(const ModelFaceBox *a,const ModelFaceBox *b) {
    float x=fmaxf(0,fminf(a->x+a->w,b->x+b->w)-fmaxf(a->x,b->x));
    float y=fmaxf(0,fminf(a->y+a->h,b->y+b->h)-fmaxf(a->y,b->y));
    float u=a->w*a->h+b->w*b->h-x*y;return u>0?x*y/u:0;
}
static int order(const void *a,const void *b) {
    float x=((const ModelFaceBox*)a)->score,y=((const ModelFaceBox*)b)->score;
    return x>y?-1:x<y?1:0;
}
int model_face_detect(const ModelFace *m,const uint16_t *image,float *work,size_t capacity,
    ModelFaceBox *boxes,size_t max_boxes) {
    /* Single invocation at a time, matching the CPU0 application. */
    static ModelFaceBox candidates[MODEL_FACE_MAX_CANDIDATES],kept[MODEL_FACE_MAX_CANDIDATES];
    unsigned level,i,j,total=0,nkept=0,n=0;int result;
    if(!boxes || !max_boxes)return -1;
    result=forward(m,image,work,capacity);if(result)return result;
    for(level=0;level<3;++level) {
        unsigned stride=8U<<level,w=320/stride,h=192/stride,size=w*h;
        const float *cls=work+offset(m,m->heads[level*3]);
        const float *obj=work+offset(m,m->heads[level*3+1]);
        const float *bb=work+offset(m,m->heads[level*3+2]);
        for(i=0;i<size;++i) {
            float score=sqrtf(sigmoid(cls[i])*sigmoid(obj[i])),cw,ch,cx,cy;
            ModelFaceBox *b;if(score<0.8f)continue;
            cw=expf(bb[2*size+i])*stride;ch=expf(bb[3*size+i])*stride;
            cx=((float)(i%w)+bb[i])*stride;cy=((float)(i/w)+bb[size+i])*stride;
            if(!isfinite(cw) || !isfinite(ch) || !isfinite(cx) || !isfinite(cy) || cw<=0 || ch<=0)continue;
            b=&candidates[total++];b->x=cx-cw/2;b->y=cy-ch/2;b->w=cw;b->h=ch;b->score=score;
        }
    }
    qsort(candidates,total,sizeof(candidates[0]),order);
    for(i=0;i<total;++i) {
        int suppress=0;ModelFaceBox a=candidates[i];
        for(j=0;j<nkept;++j) {
            ModelFaceBox x=a,y=kept[j];
            /* OpenCV YuNet NMS uses integer rectangles. */
            x.x=(float)(int)x.x;x.y=(float)(int)x.y;x.w=(float)(int)x.w;x.h=(float)(int)x.h;
            y.x=(float)(int)y.x;y.y=(float)(int)y.y;y.w=(float)(int)y.w;y.h=(float)(int)y.h;
            if(model_face_iou(&x,&y)>0.3f) {suppress=1;break;}
        }
        if(suppress)continue;
        kept[nkept++]=a;
        if(n<max_boxes) {
            float right=fminf(320,a.x+a.w),bottom=fminf(180,a.y+a.h);
            a.x=fmaxf(0,a.x);a.y=fmaxf(0,a.y);a.w=right-a.x;a.h=bottom-a.y;
            if(a.w>=16 && a.h>=16)boxes[n++]=a;
        }
    }
    return (int)n;
}
int model_face_track(ModelFaceTrack *t,const ModelFaceBox *boxes,int count) {
    int i,best=-1;float best_iou=.25f,best_value=-1;
    if(!t)return -1;
    if(t->active)for(i=0;i<count;++i) {
        float value=model_face_iou(&t->box,&boxes[i]);
        if(value>best_iou) {best=i;best_iou=value;}
    }
    if(best<0) {
        for(i=0;i<count;++i) {
            float dx=(boxes[i].x+boxes[i].w/2-160)/320,dy=(boxes[i].y+boxes[i].h/2-90)/180;
            float v=boxes[i].w*boxes[i].h/(1+4*(dx*dx+dy*dy));
            if(v>best_value) {best=i;best_value=v;}
        }
        if(best>=0 || t->active)++t->generation;
    }
    t->active=best>=0;if(best>=0)t->box=boxes[best];return best;
}
static unsigned gray(uint16_t p) {
    unsigned r=p>>11,g=(p>>5)&63,b=p&31;
    r=(r<<3)|(r>>2);g=(g<<2)|(g>>4);b=(b<<3)|(b>>2);
    return (4899*r+9617*g+1868*b+8192)>>14;
}
void model_face_crop(const uint16_t *image,const ModelFaceBox *box,uint8_t *out) {
    int x,y,x1=(int)box->x,y1=(int)box->y,x2=(int)(box->x+box->w),y2=(int)(box->y+box->h);
    if(x1<0)x1=0;
    if(y1<0)y1=0;
    if(x2>320)x2=320;
    if(y2>180)y2=180;
    if(x2<=x1 || y2<=y1) {memset(out,0,112*112);return;}
    for(y=0;y<112;++y)for(x=0;x<112;++x) {
        float sx=(x+.5f)*(x2-x1)/112-.5f,sy=(y+.5f)*(y2-y1)/112-.5f;
        int ix=(int)floorf(sx),iy=(int)floorf(sy),jx,jy;
        float dx=sx-ix,dy=sy-iy,v;
        jx=ix+1;jy=iy+1;
        if(ix<0)ix=0;
        if(iy<0)iy=0;
        if(jx>=x2-x1)jx=x2-x1-1;
        if(jy>=y2-y1)jy=y2-y1-1;
        v=(1-dy)*((1-dx)*gray(image[(y1+iy)*320+x1+ix])+dx*gray(image[(y1+iy)*320+x1+jx]))+
          dy*((1-dx)*gray(image[(y1+jy)*320+x1+ix])+dx*gray(image[(y1+jy)*320+x1+jx]));
        out[y*112+x]=(uint8_t)(v+.5f);
    }
}
