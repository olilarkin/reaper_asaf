// Interface between the SwiftUI panner (PannerUI.swift) and the REAPER side (panner.mm).
#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// One ASAF Object plug-in found in the current project.
@interface ASAFObjectState : NSObject
@property (nonatomic) NSInteger ident;          ///< stable for the life of the track + plug-in slot
@property (nonatomic, copy) NSString *name;     ///< track name
@property (nonatomic) NSInteger objectIndex;    ///< ASAF object index (0-based)
@property (nonatomic) double azimuth;           ///< degrees, 0 = front, positive = left
@property (nonatomic) double elevation;         ///< degrees, positive = up
@property (nonatomic) double distance;          ///< metres (the plug-in's "r")
@property (nonatomic) BOOL enabled;             ///< playbackEnabled
@property (nonatomic) BOOL hasColor;
@property (nonatomic) double red, green, blue;  ///< track colour, 0-1
@end

@interface ASAFPannerBridge : NSObject
/// Current objects, in track order. Main thread.
- (NSArray<ASAFObjectState *> *)snapshot;
- (void)beginEdit:(NSInteger)ident;
- (void)setAzimuth:(double)azimuth elevation:(double)elevation distance:(double)distance forObject:(NSInteger)ident;
- (void)endEdit:(NSInteger)ident;
/// Select the object's track in REAPER.
- (void)selectTrack:(NSInteger)ident;
/// Whether the panner is in REAPER's docker, and a way to move it in or out.
@property (nonatomic, readonly) BOOL docked;
- (void)toggleDock;
@end

NS_ASSUME_NONNULL_END
