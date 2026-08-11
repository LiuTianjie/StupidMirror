// Compiled into FBMjpegServer.m by scripts/patch-wda-for-control.sh.
// Keeping this implementation in one include avoids changing WDA's Xcode
// project while still giving StupidMirror a separately versioned stream.

@import CoreImage;
@import CoreMedia;
@import CoreVideo;
@import VideoToolbox;

static const uint16_t SMH264DefaultPort = 9200;
static const NSUInteger SMH264DefaultFPS = 45;
static const NSUInteger SMH264DefaultSourceQuality = 90;
static const NSUInteger SMH264DefaultBitrate = 16000000;
static const NSTimeInterval SMH264FrameTimeout = 1.0;
static NSString *const SMH264ServerName = @"StupidMirror H264 Server";

@class FBStupidMirrorH264Server;

static void SMH264CompressionOutputCallback(
  void *outputCallbackRefCon,
  void *sourceFrameRefCon,
  OSStatus status,
  VTEncodeInfoFlags infoFlags,
  CMSampleBufferRef sampleBuffer
);

@interface FBStupidMirrorH264Server : NSObject <FBTCPSocketDelegate>

@property (nonatomic, readonly) dispatch_queue_t captureQueue;
@property (nonatomic, readonly) NSMutableArray<GCDAsyncSocket *> *clients;
@property (nonatomic, readonly) FBTCPSocket *broadcaster;
@property (nonatomic, readonly) CIContext *ciContext;
@property (nonatomic, readonly) long long mainScreenID;
@property (nonatomic, assign) VTCompressionSessionRef compressionSession;
@property (nonatomic, assign) int32_t encodedWidth;
@property (nonatomic, assign) int32_t encodedHeight;
@property (nonatomic, assign) BOOL isRunning;
@property (nonatomic, assign) NSUInteger inFlightFrameCount;
@property (nonatomic, assign) BOOL needsKeyFrame;
@property (nonatomic, assign) NSUInteger sentFrames;
@property (nonatomic, assign) NSUInteger sentBytes;

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
      dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0)
    );
    _clients = [NSMutableArray array];
    _ciContext = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];
    _mainScreenID = [XCUIScreen.mainScreen displayID];
    _encodedWidth = 0;
    _encodedHeight = 0;
    _isRunning = YES;
    _inFlightFrameCount = 0;
    _needsKeyFrame = YES;
    _sentFrames = 0;
    _sentBytes = 0;
    _broadcaster = [[FBTCPSocket alloc] initWithPort:port];
    _broadcaster.delegate = self;
    NSError *error;
    if (![_broadcaster startWithError:&error]) {
      [FBLogger logFmt:@"Cannot start StupidMirror H.264 stream on port %@: %@", @(port), error.description];
      _broadcaster.delegate = nil;
      _broadcaster = nil;
      _isRunning = NO;
      return self;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_async(_captureQueue, ^{
      [weakSelf captureNextFrame];
    });
    [FBLogger logFmt:@"StupidMirror H.264 stream listening on port %@", @(port)];
  }
  return self;
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
  @synchronized (self.clients) {
    return self.clients.count > 0;
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
  VTSessionSetProperty(session, kVTCompressionPropertyKey_MaxKeyFrameInterval, (__bridge CFTypeRef)@(fps * 2));
  VTSessionSetProperty(session, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, (__bridge CFTypeRef)@2.0);
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
  uint32_t payloadLength = CFSwapInt32HostToBig((uint32_t)payload.length);
  Float64 seconds = CMTimeGetSeconds(presentationTime);
  uint64_t micros = isfinite(seconds) && seconds >= 0 ? (uint64_t)llround(seconds * 1000000.0) : 0;
  uint64_t presentationMicros = CFSwapInt64HostToBig(micros);
  uint8_t flags = isKeyFrame ? 1 : 0;
  uint8_t reserved[3] = {0, 0, 0};
  NSMutableData *packet = [NSMutableData dataWithCapacity:16 + payload.length];
  [packet appendBytes:&payloadLength length:sizeof(payloadLength)];
  [packet appendBytes:&presentationMicros length:sizeof(presentationMicros)];
  [packet appendBytes:&flags length:sizeof(flags)];
  [packet appendBytes:reserved length:sizeof(reserved)];
  [packet appendData:payload];

  @synchronized (self.clients) {
    NSArray<GCDAsyncSocket *> *clients = self.clients.copy;
    for (GCDAsyncSocket *client in clients) {
      [client writeData:packet withTimeout:SMH264FrameTimeout tag:1];
    }
    self.sentFrames++;
    self.sentBytes += packet.length * clients.count;
    if (self.sentFrames % MAX(self.targetFPS, 1) == 0) {
      [FBLogger verboseLog:[NSString stringWithFormat:@"StupidMirror H.264 stats: clients=%@ frames=%@ bytes=%@",
        @(clients.count), @(self.sentFrames), @(self.sentBytes)]];
    }
  }
}

- (void)didClientConnect:(GCDAsyncSocket *)newClient
{
  [newClient readDataWithTimeout:-1 tag:0];
}

- (void)didClientSendData:(GCDAsyncSocket *)client
{
  @synchronized (self.clients) {
    if ([self.clients containsObject:client]) {
      return;
    }
    [self.clients addObject:client];
  }
  NSString *header = [NSString stringWithFormat:
    @"HTTP/1.0 200 OK\r\nServer: %@\r\nConnection: close\r\nCache-Control: no-cache, private\r\nContent-Type: application/x-stupidmirror-h264\r\n\r\n",
    SMH264ServerName];
  NSMutableData *response = [[header dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
  const uint8_t magic[] = {'S', 'M', 'H', '1'};
  [response appendBytes:magic length:sizeof(magic)];
  [client writeData:response withTimeout:SMH264FrameTimeout tag:0];
  @synchronized (self) {
    self.needsKeyFrame = YES;
  }
  [FBLogger logFmt:@"Starting StupidMirror H.264 stream for %@:%@", client.connectedHost, @(client.connectedPort)];
}

- (void)didClientDisconnect:(GCDAsyncSocket *)client
{
  @synchronized (self.clients) {
    [self.clients removeObject:client];
  }
}

- (void)stop
{
  self.isRunning = NO;
  [self.broadcaster stop];
  @synchronized (self.clients) {
    NSArray<GCDAsyncSocket *> *clients = self.clients.copy;
    [self.clients removeAllObjects];
    for (GCDAsyncSocket *client in clients) {
      [client disconnect];
    }
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
