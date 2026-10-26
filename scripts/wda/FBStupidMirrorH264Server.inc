// Compiled into FBMjpegServer.m by scripts/patch-wda-for-control.sh.
// Keeping this implementation in one include avoids changing WDA's Xcode
// project while still giving StupidMirror a separately versioned stream.

@import CoreImage;
@import CoreMedia;
@import CoreVideo;
@import ImageIO;
@import VideoToolbox;
#import <libsrt/srt.h>
#import <mach/mach.h>
#import <netinet/in.h>

static const uint16_t SMH264DefaultPort = 9200;
static const NSUInteger SMH264DefaultFPS = 45;
static const NSUInteger SMH264DefaultSourceQuality = 80;
static const NSUInteger SMH264DefaultBitrate = 8000000;
static const NSTimeInterval SMH264FrameTimeout = 1.0;
static const NSUInteger SMSRTMaximumMessageSize = 1316;
static const NSUInteger SMSRTHeaderSize = 24;
static const NSUInteger SMSRTMaximumPayloadSize = SMSRTMaximumMessageSize - SMSRTHeaderSize;
static const NSUInteger SMH264MaximumPendingFrames = 2;
static const NSUInteger SMH264MaximumPixelBuffers = 4;
static const uint64_t SMH264StatsInterval = 5 * NSEC_PER_SEC;
static const void *SMH264CaptureQueueKey = &SMH264CaptureQueueKey;

// Export startup health through WDA's existing /status response. This keeps
// transport observability on the same probe the desktop already performs.
volatile int SMStupidMirrorSRTStartupState = 0;
char SMStupidMirrorSRTStartupError[512] = {0};

@class FBStupidMirrorH264Server;

// The simulator display controller observes the active internal panel. Both
// video transports resolve it for every capture, including external changes
// from Device Hub. Ordinary devices keep the normal XCTest display.
extern long long FBStupidMirrorActiveDisplayID(long long defaultID);

static long long FBStupidMirrorResolveScreenID(long long defaultID)
{
  return FBStupidMirrorActiveDisplayID(defaultID);
}

static dispatch_queue_t SMH264CreateQueue(const char *label, qos_class_t qos)
{
  dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, qos, 0);
  attributes = dispatch_queue_attr_make_with_autorelease_frequency(attributes, DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM);
  return dispatch_queue_create(label, attributes);
}

@interface FBStupidMirrorH264Server : NSObject

@property (nonatomic, readonly) dispatch_queue_t captureQueue;
@property (nonatomic, readonly) dispatch_queue_t srtAcceptQueue;
@property (nonatomic, readonly) dispatch_queue_t srtSendQueue;
@property (nonatomic, readonly) CIContext *ciContext;
@property (nonatomic, readonly) long long mainScreenID;
@property (nonatomic, assign) VTCompressionSessionRef compressionSession;
@property (nonatomic, assign) int32_t encodedWidth;
@property (nonatomic, assign) int32_t encodedHeight;
@property (atomic, assign) BOOL isRunning;
@property (nonatomic, assign) NSUInteger inFlightFrameCount;
@property (nonatomic, assign) BOOL needsKeyFrame;
@property (nonatomic, assign) SRTSOCKET srtListener;
@property (nonatomic, assign) SRTSOCKET srtClient;
@property (nonatomic, assign) uint32_t srtFrameID;
@property (nonatomic, assign) NSUInteger srtPendingFrames;
@property (nonatomic, assign) uint64_t srtGeneration;
@property (nonatomic, assign) BOOL srtAwaitingKeyFrame;
@property (nonatomic, assign) uint64_t lastStatsTime;
@property (nonatomic, assign) NSUInteger capturedFrames;
@property (nonatomic, assign) NSUInteger encodedFrames;
@property (nonatomic, assign) NSUInteger sentFrames;
@property (nonatomic, assign) NSUInteger skippedFrames;
@property (nonatomic, assign) NSUInteger droppedFrames;

- (instancetype)initWithPort:(uint16_t)port;
- (void)stop;
- (void)didEncodeSampleBuffer:(CMSampleBufferRef)sampleBuffer
                       status:(OSStatus)status
                    infoFlags:(VTEncodeInfoFlags)infoFlags;

@end

@implementation FBStupidMirrorH264Server

- (instancetype)initWithPort:(uint16_t)port
{
  if ((self = [super init])) {
    _captureQueue = SMH264CreateQueue(
      "com.stupidmirror.wda.h264.capture",
      // Keep the 45 fps target, but let XCTest control work preempt capture
      // when both paths contend for device-side automation resources.
      QOS_CLASS_UTILITY
    );
    dispatch_queue_set_specific(_captureQueue, SMH264CaptureQueueKey, (__bridge void *)self, NULL);
    _srtAcceptQueue = SMH264CreateQueue(
      "com.stupidmirror.wda.h264.srt-accept",
      QOS_CLASS_USER_INITIATED
    );
    _srtSendQueue = SMH264CreateQueue(
      "com.stupidmirror.wda.h264.srt-send",
      QOS_CLASS_USER_INTERACTIVE
    );
    _ciContext = [CIContext contextWithOptions:@{
      kCIContextUseSoftwareRenderer: @NO,
      kCIContextCacheIntermediates: @NO
    }];
    _mainScreenID = [XCUIScreen.mainScreen displayID];
    _encodedWidth = 0;
    _encodedHeight = 0;
    _isRunning = YES;
    _inFlightFrameCount = 0;
    _needsKeyFrame = YES;
    _srtListener = SRT_INVALID_SOCK;
    _srtClient = SRT_INVALID_SOCK;
    _srtFrameID = arc4random();
    _srtPendingFrames = 0;
    _srtGeneration = 0;
    _srtAwaitingKeyFrame = YES;
    _lastStatsTime = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    [self startSRTListenerOnPort:port];
    __weak typeof(self) weakSelf = self;
    dispatch_async(_captureQueue, ^{
      [weakSelf captureNextFrame];
    });
  }
  return self;
}

- (BOOL)setSRTOption:(SRT_SOCKOPT)option
               value:(const void *)value
              length:(int)length
            onSocket:(SRTSOCKET)socket
{
  return srt_setsockflag(socket, option, value, length) != SRT_ERROR;
}

- (void)startSRTListenerOnPort:(uint16_t)port
{
  SMStupidMirrorSRTStartupState = 1;
  if (srt_startup() != 0) {
    SMStupidMirrorSRTStartupState = -1;
    strlcpy(SMStupidMirrorSRTStartupError, srt_getlasterror_str(), sizeof(SMStupidMirrorSRTStartupError));
    [FBLogger log:@"Cannot initialize StupidMirror SRT transport"];
    return;
  }
  SRTSOCKET listener = srt_create_socket();
  if (listener == SRT_INVALID_SOCK) {
    SMStupidMirrorSRTStartupState = -2;
    strlcpy(SMStupidMirrorSRTStartupError, srt_getlasterror_str(), sizeof(SMStupidMirrorSRTStartupError));
    [FBLogger logFmt:@"Cannot create StupidMirror SRT listener: %s", srt_getlasterror_str()];
    return;
  }
  int32_t transport = SRTT_LIVE;
  bool sender = true;
  bool tooLateDrop = true;
  int32_t peerLatency = 80;
  int32_t sendTimeout = 80;
  int32_t receiveTimeout = 500;
  int32_t payloadSize = (int32_t)SMSRTMaximumMessageSize;
  BOOL configured =
    [self setSRTOption:SRTO_TRANSTYPE value:&transport length:sizeof(transport) onSocket:listener] &&
    [self setSRTOption:SRTO_SENDER value:&sender length:sizeof(sender) onSocket:listener] &&
    [self setSRTOption:SRTO_TLPKTDROP value:&tooLateDrop length:sizeof(tooLateDrop) onSocket:listener] &&
    [self setSRTOption:SRTO_PEERLATENCY value:&peerLatency length:sizeof(peerLatency) onSocket:listener] &&
    [self setSRTOption:SRTO_SNDTIMEO value:&sendTimeout length:sizeof(sendTimeout) onSocket:listener] &&
    [self setSRTOption:SRTO_RCVTIMEO value:&receiveTimeout length:sizeof(receiveTimeout) onSocket:listener] &&
    [self setSRTOption:SRTO_PAYLOADSIZE value:&payloadSize length:sizeof(payloadSize) onSocket:listener];
  // Listen on IPv6 with IPv4 mapping. The CoreDevice tunnel is IPv6 only and
  // is not subject to the Local Network privacy gate, so a dual-stack listener
  // stays reachable when iOS drops connections to the LAN address.
  int32_t ipv6Only = 0;
  struct sockaddr_in6 address6 = {0};
  address6.sin6_len = sizeof(address6);
  address6.sin6_family = AF_INET6;
  address6.sin6_port = htons(port);
  address6.sin6_addr = in6addr_any;
  BOOL dualStack = configured &&
    [self setSRTOption:SRTO_IPV6ONLY value:&ipv6Only length:sizeof(ipv6Only) onSocket:listener] &&
    srt_bind(listener, (const struct sockaddr *)&address6, sizeof(address6)) != SRT_ERROR;
  BOOL bound = dualStack;
  if (configured && !bound) {
    struct sockaddr_in address = {0};
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    address.sin_addr.s_addr = htonl(INADDR_ANY);
    bound = srt_bind(listener, (const struct sockaddr *)&address, sizeof(address)) != SRT_ERROR;
  }
  if (!bound || srt_listen(listener, 1) == SRT_ERROR) {
    SMStupidMirrorSRTStartupState = -3;
    strlcpy(SMStupidMirrorSRTStartupError, srt_getlasterror_str(), sizeof(SMStupidMirrorSRTStartupError));
    [FBLogger logFmt:@"Cannot start StupidMirror SRT listener: %s", srt_getlasterror_str()];
    srt_close(listener);
    return;
  }
  self.srtListener = listener;
  // 2: listening on IPv4 only. 3: also reachable over IPv6 (the tunnel).
  SMStupidMirrorSRTStartupState = dualStack ? 3 : 2;
  SMStupidMirrorSRTStartupError[0] = '\0';
  __weak typeof(self) weakSelf = self;
  dispatch_async(self.srtAcceptQueue, ^{
    [weakSelf acceptSRTClients];
  });
  [FBLogger logFmt:@"StupidMirror SRT/H.264 stream listening on UDP port %@ (%@)",
    @(port), dualStack ? @"IPv4+IPv6" : @"IPv4"];
}

- (void)acceptSRTClients
{
  while (self.isRunning) {
    SRTSOCKET listener = self.srtListener;
    if (listener == SRT_INVALID_SOCK) {
      return;
    }
    SRTSOCKET client = srt_accept(listener, NULL, NULL);
    if (client == SRT_INVALID_SOCK) {
      if (self.isRunning) {
        [FBLogger logFmt:@"StupidMirror SRT accept failed: %s", srt_getlasterror_str()];
      }
      return;
    }
    @synchronized (self) {
      if (self.srtClient != SRT_INVALID_SOCK) {
        srt_close(self.srtClient);
      }
      self.srtClient = client;
      self.needsKeyFrame = YES;
      self.srtFrameID = arc4random();
      self.srtGeneration++;
      self.srtAwaitingKeyFrame = YES;
    }
    [FBLogger log:@"StupidMirror SRT client connected"];
    [self receiveControlMessagesFromClient:client];
    __block BOOL shouldCloseClient = NO;
    @synchronized (self) {
      if (self.srtClient == client) {
        self.srtClient = SRT_INVALID_SOCK;
        shouldCloseClient = YES;
      }
    }
    if (shouldCloseClient) {
      srt_close(client);
    }
    [FBLogger log:@"StupidMirror SRT client disconnected"];
  }
}

- (void)receiveControlMessagesFromClient:(SRTSOCKET)client
{
  // Live-mode SRT rejects a receive buffer smaller than the negotiated payload
  // size without consuming the message, so a short buffer turns this loop
  // into a busy spin that never sees a key-frame request.
  char buffer[SMSRTMaximumMessageSize];
  const uint8_t keyFrameRequest[] = {'S', 'M', 'K', 'F'};
  while (self.isRunning && srt_getsockstate(client) == SRTS_CONNECTED) {
    int received = srt_recvmsg(client, buffer, sizeof(buffer));
    if (received == sizeof(keyFrameRequest) &&
        memcmp(buffer, keyFrameRequest, sizeof(keyFrameRequest)) == 0) {
      @synchronized (self) {
        self.needsKeyFrame = YES;
      }
    }
  }
}

- (NSUInteger)configuredUnsignedInteger:(NSString *)key
                           defaultValue:(NSUInteger)defaultValue
                                minimum:(NSUInteger)minimum
                                maximum:(NSUInteger)maximum
{
  NSString *raw = NSProcessInfo.processInfo.environment[key];
  if (raw.length == 0) {
    return defaultValue;
  }
  NSInteger value = raw.integerValue;
  if (value < (NSInteger)minimum || value > (NSInteger)maximum) {
    return defaultValue;
  }
  return (NSUInteger)value;
}

- (NSUInteger)targetFPS
{
  return [self configuredUnsignedInteger:@"STUPIDMIRROR_H264_FPS"
                            defaultValue:SMH264DefaultFPS
                                 minimum:1
                                 maximum:60];
}

- (CGFloat)sourceQuality
{
  NSUInteger percent = [self configuredUnsignedInteger:@"STUPIDMIRROR_H264_SOURCE_QUALITY"
                                           defaultValue:SMH264DefaultSourceQuality
                                                minimum:50
                                                maximum:100];
  return (CGFloat)percent / 100.0;
}

- (NSUInteger)targetBitrate
{
  return [self configuredUnsignedInteger:@"STUPIDMIRROR_H264_BITRATE"
                            defaultValue:SMH264DefaultBitrate
                                 minimum:2000000
                                 maximum:50000000];
}

- (void)scheduleNextFrameStartedAt:(uint64_t)timeStarted
{
  if (!self.isRunning) {
    return;
  }
  [self logStatsIfNeeded:timeStarted];
  uint64_t interval = (uint64_t)(1.0 / (double)self.targetFPS * NSEC_PER_SEC);
  uint64_t elapsed = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - timeStarted;
  int64_t delay = (int64_t)interval - (int64_t)elapsed;
  __weak typeof(self) weakSelf = self;
  if (delay > 0) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay), self.captureQueue, ^{
      [weakSelf captureNextFrame];
    });
  } else {
    dispatch_async(self.captureQueue, ^{
      [weakSelf captureNextFrame];
    });
  }
}

- (void)logStatsIfNeeded:(uint64_t)now
{
  if (now - self.lastStatsTime < SMH264StatsInterval) {
    return;
  }
  self.lastStatsTime = now;
  task_vm_info_data_t memory = {0};
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  kern_return_t memoryStatus = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&memory, &count);
  NSUInteger captured, encoded, sent, skipped, dropped, encoding, sending;
  @synchronized (self) {
    captured = self.capturedFrames;
    encoded = self.encodedFrames;
    sent = self.sentFrames;
    skipped = self.skippedFrames;
    dropped = self.droppedFrames;
    encoding = self.inFlightFrameCount;
    sending = self.srtPendingFrames;
  }
  [FBLogger logFmt:@"StupidMirror H.264 stats: footprint=%lld resident=%lld captured=%lu encoded=%lu sent=%lu skipped=%lu dropped=%lu encoding=%lu sending=%lu",
    memoryStatus == KERN_SUCCESS ? (long long)memory.phys_footprint : -1LL,
    memoryStatus == KERN_SUCCESS ? (long long)memory.resident_size : -1LL,
    (unsigned long)captured, (unsigned long)encoded, (unsigned long)sent,
    (unsigned long)skipped, (unsigned long)dropped, (unsigned long)encoding, (unsigned long)sending];
}

- (BOOL)hasClients
{
  @synchronized (self) {
    return self.srtClient != SRT_INVALID_SOCK &&
      srt_getsockstate(self.srtClient) == SRTS_CONNECTED;
  }
}

- (void)captureNextFrame
{
  @autoreleasepool {
    [self captureFrameInAutoreleasePool];
  }
}

- (void)captureFrameInAutoreleasePool
{
  if (!self.isRunning) {
    return;
  }
  uint64_t timeStarted = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
  if (![self hasClients]) {
    [self scheduleNextFrameStartedAt:timeStarted];
    return;
  }
  BOOL canBeginEncoding = NO;
  @synchronized (self) {
    // Apply backpressure before asking XCTest for another full-resolution
    // image. Skipping an unencoded source frame leaves H.264 references intact.
    if (self.inFlightFrameCount + self.srtPendingFrames < SMH264MaximumPendingFrames) {
      self.inFlightFrameCount++;
      canBeginEncoding = YES;
    } else {
      self.skippedFrames++;
    }
  }
  if (!canBeginEncoding) {
    [self scheduleNextFrameStartedAt:timeStarted];
    return;
  }

  NSError *error;
  NSData *jpeg = [FBScreenshot takeInOriginalResolutionWithScreenID:FBStupidMirrorResolveScreenID(self.mainScreenID)
                                                compressionQuality:self.sourceQuality
                                                               uti:UTTypeJPEG
                                                           timeout:SMH264FrameTimeout
                                                             error:&error];
  if (jpeg == nil) {
    [self finishEncodingFrame];
    [FBLogger logFmt:@"StupidMirror H.264 screenshot failed: %@", error.description];
    [self scheduleNextFrameStartedAt:timeStarted];
    return;
  }
  @synchronized (self) {
    self.capturedFrames++;
  }
  if (!self.isRunning) {
    [self finishEncodingFrame];
    return;
  }

  CIImage *sourceImage = [CIImage imageWithData:jpeg options:@{kCIImageApplyOrientationProperty: @YES}];
  if (sourceImage == nil || CGRectIsEmpty(sourceImage.extent)) {
    [self finishEncodingFrame];
    [self scheduleNextFrameStartedAt:timeStarted];
    return;
  }
  CGRect extent = CGRectIntegral(sourceImage.extent);
  if (fabs(extent.origin.x) > DBL_EPSILON || fabs(extent.origin.y) > DBL_EPSILON) {
    sourceImage = [sourceImage imageByApplyingTransform:CGAffineTransformMakeTranslation(
      -extent.origin.x,
      -extent.origin.y
    )];
    extent = CGRectIntegral(sourceImage.extent);
  }
  int32_t width = (int32_t)lrint(CGRectGetWidth(extent));
  int32_t height = (int32_t)lrint(CGRectGetHeight(extent));
  if (width <= 0 || height <= 0 || ![self prepareEncoderWidth:width height:height]) {
    [self finishEncodingFrame];
    [self scheduleNextFrameStartedAt:timeStarted];
    return;
  }

  CVPixelBufferPoolRef pool = VTCompressionSessionGetPixelBufferPool(self.compressionSession);
  CVPixelBufferRef pixelBuffer = nil;
  NSDictionary *allocationLimits = @{(__bridge NSString *)kCVPixelBufferPoolAllocationThresholdKey: @(SMH264MaximumPixelBuffers)};
  if (pool == nil || CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
        kCFAllocatorDefault, pool, (__bridge CFDictionaryRef)allocationLimits, &pixelBuffer
      ) != kCVReturnSuccess) {
    @synchronized (self) {
      self.skippedFrames++;
    }
    [self finishEncodingFrame];
    [self scheduleNextFrameStartedAt:timeStarted];
    return;
  }
  CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
  [self.ciContext render:sourceImage
         toCVPixelBuffer:pixelBuffer
                  bounds:CGRectMake(0, 0, width, height)
              colorSpace:colorSpace];
  CGColorSpaceRelease(colorSpace);

  CMTime presentationTime = CMTimeMake((int64_t)timeStarted, (int32_t)NSEC_PER_SEC);
  NSDictionary *frameProperties = nil;
  @synchronized (self) {
    if (self.needsKeyFrame) {
      frameProperties = @{(__bridge NSString *)kVTEncodeFrameOptionKey_ForceKeyFrame: @YES};
      self.needsKeyFrame = NO;
    }
  }
  // The callback may run before EncodeFrame returns. Claim completion under
  // the same lock on every path, so an error/drop cannot release two slots or
  // let a late callback send a frame that has already been abandoned.
  __block BOOL frameFinished = NO;
  __weak typeof(self) weakSelf = self;
  VTEncodeInfoFlags encodeFlags = 0;
  OSStatus status = VTCompressionSessionEncodeFrameWithOutputHandler(
    self.compressionSession,
    pixelBuffer,
    presentationTime,
    kCMTimeInvalid,
    (__bridge CFDictionaryRef)frameProperties,
    &encodeFlags,
    ^(OSStatus callbackStatus, VTEncodeInfoFlags flags, CMSampleBufferRef sampleBuffer) {
      @autoreleasepool {
        __strong typeof(weakSelf) server = weakSelf;
        if (server == nil) { return; }
        @synchronized (server) {
          if (frameFinished) { return; }
          frameFinished = YES;
        }
        [server didEncodeSampleBuffer:sampleBuffer status:callbackStatus infoFlags:flags];
        [server finishEncodingFrame];
      }
    }
  );
  CVPixelBufferRelease(pixelBuffer);
  if (status != noErr || ((encodeFlags & kVTEncodeInfo_FrameDropped) && !(encodeFlags & kVTEncodeInfo_Asynchronous))) {
    BOOL shouldFinish = NO;
    @synchronized (self) {
      if (!frameFinished) {
        frameFinished = YES;
        shouldFinish = YES;
      }
    }
    if (shouldFinish) {
      [self markStreamDiscontinuity];
      [self finishEncodingFrame];
    }
    if (status != noErr) {
      [FBLogger logFmt:@"StupidMirror H.264 encode submission failed: %@", @(status)];
    }
  }
  [self scheduleNextFrameStartedAt:timeStarted];
}

- (BOOL)prepareEncoderWidth:(int32_t)width height:(int32_t)height
{
  if (self.compressionSession != nil && self.encodedWidth == width && self.encodedHeight == height) {
    return YES;
  }
  [self invalidateEncoder];

  NSDictionary *pixelAttributes = @{
    (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
    (__bridge NSString *)kCVPixelBufferWidthKey: @(width),
    (__bridge NSString *)kCVPixelBufferHeightKey: @(height),
    (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{}
  };
  VTCompressionSessionRef session = nil;
  OSStatus status = VTCompressionSessionCreate(
    kCFAllocatorDefault,
    width,
    height,
    kCMVideoCodecType_H264,
    NULL,
    (__bridge CFDictionaryRef)pixelAttributes,
    NULL,
    NULL,
    NULL,
    &session
  );
  if (status != noErr || session == nil) {
    [FBLogger logFmt:@"Cannot create StupidMirror H.264 encoder: %@", @(status)];
    return NO;
  }
  self.compressionSession = session;
  self.encodedWidth = width;
  self.encodedHeight = height;
  NSUInteger fps = self.targetFPS;
  NSUInteger bitrate = self.targetBitrate;
  VTSessionSetProperty(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
  VTSessionSetProperty(session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
  VTSessionSetProperty(session, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel);
  VTSessionSetProperty(session, kVTCompressionPropertyKey_ExpectedFrameRate, (__bridge CFTypeRef)@(fps));
  VTSessionSetProperty(session, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFTypeRef)@(bitrate));
  VTSessionSetProperty(session, kVTCompressionPropertyKey_DataRateLimits, (__bridge CFArrayRef)@[@(bitrate / 8 * 2), @2]);
  VTSessionSetProperty(session, kVTCompressionPropertyKey_MaxKeyFrameInterval, (__bridge CFTypeRef)@(fps));
  VTSessionSetProperty(session, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, (__bridge CFTypeRef)@1.0);
  VTSessionSetProperty(session, kVTCompressionPropertyKey_MaxFrameDelayCount, (__bridge CFTypeRef)@1);
  status = VTCompressionSessionPrepareToEncodeFrames(session);
  if (status != noErr) {
    [FBLogger logFmt:@"Cannot prepare StupidMirror H.264 encoder: %@", @(status)];
    [self invalidateEncoder];
    return NO;
  }
  @synchronized (self) {
    self.needsKeyFrame = YES;
  }
  [FBLogger logFmt:@"StupidMirror H.264 encoder configured: %@x%@ %@ fps %@ bps",
    @(width), @(height), @(fps), @(bitrate)];
  return YES;
}

- (void)invalidateEncoder
{
  if (self.compressionSession != nil) {
    VTCompressionSessionCompleteFrames(self.compressionSession, kCMTimeInvalid);
    VTCompressionSessionInvalidate(self.compressionSession);
    CFRelease(self.compressionSession);
    self.compressionSession = nil;
  }
  self.encodedWidth = 0;
  self.encodedHeight = 0;
}

- (void)didEncodeSampleBuffer:(CMSampleBufferRef)sampleBuffer
                       status:(OSStatus)status
                    infoFlags:(VTEncodeInfoFlags)infoFlags
{
  if (status == noErr && !(infoFlags & kVTEncodeInfo_FrameDropped) &&
      sampleBuffer != nil && CMSampleBufferDataIsReady(sampleBuffer)) {
    @synchronized (self) {
      self.encodedFrames++;
    }
    BOOL isKeyFrame = YES;
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    if (attachments != nil && CFArrayGetCount(attachments) > 0) {
      CFDictionaryRef attachment = CFArrayGetValueAtIndex(attachments, 0);
      isKeyFrame = !CFDictionaryContainsKey(attachment, kCMSampleAttachmentKey_NotSync);
    }
    NSData *annexB = [self annexBDataForSampleBuffer:sampleBuffer keyFrame:isKeyFrame];
    if (annexB.length > 0) {
      [self sendPayload:annexB
      presentationTime:CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
               keyFrame:isKeyFrame];
    } else {
      [self markStreamDiscontinuity];
    }
  } else {
    [self markStreamDiscontinuity];
    if (status != noErr) {
      [FBLogger logFmt:@"StupidMirror H.264 encode failed: %@ flags=%@", @(status), @(infoFlags)];
    }
  }
}

- (void)markStreamDiscontinuity
{
  @synchronized (self) {
    self.droppedFrames++;
    self.srtGeneration++;
    self.srtAwaitingKeyFrame = YES;
    self.needsKeyFrame = YES;
  }
}

- (void)markStreamDiscontinuityForGeneration:(uint64_t)generation
{
  @synchronized (self) {
    if (generation == self.srtGeneration) {
      [self markStreamDiscontinuity];
    }
  }
}

- (void)finishEncodingFrame
{
  @synchronized (self) {
    if (self.inFlightFrameCount > 0) {
      self.inFlightFrameCount--;
    }
  }
}

- (NSData *)annexBDataForSampleBuffer:(CMSampleBufferRef)sampleBuffer keyFrame:(BOOL)isKeyFrame
{
  NSMutableData *result = [NSMutableData data];
  const uint8_t startCode[] = {0, 0, 0, 1};
  CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sampleBuffer);
  int nalLengthSizeValue = 4;
  if (isKeyFrame) {
    if (format == nil) { return nil; }
    size_t parameterSetCount = 0;
    OSStatus countStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
      format, 0, NULL, NULL, &parameterSetCount, &nalLengthSizeValue
    );
    if (countStatus != noErr || parameterSetCount == 0) { return nil; }
    for (size_t index = 0; index < parameterSetCount; index++) {
      const uint8_t *parameterSet = NULL;
      size_t parameterSetSize = 0;
      if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, index, &parameterSet, &parameterSetSize, NULL, NULL
          ) != noErr || parameterSet == NULL || parameterSetSize == 0) {
        return nil;
      }
      [result appendBytes:startCode length:sizeof(startCode)];
      [result appendBytes:parameterSet length:parameterSetSize];
    }
  }

  CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
  size_t totalLength = blockBuffer == nil ? 0 : CMBlockBufferGetDataLength(blockBuffer);
  size_t nalLengthSize = (size_t)nalLengthSizeValue;
  if (totalLength == 0 || nalLengthSize < 1 || nalLengthSize > 4) {
    return nil;
  }
  NSMutableData *avcc = [NSMutableData dataWithLength:totalLength];
  if (CMBlockBufferCopyDataBytes(blockBuffer, 0, totalLength, avcc.mutableBytes) != kCMBlockBufferNoErr) {
    return nil;
  }
  const uint8_t *bytes = avcc.bytes;
  size_t offset = 0;
  while (offset + nalLengthSize <= totalLength) {
    uint32_t nalLength = 0;
    for (size_t index = 0; index < nalLengthSize; index++) {
      nalLength = (nalLength << 8) | bytes[offset + index];
    }
    offset += nalLengthSize;
    if (nalLength == 0 || offset + nalLength > totalLength) {
      return nil;
    }
    [result appendBytes:startCode length:sizeof(startCode)];
    [result appendBytes:bytes + offset length:nalLength];
    offset += nalLength;
  }
  return offset == totalLength ? result : nil;
}

- (void)sendPayload:(NSData *)payload presentationTime:(CMTime)presentationTime keyFrame:(BOOL)isKeyFrame
{
  uint64_t generation;
  @synchronized (self) {
    if (!self.isRunning) { return; }
    if (self.srtAwaitingKeyFrame && !isKeyFrame) {
      self.droppedFrames++;
      self.needsKeyFrame = YES;
      return;
    }
    if (self.srtPendingFrames >= SMH264MaximumPendingFrames) {
      [self markStreamDiscontinuity];
      return;
    }
    // Admitting an IDR establishes a new ordered chain. A later enqueue or
    // send failure invalidates its generation, including already queued P
    // frames, before another chain can be admitted.
    if (isKeyFrame) { self.srtAwaitingKeyFrame = NO; }
    generation = self.srtGeneration;
    self.srtPendingFrames++;
  }
  __weak typeof(self) weakSelf = self;
  dispatch_async(self.srtSendQueue, ^{
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (strongSelf != nil) {
      [strongSelf sendSRTPayloadOnSendQueue:payload
                           presentationTime:presentationTime
                                  keyFrame:isKeyFrame
                                generation:generation];
      @synchronized (strongSelf) {
        if (strongSelf.srtPendingFrames > 0) {
          strongSelf.srtPendingFrames--;
        }
      }
    }
  });
}

- (void)sendSRTPayloadOnSendQueue:(NSData *)annexB
                 presentationTime:(CMTime)presentationTime
                        keyFrame:(BOOL)isKeyFrame
                      generation:(uint64_t)generation
{
  __block SRTSOCKET client = SRT_INVALID_SOCK;
  __block uint32_t frameID = 0;
  @synchronized (self) {
    if (!self.isRunning || generation != self.srtGeneration) {
      self.droppedFrames++;
      return;
    }
    client = self.srtClient;
    frameID = self.srtFrameID++;
  }
  if (client == SRT_INVALID_SOCK || srt_getsockstate(client) != SRTS_CONNECTED) {
    [self markStreamDiscontinuityForGeneration:generation];
    return;
  }
  Float64 seconds = CMTimeGetSeconds(presentationTime);
  uint64_t presentationMicros = isfinite(seconds) && seconds >= 0
    ? (uint64_t)llround(seconds * 1000000.0)
    : 0;
  NSUInteger fragmentCountValue = (annexB.length + SMSRTMaximumPayloadSize - 1) /
    SMSRTMaximumPayloadSize;
  if (fragmentCountValue == 0 || fragmentCountValue > UINT16_MAX) {
    [self markStreamDiscontinuityForGeneration:generation];
    return;
  }
  uint16_t fragmentCount = (uint16_t)fragmentCountValue;
  uint32_t networkFrameID = CFSwapInt32HostToBig(frameID);
  uint64_t networkPresentationMicros = CFSwapInt64HostToBig(presentationMicros);
  uint16_t networkFragmentCount = CFSwapInt16HostToBig(fragmentCount);
  const uint8_t magic[] = {'S', 'M', 'S', '2'};
  // Reuse one fixed packet buffer; an IDR no longer allocates an Objective-C
  // object for every 1,292-byte fragment.
  uint8_t message[SMSRTMaximumMessageSize];
  memcpy(message, magic, sizeof(magic));
  memcpy(message + 4, &networkFrameID, sizeof(networkFrameID));
  memcpy(message + 8, &networkPresentationMicros, sizeof(networkPresentationMicros));
  memcpy(message + 18, &networkFragmentCount, sizeof(networkFragmentCount));
  message[20] = isKeyFrame ? 1 : 0;
  memset(message + 21, 0, 3);
  BOOL sendFailed = NO;
  for (uint16_t index = 0; index < fragmentCount; index++) {
    NSUInteger offset = (NSUInteger)index * SMSRTMaximumPayloadSize;
    NSUInteger length = MIN(SMSRTMaximumPayloadSize, annexB.length - offset);
    uint16_t networkIndex = CFSwapInt16HostToBig(index);
    memcpy(message + 16, &networkIndex, sizeof(networkIndex));
    memcpy(message + SMSRTHeaderSize, (const uint8_t *)annexB.bytes + offset, length);
    int messageLength = (int)(SMSRTHeaderSize + length);
    int sent = srt_sendmsg(client, (const char *)message, messageLength, 200, 0);
    if (sent != messageLength) {
      sendFailed = YES;
      break;
    }
  }
  @synchronized (self) {
    if (sendFailed) {
      // A failure from an old client/generation must not discard an IDR
      // already queued for a replacement client.
      [self markStreamDiscontinuityForGeneration:generation];
    } else {
      self.sentFrames++;
    }
  }
}

- (void)stop
{
  self.isRunning = NO;
  __block SRTSOCKET listener = SRT_INVALID_SOCK;
  __block SRTSOCKET client = SRT_INVALID_SOCK;
  @synchronized (self) {
    listener = self.srtListener;
    client = self.srtClient;
    self.srtListener = SRT_INVALID_SOCK;
    self.srtClient = SRT_INVALID_SOCK;
  }
  if (listener != SRT_INVALID_SOCK) {
    srt_close(listener);
  }
  if (client != SRT_INVALID_SOCK) {
    srt_close(client);
  }
  // Only the capture queue may touch the encoder or its pool. In particular,
  // do not invalidate it while another thread is rendering into a pool buffer.
  // The synchronous barrier also makes this safe when called from dealloc.
  __unsafe_unretained typeof(self) server = self;
  void (^releaseEncoder)(void) = ^{
    [server invalidateEncoder];
    [server.ciContext clearCaches];
  };
  if (dispatch_get_specific(SMH264CaptureQueueKey) == (__bridge void *)self) {
    releaseEncoder();
  } else {
    dispatch_sync(self.captureQueue, releaseEncoder);
  }
}

- (void)dealloc
{
  [self stop];
}

@end
