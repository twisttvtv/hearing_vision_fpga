"""Receive raw camera previews and board-computed speaking snapshots; no PC inference.

Default save: model_speaking.png beside this script, overwritten by each valid
positive snapshot. Decoder memory and displayed image count remain bounded.
"""
from pathlib import Path
import argparse
import math
import struct
import time
import zlib
import numpy as np
MAGIC=b'MLIVE001'
HEADER=struct.Struct('<8sBBHHHIIQfHHHHIIIII')
WIDTH=320;HEIGHT=180;PAYLOAD=WIDTH*HEIGHT*2
MAX_PACKET=64+PAYLOAD+4

class Decoder:
    def __init__(self):self.buffer=bytearray();self.bad=0
    def feed(self,data):
        if len(data)>MAX_PACKET*2:
            data=data[-MAX_PACKET*2:];self.buffer.clear();self.bad+=1
        self.buffer.extend(data);frames=[]
        while True:
            start=self.buffer.find(MAGIC)
            if start<0:
                del self.buffer[:-7];break
            if start:del self.buffer[:start]
            if len(self.buffer)<64:break
            h=HEADER.unpack_from(self.buffer)
            _,version,fmt,length,w,height,n,seq,ticks,score,x,y,bw,bh,track,flags,clock,reserved,crc=h
            valid=(version==1 and fmt==1 and length==64 and w==WIDTH and height==HEIGHT and n==PAYLOAD
                and zlib.crc32(self.buffer[:60])==crc and math.isfinite(score) and 0<=score<=1
                and clock>0 and reserved==0
                and ((flags==2 and score==0 and x==y==bw==bh==track==0)
                     or (flags in (0,1) and bw>0 and bh>0 and x+bw<=w and y+bh<=height
                         and bool(flags&1)==(score>=.5))))
            if not valid:
                del self.buffer[0];self.bad+=1;continue
            if len(self.buffer)<MAX_PACKET:break
            pixels=bytes(self.buffer[64:64+n]);expected=struct.unpack_from('<I',self.buffer,64+n)[0]
            if zlib.crc32(pixels)!=expected:
                del self.buffer[0];self.bad+=1;continue
            del self.buffer[:MAX_PACKET]
            p=np.frombuffer(pixels,dtype='<u2').reshape(height,w)
            r=(p>>11).astype(np.uint8);g=((p>>5)&63).astype(np.uint8);b=(p&31).astype(np.uint8)
            image=np.stack([(b<<3)|(b>>2),(g<<2)|(g>>4),(r<<3)|(r>>2)],axis=-1)
            frames.append(dict(image=image,sequence=seq,ticks=ticks,seconds=ticks/clock,
                score=None if flags==2 else score,box=(x,y,bw,bh),track=track,
                speaking=bool(flags&1),raw_preview=(flags==2)))
        return frames

def annotate(frame):
    import cv2
    image=frame['image'].copy()
    if frame.get('raw_preview',False):
        cv2.putText(image,f"CAMERA PREVIEW frame={frame['sequence']}",(4,14),cv2.FONT_HERSHEY_SIMPLEX,.38,(255,220,0),1)
        cv2.putText(image,f"capture={frame['seconds']:.3f}s; no result",(4,29),cv2.FONT_HERSHEY_SIMPLEX,.38,(255,220,0),1)
        return image
    x,y,w,h=frame['box'];color=(0,220,0) if frame['speaking'] else (0,180,255)
    cv2.rectangle(image,(x,y),(x+w-1,y+h-1),color,1)
    cv2.putText(image,f"visual={frame['score']:.3f} frame={frame['sequence']}",(4,14),cv2.FONT_HERSHEY_SIMPLEX,.38,color,1)
    return image

def preview(frame,port_name,baud,received,valid,bad,interval=None,age=None):
    import cv2
    canvas=np.zeros((470,640,3),dtype=np.uint8)
    if frame is None:
        cv2.putText(canvas,'Waiting for board image packet',(35,165),cv2.FONT_HERSHEY_SIMPLEX,.65,(220,220,220),1)
        cv2.putText(canvas,'No complete image has arrived yet',(35,195),cv2.FONT_HERSHEY_SIMPLEX,.48,(160,160,160),1)
    else:
        canvas[:360]=cv2.resize(annotate(frame),(640,360),interpolation=cv2.INTER_NEAREST)
    cv2.putText(canvas,f'{port_name}  {baud} baud   RX bytes: {received}',(10,383),cv2.FONT_HERSHEY_SIMPLEX,.48,(220,220,220),1)
    cv2.putText(canvas,f'Valid images: {valid}   Rejected packets: {bad}',(10,408),cv2.FONT_HERSHEY_SIMPLEX,.48,(220,220,220),1)
    status='Awaiting board result'
    if frame is not None:
        if frame.get('raw_preview',False):
            status=f"CAMERA PREVIEW | no recognition result | seq={frame['sequence']}"
        else:
            label='SPEAKING' if frame['speaking'] else 'NOT SPEAKING'
            status=f"Board: {label}  score={frame['score']:.4f}  seq={frame['sequence']}"
    cv2.putText(canvas,status,(10,433),cv2.FONT_HERSHEY_SIMPLEX,.48,(0,220,0) if frame and frame['speaking'] else (0,180,255),1)
    timing='Q / Esc: close   |   Displays latest received snapshot'
    if age is not None:
        gap='waiting for second image' if interval is None else f'{interval:.1f}s'
        timing=f'Last image: {age:.1f}s ago   Interval: {gap}   Q/Esc: close'
    cv2.putText(canvas,timing,(10,458),cv2.FONT_HERSHEY_SIMPLEX,.43,(160,160,160),1)
    return canvas

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port',required=True)
    parser.add_argument('--baud',type=int,default=921600)
    parser.add_argument('--headless',action='store_true')
    args=parser.parse_args()
    import cv2
    import serial
    destination=Path(__file__).resolve().with_name('model_speaking.png');decoder=Decoder()
    latest=None;received=0;valid=0;last_display=0.;last_report=time.monotonic()
    last_arrival=None;interval=None
    print('Waiting for camera previews and board recognition snapshots. Q/Esc or Ctrl+C stops. Save:',destination,flush=True)
    try:
        with serial.Serial(args.port,args.baud,timeout=.05) as port:
            print(f'Opened {args.port} at {args.baud} baud.',flush=True)
            if not args.headless:cv2.namedWindow('MODEL camera - board inference',cv2.WINDOW_AUTOSIZE)
            while True:
                data=port.read(min(max(port.in_waiting,1),4096))
                received+=len(data)
                for frame in decoder.feed(data):
                    arrival=time.monotonic()
                    if last_arrival is not None:interval=arrival-last_arrival
                    last_arrival=arrival
                    latest=frame;valid+=1
                    image=annotate(frame)
                    if frame['speaking']:
                        ok,png=cv2.imencode('.png',image)
                        if not ok:raise RuntimeError('PNG encoding failed')
                        destination.write_bytes(png.tobytes())
                    gap='first image' if interval is None else f'{interval:.2f}s'
                    if frame['raw_preview']:
                        print(f"camera_preview frame={frame['sequence']} capture={frame['seconds']:.3f}s no_result bad_packets={decoder.bad} interval={gap}",flush=True)
                    else:
                        print(f"frame={frame['sequence']} track={frame['track']} visual_score={frame['score']:.4f} bad_packets={decoder.bad} interval={gap}",flush=True)
                now=time.monotonic()
                if not args.headless and now-last_display>=.1:
                    age=None if last_arrival is None else now-last_arrival
                    cv2.imshow('MODEL camera - board inference',preview(latest,args.port,args.baud,received,valid,decoder.bad,interval,age));last_display=now
                if now-last_report>=5:
                    print(f'RX bytes={received} valid_images={valid} rejected_packets={decoder.bad}',flush=True);last_report=now
                if not args.headless and cv2.waitKey(1)&255 in (27,ord('q')):break
    except KeyboardInterrupt:pass
    finally:
        if not args.headless:cv2.destroyAllWindows()

if __name__=='__main__':main()
