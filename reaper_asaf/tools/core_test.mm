// Harness test for asaf_core: N ASAF Objects + ASAF Export -> bounce file -> ASAF BWF.
#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#include "../asaf_core.h"
static AudioUnit mk(OSType sub){ AudioComponentDescription d={'aufx',sub,'ASFs',0,0}; AudioUnit au=NULL; AudioComponent c=AudioComponentFindNext(NULL,&d); if(c) AudioComponentInstanceNew(c,&au); return au; }
static void setp(AudioUnit au,NSString*name,float v){ UInt32 sz=0; Boolean w; AudioUnitGetPropertyInfo(au,kAudioUnitProperty_ParameterList,0,0,&sz,&w); int n=sz/4;
  for(int i=0;i<n;i++){ AudioUnitParameterInfo pi; sz=sizeof pi; AudioUnitGetProperty(au,kAudioUnitProperty_ParameterInfo,0,i,&pi,&sz); if([(__bridge NSString*)pi.cfNameString isEqual:name]){ AudioUnitSetParameter(au,i,0,0,v,0); return; } } printf("no param %s\n",name.UTF8String); }
static void pump(double s){ [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:s]]; }
static OSStatus inCB(void*ref,AudioUnitRenderActionFlags*f,const AudioTimeStamp*ts,UInt32 bus,UInt32 n,AudioBufferList*io){
  double hz=220.0*(1+(intptr_t)ref); for(UInt32 b=0;b<io->mNumberBuffers;b++){ float*p=(float*)io->mBuffers[b].mData; for(UInt32 i=0;i<n;i++) p[i]=0.25f*sinf((float)((ts->mSampleTime+i)*2*M_PI*hz/48000.0)); } return noErr; }
static void fmt(AudioUnit au,AudioUnitScope sc,int ch){ AudioStreamBasicDescription d={48000,kAudioFormatLinearPCM,kAudioFormatFlagsNativeFloatPacked|kAudioFormatFlagIsNonInterleaved,4,1,4,(UInt32)ch,32,0}; AudioUnitSetProperty(au,kAudioUnitProperty_StreamFormat,sc,0,&d,sizeof d); }
int main(int argc,char**argv){ @autoreleasepool{
  int nobj=argc>1?atoi(argv[1]):3; const char*path=argc>2?argv[2]:"/tmp/asaf_core_test.wav"; const int N=1024, NOUT=8, NCH=nobj+NOUT;
  std::vector<AudioUnit> objs; for(int i=0;i<nobj;i++){ AudioUnit o=mk('Objt'); if(!o) return 1; objs.push_back(o); setp(o,@"index",i); setp(o,@"azimuth",(getenv("AZ")?atof(getenv("AZ")):-90)+i*40); setp(o,@"elevation",getenv("EL")?atof(getenv("EL")):0); }
  AudioUnit ex=mk('Expt'); if(!ex) return 1; pump(0.3);
  for(int i=0;i<nobj;i++){ fmt(objs[i],kAudioUnitScope_Input,1); fmt(objs[i],kAudioUnitScope_Output,1); AURenderCallbackStruct cb={inCB,(void*)(intptr_t)i}; AudioUnitSetProperty(objs[i],kAudioUnitProperty_SetRenderCallback,kAudioUnitScope_Input,0,&cb,sizeof cb); AudioUnitInitialize(objs[i]); }
  fmt(ex,kAudioUnitScope_Input,2); fmt(ex,kAudioUnitScope_Output,NOUT); AURenderCallbackStruct cb={inCB,NULL}; AudioUnitSetProperty(ex,kAudioUnitProperty_SetRenderCallback,kAudioUnitScope_Input,0,&cb,sizeof cb); AudioUnitInitialize(ex);

  std::string err;
  printf("shim load %d, exports %d\n",(int)asaf::shim().load(),asaf::shim().ok()?asaf::shim().Count(asaf::kExport):-1);
  if(!asaf::armExport(true,&err)){ printf("arm failed: %s\n",err.c_str()); return 1; }
  asaf::BounceWriter w; if(!w.open(path,NCH,48000)){ printf("open failed\n"); return 1; }
  std::vector<std::vector<float>> fb(NCH,std::vector<float>(N)); std::vector<std::vector<double>> db(NCH,std::vector<double>(N)); std::vector<double*> ptrs(NCH); for(int c=0;c<NCH;c++) ptrs[c]=db[c].data();
  AudioBufferList*bl=(AudioBufferList*)malloc(sizeof(AudioBufferList)+sizeof(AudioBuffer)*16); double metaPeak=0;
  for(int blk=0;blk<48000*4/N;blk++){ AudioTimeStamp ts={0}; ts.mFlags=kAudioTimeStampSampleTimeValid; ts.mSampleTime=blk*N;
    for(int i=0;i<nobj;i++){ AudioUnitRenderActionFlags fl=0; bl->mNumberBuffers=1; bl->mBuffers[0]=(AudioBuffer){1,(UInt32)N*4,fb[i].data()}; AudioUnitRender(objs[i],&fl,&ts,0,N,bl); float*p=(float*)bl->mBuffers[0].mData; for(int k=0;k<N;k++) db[i][k]=p[k]; }
    AudioUnitRenderActionFlags fl=0; bl->mNumberBuffers=NOUT; for(int c=0;c<NOUT;c++) bl->mBuffers[c]=(AudioBuffer){1,(UInt32)N*4,fb[nobj+c].data()}; AudioUnitRender(ex,&fl,&ts,0,N,bl);
    for(int c=0;c<NOUT;c++){ float*p=(float*)bl->mBuffers[c].mData; for(int k=0;k<N;k++){ db[nobj+c][k]=p[k]; if(fabsf(p[k])>metaPeak) metaPeak=fabsf(p[k]); } }
    w.write(ptrs.data(),N,NCH,0,1);
  }
  w.close(); int ch=0; bool pre=asaf::isASAFFile(path,&ch); printf("bounce: %d ch, meta peak %.3f, ASAF before=%d\n",ch,metaPeak,(int)pre);
  std::string apacErr; bool wantApac=getenv("APAC")!=NULL; double t0=CFAbsoluteTimeGetCurrent();
  bool ok=wantApac?asaf::convertBounceToASAFAndAPAC(path,&err,&apacErr):asaf::convertBounceToASAF(path,&err); ch=0;
  if(wantApac) printf("apac: %s (%.1fs) %s\n",apacErr.empty()?"OK":"FAILED",CFAbsoluteTimeGetCurrent()-t0,apacErr.c_str()); bool post=asaf::isASAFFile(path,&ch);
  printf("convert %s; after: %d ch, ASAF=%d%s%s\n",ok?"OK":"FAILED",ch,(int)post,ok?"":"\n  ",ok?"":err.c_str());
  float armed=-1; asaf::shim().GetParam(asaf::kExport,"bounceArmed",&armed); printf("armed after: %g\n",armed);
  fflush(stdout); _exit(ok?0:1);
} }
