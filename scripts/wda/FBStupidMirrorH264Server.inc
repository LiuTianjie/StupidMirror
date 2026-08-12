// Compiled into FBMjpegServer.m by scripts/patch-wda-for-control.sh.
// Keeping this implementation in one include avoids changing WDA's Xcode
// project while still giving StupidMirror a separately versioned stream.

@import CoreImage;
@import CoreMedia;
@import CoreVideo;
@import VideoToolbox;
#import <libsrt/srt.h>
#import <netinet/in.h>

static const uint16_t SMH264DefaultPort = 9200;
static const NSUInteger SMH264DefaultFPS = 45;
static const NSUInteger SMH264DefaultSourceQuality = 80;
static const NSUInteger SMH264DefaultBitrate = 8000000;
static const NSTimeInterval SMH264FrameTimeout = 1.0;
static const NSUInteger SMSRTMaximumMessageSize = 1316;
static const NSUInteger SMSRTHeaderSize = 24;
static const NSUInteger SMSRTMaximumPayloadSize = SMSRTMaximumMessageSize - SMSRTHeaderSize;

// Export startup health through WDA's existing /status response. This keeps
// transport observability on the same probe the desktop already performs.
volatile int SMStupidMirrorSRTStartupState = 0;
char SMStupidMirrorSRTStartupError[512] = {0};

@class FBStupidMirrorH264Server;

static void SMH264CompressionOutputCallback(
  void *outputCallbackRefCon,
  void *sourceFrameRefCon,
  OSStatus status,
  VTEncodeInfoFlags infoFlags,
  CMSampleBufferRef sampleBuffer
);

@interface FBStupidMirrorH264Server : NSObject

@property (nonatomic, readonly) dispatch_queue_t captureQueue;
@property (nonatomic, readonly) dispatch_queue_t srtAcceptQueue;
@property (nonatomic, readonly) dispatch_queue_t srtSendQueue;
@property (nonatomic, readonly) CIContext *ciContext;
@property (nonatomic, readonly) long long mainScreenID;
@property (nonatomic, assign) VTCompressionSessionRef compressionSession;
@property (nonatomic, assign) int32_t encodedWidth;
@property (nonatomic, assign) int32_t encodedHeight;
@property (nonatomic, assign) BOOL isRunning;
@property (nonatomic, assign) NSUInteger inFlightFrameCount;
@property (nonatomic, assign) BOOL needsKeyFrame;
@property (nonatomic, assign) SRTSOCKET srtListener;
@property (nonatomic, assign) SRTSOCKET srtClient;
@property (nonatomic, assign) uint32_t srtFrameID;
@property (nonatomic, assign) NSUInteger srtPendingFrames;

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
    _captureQueue = dispatch_queue_create(
      "com.stupidmirror.wda.h264.capture",
      // Keep the 45 fps target, but let XCTest control work preempt capture
      // when both paths contend for device-side automation resources.
      dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0)
    );
    _srtAcceptQueue = dispatch_queue_create(
      "com.stupidmirror.wda.h264.srt-accept",
      dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0)
    );
    _srtSendQueue = dispatch_queue_create(
      "com.stupidmirror.wda.h264.srt-send",
      dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0)
    );
    _ciContext = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];
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
  struct sockaddr_in address = {0};
  address.sin_len = sizeof(address);
  address.sin_family = AF_INET;
  address.sin_port = htons(port);
  address.sin_addr.s_addr = htonl(INADDR_ANY);
  if (!configured ||
      srt_bind(listener, (const struct sockaddr *)&address, sizeof(address)) == SRT_ERROR ||
      srt_listen(listener, 1) == SRT_ERROR) {
    SMStupidMirrorSRTStartupState = -3;
    strlcpy(SMStupidMirrorSRTStartupError, srt_getlasterror_str(), sizeof(SMStupidMirrorSRTStartupError));
    [FBLogger logFmt:@"Cannot start StupidMirror SRT listener: %s", srt_getlasterror_str()];
    srt_close(listener);
    return;
  }
  self.srtListener = listener;
  SMStupidMirrorSRTStartupState = 2;
  SMStupidMirrorSRTStartupError[0] = '\0';
  __weak typeof(self) weakSelf = self;
  dispatch_async(self.srtAcceptQueue, ^{
    [weakSelf acceptSRTClients];
  });
  [FBLogger logFmt:@"StupidMirror SRT/H.264 stream listening on UDP port %@", @(port)];
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
  char buffer[64];
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

- (BOOL)hasClients
{
  @synchronized (self) {
    return self.srtClient != SRT_INVALID_SOCK &&
      srt_getsockstate(self.srtClient) == SRTS_CONNECTED;
  }
}

- (void)captureNextFrame
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
    if (self.inFlightFrameCount < 2) {
      self.inFlightFrameCount++;
      canBeginEncoding = YES;
    }
  }
  if (!canBeginEncoding) {
    [self scheduleNextFrameStartedAt:timeStarted];
    return;
  }

  NSError *error;
  NSData *jpeg = [FBScreenshot takeInOriginalResolutionWithScreenID:self.mainScreenID
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
  if (pool == nil || CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer) != kCVReturnSuccess) {
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
  OSStatus status = VTCompressionSessionEncodeFrame(
    self.compressionSession,
    pixelBuffer,
    presentationTime,
    kCMTimeInvalid,
    (__bridge CFDictionaryRef)frameProperties,
    NULL,
    NULL
  );
  CVPixelBufferRelease(pixelBuffer);
  if (status != noErr) {
    [self finishEncodingFrame];
    [FBLogger logFmt:@"StupidMirror H.264 encode submission failed: %@", @(status)];
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
    SMH264CompressionOutputCallback,
    (__bridge void *)self,
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
  if (status == noErr && sampleBuffer != nil && CMSampleBufferDataIsReady(sampleBuffer)) {
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
    }
  } else if (status != noErr) {
    [FBLogger logFmt:@"StupidMirror H.264 encode failed: %@ flags=%@", @(status), @(infoFlags)];
  }
  [self finishEncodingFrame];
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
  if (isKeyFrame && format != nil) {
    size_t parameterSetCount = 0;
    OSStatus countStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
      format, 0, NULL, NULL, &parameterSetCount, &nalLengthSizeValue
    );
    if (countStatus == noErr) {
      for (size_t index = 0; index < parameterSetCount; index++) {
        const uint8_t *parameterSet = NULL;
        size_t parameterSetSize = 0;
        if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
              format, index, &parameterSet, &parameterSetSize, NULL, NULL
            ) == noErr && parameterSet != NULL && parameterSetSize > 0) {
          [result appendBytes:startCode length:sizeof(startCode)];
          [result appendBytes:parameterSet length:parameterSetSize];
        }
      }
    }
  }

  CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
  size_t totalLength = blockBuffer == nil ? 0 : CMBlockBufferGetDataLength(blockBuffer);
  size_t nalLengthSize = (size_t)nalLengthSizeValue;
  if (totalLength == 0 || nalLengthSize < 1 || nalLengthSize > 4) {
    return result;
  }
  NSMutableData *avcc = [NSMutableData dataWithLength:totalLength];
  if (CMBlockBufferCopyDataBytes(blockBuffer, 0, totalLength, avcc.mutableBytes) != kCMBlockBufferNoErr) {
    return result;
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
      break;
    }
    [result appendBytes:startCode length:sizeof(startCode)];
    [result appendBytes:bytes + offset length:nalLength];
    offset += nalLength;
  }
  return result;
}

- (void)sendPayload:(NSData *)payload presentationTime:(CMTime)presentationTime keyFrame:(BOOL)isKeyFrame
{
  @synchronized (self) {
    if (self.srtPendingFrames >= 2) {
      self.needsKeyFrame = YES;
      return;
    }
    self.srtPendingFrames++;
  }
  __weak typeof(self) weakSelf = self;
  dispatch_async(self.srtSendQueue, ^{
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (strongSelf != nil) {
      [strongSelf sendSRTPayloadOnSendQueue:payload
                           presentationTime:presentationTime
                                  keyFrame:isKeyFrame];
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
{
  __block SRTSOCKET client = SRT_INVALID_SOCK;
  __block uint32_t frameID = 0;
  @synchronized (self) {
    client = self.srtClient;
    frameID = self.srtFrameID++;
  }
  if (client == SRT_INVALID_SOCK || srt_getsockstate(client) != SRTS_CONNECTED) {
    return;
  }
  Float64 seconds = CMTimeGetSeconds(presentationTime);
  uint64_t presentationMicros = isfinite(seconds) && seconds >= 0
    ? (uint64_t)llround(seconds * 1000000.0)
    : 0;
  NSUInteger fragmentCountValue = (annexB.length + SMSRTMaximumPayloadSize - 1) /
    SMSRTMaximumPayloadSize;
  if (fragmentCountValue == 0 || fragmentCountValue > UINT16_MAX) {
    @synchronized (self) {
      self.needsKeyFrame = YES;
    }
    return;
  }
  uint16_t fragmentCount = (uint16_t)fragmentCountValue;
  uint32_t networkFrameID = CFSwapInt32HostToBig(frameID);
  uint64_t networkPresentationMicros = CFSwapInt64HostToBig(presentationMicros);
  uint16_t networkFragmentCount = CFSwapInt16HostToBig(fragmentCount);
  const uint8_t magic[] = {'S', 'M', 'S', '2'};
  BOOL sendFailed = NO;
  for (uint16_t index = 0; index < fragmentCount; index++) {
    NSUInteger offset = (NSUInteger)index * SMSRTMaximumPayloadSize;
    NSUInteger length = MIN(SMSRTMaximumPayloadSize, annexB.length - offset);
    uint16_t networkIndex = CFSwapInt16HostToBig(index);
    uint8_t flags = isKeyFrame ? 1 : 0;
    uint8_t reserved[3] = {0, 0, 0};
    NSMutableData *message = [NSMutableData dataWithCapacity:SMSRTHeaderSize + length];
    [message appendBytes:magic length:sizeof(magic)];
    [message appendBytes:&networkFrameID length:sizeof(networkFrameID)];
    [message appendBytes:&networkPresentationMicros length:sizeof(networkPresentationMicros)];
    [message appendBytes:&networkIndex length:sizeof(networkIndex)];
    [message appendBytes:&networkFragmentCount length:sizeof(networkFragmentCount)];
    [message appendBytes:&flags length:sizeof(flags)];
    [message appendBytes:reserved length:sizeof(reserved)];
    [message appendBytes:(const uint8_t *)annexB.bytes + offset length:length];
    int sent = srt_sendmsg(client, message.bytes, (int)message.length, 200, 0);
    if (sent != (int)message.length) {
      sendFailed = YES;
      break;
    }
  }
  if (sendFailed) {
    @synchronized (self) {
      self.needsKeyFrame = YES;
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
  [self invalidateEncoder];
}

- (void)dealloc
{
  [self stop];
}

@end

static void SMH264CompressionOutputCallback(
  void *outputCallbackRefCon,
  void *sourceFrameRefCon,
  OSStatus status,
  VTEncodeInfoFlags infoFlags,
  CMSampleBufferRef sampleBuffer
)
{
  FBStupidMirrorH264Server *server = (__bridge FBStupidMirrorH264Server *)outputCallbackRefCon;
  [server didEncodeSampleBuffer:sampleBuffer status:status infoFlags:infoFlags];
}
