// STUPIDMIRROR_FAST_TOUCH
//
// Included at the end of FBCustomCommands.m by scripts/patch-wda-for-control.sh.
//
// POST /stupidmirror/touch synthesizes a touch gesture directly through the
// test daemon, the same call WDA's W3C actions end in, without the work every
// stock coordinate route does first: no session lookup, no query for the
// foreground application, no XCUICoordinate resolution and no accessibility
// snapshot. That per-call work, not the touch itself, is most of a tap's
// latency.
//
// Body:
//   {
//     "fingers": [ [[x, y, seconds], ...], ... ],   // one path per finger
//     "orientation": 1                               // UIInterfaceOrientation,
//   }                                                // 0 = ask the device
//
// Points are in the foreground app's coordinate space, the space
// /window/size reports. Each finger touches down at its first sample, moves
// through the rest at their offsets, and lifts at its last sample, so a fast
// drag lifts while moving and scroll views keep their momentum.

#import "FBXCTestDaemonsProxy.h"
#import "XCSynthesizedEventRecord.h"
#import "XCPointerEventPath.h"
#import "XCUIApplication+FBHelpers.h"

@interface FBStupidMirrorTouchCommands : NSObject <FBCommandHandler>
@end

@implementation FBStupidMirrorTouchCommands

+ (NSArray *)routes
{
  return @[
    [[FBRoute POST:@"/stupidmirror/touch"].withoutSession respondWithTarget:self action:@selector(handleTouch:)],
    [[FBRoute POST:@"/stupidmirror/touch"] respondWithTarget:self action:@selector(handleTouch:)],
  ];
}

// Landscape needs the app's real orientation (left and right mirror each
// other). Asking costs a round trip, so the answer is reused briefly.
+ (UIInterfaceOrientation)stupidMirrorDeviceOrientation
{
  static UIInterfaceOrientation cached = UIInterfaceOrientationUnknown;
  static CFAbsoluteTime cachedAt = 0;
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  if (cached == UIInterfaceOrientationUnknown || now - cachedAt > 2.0) {
    cached = XCUIApplication.fb_activeApplication.interfaceOrientation;
    cachedAt = now;
  }
  return cached == UIInterfaceOrientationUnknown ? UIInterfaceOrientationPortrait : cached;
}

+ (id<FBResponsePayload>)handleTouch:(FBRouteRequest *)request
{
  NSArray *fingers = request.arguments[@"fingers"];
  if (![fingers isKindOfClass:NSArray.class] || fingers.count == 0) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"fingers must be a non-empty array" traceback:nil]);
  }

  UIInterfaceOrientation orientation = (UIInterfaceOrientation)[request.arguments[@"orientation"] integerValue];
  if (orientation < UIInterfaceOrientationPortrait || orientation > UIInterfaceOrientationLandscapeLeft) {
    orientation = [self stupidMirrorDeviceOrientation];
  }

  XCSynthesizedEventRecord *record = [[XCSynthesizedEventRecord alloc] initWithName:@"StupidMirror touch"
                                                               interfaceOrientation:orientation];
  for (NSArray *finger in fingers) {
    if (![finger isKindOfClass:NSArray.class] || finger.count == 0) {
      return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"each finger needs at least one [x, y, seconds] sample" traceback:nil]);
    }
    XCPointerEventPath *path = nil;
    double lastOffset = 0;
    for (NSArray *sample in finger) {
      if (![sample isKindOfClass:NSArray.class] || sample.count < 3) {
        return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"a sample is [x, y, seconds]" traceback:nil]);
      }
      CGPoint point = CGPointMake([sample[0] doubleValue], [sample[1] doubleValue]);
      double offset = MAX([sample[2] doubleValue], lastOffset);
      if (nil == path) {
        path = [[XCPointerEventPath alloc] initForTouchAtPoint:point offset:offset];
      } else {
        [path moveToPoint:point atOffset:offset];
      }
      lastOffset = offset;
    }
    [path liftUpAtOffset:lastOffset];
    [record addPointerEventPath:path];
  }

  NSError *error;
  if (![FBXCTestDaemonsProxy synthesizeEventWithRecord:record error:&error]) {
    return FBResponseWithUnknownError(error);
  }
  return FBResponseWithOK();
}

@end
