// Interface between the SwiftUI editors (UI.swift) and the plug-in (plugin.mm).
#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface ASAFParamInfo : NSObject
@property (nonatomic, copy) NSString *ident;   ///< the unit's own id, e.g. "azimuth"
@property (nonatomic, copy) NSString *name;    ///< display name
@property (nonatomic, copy) NSString *group;   ///< e.g. "Object 3"; empty if none
@property (nonatomic) double minValue, maxValue, defaultValue;
@property (nonatomic) BOOL stepped, readOnly;
/// Names for a stepped parameter's values, first = minimum ("Binaural", "Stereo", ...); empty if none.
@property (nonatomic, copy) NSArray<NSString *> *labels;
@end

@interface ASAFUnitBridge : NSObject
@property (nonatomic, readonly, copy) NSString *unitName;                   ///< "ASAF Object"
@property (nonatomic, readonly, copy) NSString *kind;                       ///< "Objt", "Expt", ...
@property (nonatomic, readonly, copy) NSArray<ASAFParamInfo *> *parameters; ///< empty if the Apple unit's build isn't recognised
/// Colour for this unit's puck, 0xRRGGBB: the host track's colour if it has one, else a colour chosen
/// from the object index.
@property (nonatomic, readonly) NSInteger puckRGB;
- (NSInteger)indexOf:(NSString *)ident;                                     ///< -1 if absent
- (double)valueAt:(NSInteger)index;
- (void)setValue:(double)value at:(NSInteger)index;
- (void)beginGesture:(NSInteger)index;
- (void)endGesture:(NSInteger)index;
/// ASAF Export only: convert a bounced file to ASAF BWF (and optionally APAC). Blocks; returns nil on
/// success or a message.
- (nullable NSString *)convertFile:(NSString *)path createAPAC:(BOOL)apac;
@end

NS_ASSUME_NONNULL_END
