// Included by FBCustomCommands.m. The display used for video and the posture
// reported to the desktop come from the same live simulator state.
#import <TargetConditionals.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <math.h>
#import <objc/message.h>

static id SMDisplayValue(id object, NSString *key)
{
  if (![object respondsToSelector:NSSelectorFromString(key)]) { return nil; }
  @try { return [object valueForKey:key]; } @catch (NSException *exception) { return nil; }
}

@interface FBStupidMirrorDisplayCommands : NSObject <FBCommandHandler>
@property (nonatomic, strong) id angleManager;
@property (nonatomic, strong) NSOperationQueue *angleQueue;
@property (nonatomic, strong) NSNumber *hingeAngle;
@property (nonatomic, strong) NSArray *displays;
@property (nonatomic, strong) id activeDisplay;
@property (nonatomic, assign) CFAbsoluteTime refreshedAt;
@end

@implementation FBStupidMirrorDisplayCommands

+ (instancetype)shared
{
  static FBStupidMirrorDisplayCommands *instance;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ instance = [self new]; });
  return instance;
}

- (instancetype)init
{
  if ((self = [super init])) {
#if TARGET_OS_SIMULATOR
    Class displayClass = NSClassFromString(@"CADisplay");
    SEL selector = NSSelectorFromString(@"displays");
    if ([displayClass respondsToSelector:selector]) {
      NSArray *all = ((id (*)(id, SEL))objc_msgSend)(displayClass, selector);
      _displays = [all filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id display, NSDictionary *bindings) {
        NSNumber *type = SMDisplayValue(display, @"displayType");
        return type != nil && type.integerValue == 0;
      }]];
    }
    if (_displays.count > 1) {
      dlopen("/System/Library/Frameworks/CoreMotion.framework/CoreMotion", RTLD_LAZY);
      Class angleClass = NSClassFromString(@"CMAngleManager");
      _angleManager = [[angleClass alloc] init];
      SEL start = NSSelectorFromString(@"startAngleUpdatesToQueue:handler:");
      if ([_angleManager respondsToSelector:start]) {
        _angleQueue = [NSOperationQueue new];
        _angleQueue.maxConcurrentOperationCount = 1;
        _angleQueue.qualityOfService = NSQualityOfServiceUtility;
        __weak typeof(self) weakSelf = self;
        // CMAngleManager's handler has one argument (unlike CMMotionManager).
        void (^handler)(id) = ^(id angle) {
          NSNumber *valid = SMDisplayValue(angle, @"isAngleValid");
          NSNumber *degrees = SMDisplayValue(angle, @"angleDegrees");
          if (valid.boolValue && degrees != nil && isfinite(degrees.doubleValue)) {
            typeof(self) self = weakSelf;
            @synchronized (self) { self.hingeAngle = degrees; }
          }
        };
        ((void (*)(id, SEL, id, id))objc_msgSend)(_angleManager, start, _angleQueue, handler);
      }
    }
#endif
  }
  return self;
}

- (id)currentDisplay
{
  // A short cache keeps private display queries off the per-frame hot path.
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  if (self.activeDisplay && now - self.refreshedAt < 0.1) { return self.activeDisplay; }
  self.refreshedAt = now;
  for (id display in self.displays) {
    NSNumber *state = SMDisplayValue(SMDisplayValue(display, @"stateControl"), @"displayState");
    if (state != nil && state.integerValue > 0) {
      self.activeDisplay = display;
      return display;
    }
  }
  // Keep the last panel while both are off (lock or a folding transition).
  return self.activeDisplay ?: self.displays.firstObject;
}

+ (NSArray *)routes
{
  return @[
    [[FBRoute GET:@"/stupidmirror/display"].withoutSession respondWithTarget:self action:@selector(handleDisplay:)],
    [[FBRoute POST:@"/stupidmirror/posture"].withoutSession respondWithTarget:self action:@selector(handlePosture:)],
    [[FBRoute POST:@"/stupidmirror/rotate"].withoutSession respondWithTarget:self action:@selector(handleRotate:)],
  ];
}

+ (id<FBResponsePayload>)handleDisplay:(FBRouteRequest *)request
{
  FBStupidMirrorDisplayCommands *state = self.shared;
  @synchronized (state) {
    id display = [state currentDisplay];
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSNumber *displayID = SMDisplayValue(display, @"displayId");
    if (displayID) { result[@"display_id"] = displayID; }
    NSValue *nativeSize = SMDisplayValue(display, @"nativeSize");
    if (nativeSize) {
      CGSize size = nativeSize.CGSizeValue;
      result[@"native_width"] = @(size.width);
      result[@"native_height"] = @(size.height);
    }
    result[@"point_scale"] = SMDisplayValue(display, @"pointScale") ?: @1;
    result[@"orientation"] = SMDisplayValue(display, @"currentOrientation") ?: @"rot0";
    result[@"foldable"] = state.displays.count > 1 ? @YES : @NO;
    if (state.hingeAngle) {
      double angle = state.hingeAngle.doubleValue;
      result[@"hinge_angle"] = state.hingeAngle;
      result[@"posture"] = angle < 5 ? @"closed" : angle > 175 ? @"open" : @"partially_open";
    }
    return FBResponseWithObject(result);
  }
}

+ (id<FBResponsePayload>)handlePosture:(FBRouteRequest *)request
{
#if TARGET_OS_SIMULATOR
  FBStupidMirrorDisplayCommands *state = self.shared;
  if (state.displays.count < 2) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"Posture control requires a foldable iOS Simulator." traceback:nil]);
  }
  NSString *posture = request.arguments[@"posture"];
  // Match Device Hub's three pose presets, including its 130-degree book pose.
  NSDictionary *angles = @{@"closed": @0, @"partially_open": @130, @"open": @180};
  NSNumber *angle = [posture isKindOfClass:NSString.class] ? angles[posture] : nil;
  if (angle == nil) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"posture must be closed, partially_open, or open." traceback:nil]);
  }
  void *io = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
  CFDataRef (*serialize)(CFTypeRef, CFOptionFlags) = dlsym(io, "IOCFSerialize");
  CFTypeRef (*clientCreate)(CFAllocatorRef) = dlsym(io, "IOHIDEventSystemClientCreate");
  CFTypeRef (*eventCreate)(CFAllocatorRef, uint64_t, uint16_t, uint16_t, uint32_t, const uint8_t *, CFIndex, uint32_t) = dlsym(io, "IOHIDEventCreateVendorDefinedEvent");
  void (*dispatchEvent)(CFTypeRef, CFTypeRef) = dlsym(io, "IOHIDEventSystemClientDispatchEvent");
  if (!(serialize && clientCreate && eventCreate && dispatchEvent)) {
    return FBResponseWithStatus([FBCommandStatus unsupportedOperationErrorWithMessage:@"This simulator runtime cannot send hinge events." traceback:nil]);
  }
  // Device Hub sends this vendor event to the simulated hinge sensor. The
  // resulting CoreMotion update is read back by /stupidmirror/display.
  NSDictionary *payload = @{@"provider": @"com.apple.Virtualization.VirtualMachines",
                            @"source": @"hinge-slider-control", @"type": @"range", @"value": @(angle.doubleValue)};
  CFDataRef data = serialize((__bridge CFDictionaryRef)payload, 1);
  CFTypeRef client = clientCreate(kCFAllocatorDefault);
  CFTypeRef event = data ? eventCreate(kCFAllocatorDefault, mach_absolute_time(), 0xff61, 0x5b, 0,
                                      CFDataGetBytePtr(data), CFDataGetLength(data), 0) : NULL;
  BOOL sent = client && event;
  if (sent) { dispatchEvent(client, event); }
  if (event) { CFRelease(event); }
  if (client) { CFRelease(client); }
  if (data) { CFRelease(data); }
  if (!sent) {
    return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:@"Could not create a simulator hinge event." traceback:nil]);
  }
  return FBResponseWithOK();
#else
  return FBResponseWithStatus([FBCommandStatus unsupportedOperationErrorWithMessage:@"Physical device posture is read-only." traceback:nil]);
#endif
}

+ (id<FBResponsePayload>)handleRotate:(FBRouteRequest *)request
{
#if TARGET_OS_SIMULATOR
  NSString *orientation = SMDisplayValue([self.shared currentDisplay], @"currentOrientation");
  UIDeviceOrientation next = UIDeviceOrientationLandscapeRight;
  if ([orientation isEqualToString:@"rot90"]) { next = UIDeviceOrientationPortrait; }
  else if ([orientation isEqualToString:@"rot0"]) { next = UIDeviceOrientationLandscapeLeft; }
  else if ([orientation isEqualToString:@"rot270"]) { next = UIDeviceOrientationPortraitUpsideDown; }
  [XCUIDevice sharedDevice].orientation = next;
  return FBResponseWithOK();
#else
  return FBResponseWithStatus([FBCommandStatus unsupportedOperationErrorWithMessage:@"Rotation requires an iOS Simulator." traceback:nil]);
#endif
}

@end

// Shared by the MJPEG and H.264 capture paths. Single-screen/physical devices
// retain XCTest's default display without screenshot probing.
long long FBStupidMirrorActiveDisplayID(long long defaultID)
{
#if TARGET_OS_SIMULATOR
  FBStupidMirrorDisplayCommands *state = FBStupidMirrorDisplayCommands.shared;
  if (state.displays.count > 1) {
    @synchronized (state) {
      NSNumber *displayID = SMDisplayValue([state currentDisplay], @"displayId");
      if (displayID) { return displayID.longLongValue; }
    }
  }
#endif
  return defaultID;
}
