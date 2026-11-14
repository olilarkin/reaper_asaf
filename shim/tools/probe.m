// Probes hidden JUCE parameter ranges of an ASAF AU by round-tripping its state.
#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
static OSType fcc(const char*s){return (s[0]<<24)|(s[1]<<16)|(s[2]<<8)|s[3];}
static AudioUnit au;
static NSXMLDocument* getState(void){
  CFPropertyListRef pl=NULL; UInt32 sz=sizeof pl;
  if(AudioUnitGetProperty(au,kAudioUnitProperty_ClassInfo,kAudioUnitScope_Global,0,&pl,&sz)) return nil;
  NSData*j=((__bridge_transfer NSDictionary*)pl)[@"jucePluginState"];
  uint32_t len; [j getBytes:&len range:NSMakeRange(4,4)];
  return [[NSXMLDocument alloc] initWithData:[j subdataWithRange:NSMakeRange(8,len)] options:0 error:nil];
}
static void setState(NSXMLDocument*doc){
  CFPropertyListRef pl=NULL; UInt32 sz=sizeof pl;
  AudioUnitGetProperty(au,kAudioUnitProperty_ClassInfo,kAudioUnitScope_Global,0,&pl,&sz);
  NSMutableDictionary*d=[(__bridge_transfer NSDictionary*)pl mutableCopy];
  NSData*x=[doc XMLDataWithOptions:NSXMLNodeCompactEmptyElement]; NSMutableData*b=[NSMutableData data];
  uint32_t magic=0x21324356,len=(uint32_t)x.length; [b appendBytes:&magic length:4]; [b appendBytes:&len length:4]; [b appendData:x]; [b appendBytes:"" length:1];
  d[@"jucePluginState"]=b; CFPropertyListRef p=(__bridge CFPropertyListRef)d;
  OSStatus e=AudioUnitSetProperty(au,kAudioUnitProperty_ClassInfo,kAudioUnitScope_Global,0,&p,sizeof p); if(e) fprintf(stderr,"set err %d\n",(int)e);
}
static NSDictionary* vals(NSXMLDocument*d){ NSMutableDictionary*m=[NSMutableDictionary dictionary];
  for(NSXMLElement*e in [d nodesForXPath:@"//PARAM" error:nil]) m[[e attributeForName:@"id"].stringValue]=@([e attributeForName:@"value"].stringValue.doubleValue); return m;}
static NSDictionary* probe(NSDictionary*(^f)(NSString*), NSSet*skip){ NSXMLDocument*d=getState();
  for(NSXMLElement*e in [d nodesForXPath:@"//PARAM" error:nil]){ NSString*i=[e attributeForName:@"id"].stringValue; if([skip containsObject:i]) continue;
    NSNumber*v=(NSNumber*)f(i); if(v) [e attributeForName:@"value"].stringValue=[NSString stringWithFormat:@"%.9g",v.doubleValue]; }
  setState(d); return vals(getState()); }
int main(int argc,char**argv){ @autoreleasepool{
  AudioComponentDescription desc={'aufx',fcc(argv[1]),fcc("Appl"),0,0};
  AudioComponent c=AudioComponentFindNext(NULL,&desc); if(!c||AudioComponentInstanceNew(c,&au)) return 1;
  NSMutableSet*skip=[NSMutableSet set]; for(int i=2;i<argc;i++) [skip addObject:@(argv[i])];
  NSXMLDocument*orig=getState(); NSDictionary*def=vals(orig);
  NSDictionary*mn=probe(^(NSString*i){return (id)@(-1e9);},skip);
  NSDictionary*mx=probe(^(NSString*i){return (id)@(1e9);},skip);
  NSDictionary*mid=probe(^(NSString*i){double a=[mn[i] doubleValue],b=[mx[i] doubleValue]; return (id)@(a+(b-a)*0.3712);},skip);
  setState(orig);
  NSMutableArray*out=[NSMutableArray array];
  for(NSString*i in [def.allKeys sortedArrayUsingSelector:@selector(compare:)]){
    BOOL sk=[skip containsObject:i]; double a=sk?0:[mn[i] doubleValue],b=sk?1:[mx[i] doubleValue],want=a+(b-a)*0.3712,got=[mid[i] doubleValue];
    BOOL disc= sk || fabs(got-want)>1e-4*fmax(1,fabs(b-a));
    [out addObject:@{@"id":i,@"def":def[i],@"min":@(a),@"max":@(b),@"discrete":@(disc)}]; }
  NSData*js=[NSJSONSerialization dataWithJSONObject:out options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:nil];
  [js writeToFile:[NSString stringWithFormat:@"params_%s.json",argv[1]] atomically:YES];
  printf("%s: %lu params, root <%s>\n",argv[1],(unsigned long)out.count,orig.rootElement.name.UTF8String);
  for(NSDictionary*p in out) if(out.count<80) printf("  %-34s def %-10.4g [%g .. %g]%s\n",[p[@"id"] UTF8String],[p[@"def"] doubleValue],[p[@"min"] doubleValue],[p[@"max"] doubleValue],[p[@"discrete"] boolValue]?" discrete":"");
} return 0;}
