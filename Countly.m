// Countly.m
//
// This code is provided under the MIT License.
//
// Please visit www.count.ly for more information.

#import "Countly.h"
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonKeyDerivation.h>
#include <sys/sysctl.h>

#if defined(__IPHONE_OS_VERSION_MIN_REQUIRED)
#import <UIKit/UIKit.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <CoreTelephony/CTCarrier.h>
#endif

#define COUNTLY_DEBUG

#ifdef COUNTLY_DEBUG
#   define COUNTLY_LOG(fmt, ...) NSLog(fmt, ## __VA_ARGS__)
#else
#   define COUNTLY_LOG(...)
#endif

#if !__has_feature(objc_arc)
#error Countly must be built with ARC.
#endif

NSString * const CountlyUserDefaultsUUID = @"CountlyUUID";

static NSString *kCountlyVersion = @"1.0";

static NSString * CLYPercentEscapedQueryStringPairMemberFromStringWithEncoding(NSString *string) {
    static NSString *const kCLYCharactersToBeEscaped = @":/?&=;+!@#$()~',";
    static NSString *const kCLYCharactersToLeaveUnescaped = @"[].";
    
    return (__bridge_transfer NSString *)CFURLCreateStringByAddingPercentEscapes(kCFAllocatorDefault, (__bridge CFStringRef)string, (__bridge CFStringRef)kCLYCharactersToLeaveUnescaped, (__bridge CFStringRef)kCLYCharactersToBeEscaped, CFStringConvertNSStringEncodingToEncoding(NSUTF8StringEncoding));
}

static NSData * CLYDigest(NSData *data, unsigned char * (*cc_digest)(const void *, CC_LONG, unsigned char *), CC_LONG digestLength) {
    unsigned char md[digestLength];
    
    memset(md, 0, sizeof(md));
    cc_digest([data bytes], (CC_LONG)[data length], md);
    return [NSData dataWithBytes:md length:sizeof(md)];
}

static NSData * CLYSHA1Hash(NSData *data) {
    return CLYDigest(data, CC_SHA1, CC_SHA1_DIGEST_LENGTH);
}

static NSString * CLYHexStringFromData(NSData *data) {
    NSUInteger capacity = data.length * 2;
    NSMutableString *stringBuffer = [NSMutableString stringWithCapacity:capacity];
    const unsigned char *dataBuffer = data.bytes;
    NSInteger i;
    
    for (i = 0; i < data.length; ++i) {
        [stringBuffer appendFormat:@"%02lx", (long)dataBuffer[i]];
    }
    
    return [[NSString stringWithString:stringBuffer]lowercaseString];
}

static NSString * CLYUUIDString() {
    CFUUIDRef uid = CFUUIDCreate(kCFAllocatorDefault);
    CFStringRef tmpString = CFUUIDCreateString(kCFAllocatorDefault, uid);
    
    CFRelease(uid);
    return (__bridge_transfer NSString *)tmpString;
}

static NSString * CLYSystemInfoForKey(char *key) {
    size_t size;
    
    sysctlbyname(key, NULL, &size, NULL, 0);
    char *answer = malloc(size);
    sysctlbyname(key, answer, &size, NULL, 0);
    NSString *results = [NSString stringWithCString:answer encoding:NSUTF8StringEncoding];
    free(answer);
    return results;
}

@interface CLYEvent : NSObject

@property (nonatomic, copy) NSString *key;
@property (nonatomic) NSDictionary *segmentation;
@property (nonatomic) NSUInteger count;
@property (nonatomic) CGFloat sum;
@property (nonatomic) time_t timestamp;

@end

@implementation CLYEvent

@end

@interface CLYEventQueue : NSObject {
    NSMutableArray *_events;
    dispatch_queue_t _queue;
}

@end

@implementation CLYEventQueue

- (id)init {
    if (self = [super init]) {
        _events = [[NSMutableArray alloc] init];
        _queue = dispatch_queue_create("com.countly.eventqueue", DISPATCH_QUEUE_CONCURRENT);
    }
    
    return self;
}

- (NSUInteger)count {
    __block NSUInteger retValue;
    
    dispatch_sync(_queue, ^{
        retValue = [_events count];
    });
    
    return retValue;
}

- (NSArray *)flushAllEvents {
    __block NSArray *retEvents = nil;
    
    dispatch_barrier_sync(_queue, ^{
        if (_events.count > 0) {
            retEvents = [_events copy];
            [_events removeAllObjects];
        }
    });
    
    return retEvents;
}

- (void)recordEvent:(NSString *)key segmentation:(NSDictionary *)segmentation count:(NSUInteger)count sum:(CGFloat)sum {
    dispatch_barrier_async(_queue, ^{
        __block BOOL identicalEventFound = NO;
        
        [_events enumerateObjectsUsingBlock:^(CLYEvent *event, NSUInteger idx, BOOL *stop) {
            if ([event.key
                 isEqualToString:key] && (!segmentation || [segmentation isEqualToDictionary:event.segmentation])) {
                event.count += count;
                event.sum += sum;
                event.timestamp = (event.timestamp + time(NULL)) / 2;
                
                identicalEventFound = YES;
                *stop = identicalEventFound;
            }
        }];
        
        if (!identicalEventFound) {
            CLYEvent *event = [[CLYEvent alloc] init];
            event.key = key;
            event.segmentation = segmentation;
            event.count = count;
            event.sum = sum;
            event.timestamp = time(NULL);
            [_events addObject:event];
        }
    });
}

@end


@interface Countly () {
#if defined(__IPHONE_OS_VERSION_MIN_REQUIRED)
    UIBackgroundTaskIdentifier _backgroundTaskIdentifier;
#endif
}

@property (nonatomic) NSTimer *sessionTimer;
@property (nonatomic) NSMutableArray *httpQueue;
@property (nonatomic) NSURLConnection *connection;
@property (nonatomic) CFTimeInterval sessionsLastTime;
@property (nonatomic) BOOL sessionStarted;
@property (nonatomic) CLYEventQueue *eventQueue;
@property (nonatomic) NSString *appKey;
@property (nonatomic) NSString *appHost;
@property (nonatomic) NSString *UUID;
@end

@implementation Countly

#pragma mark - Setup and Teardown

+ (instancetype)sharedInstance {
    static Countly *_sharedInstance = nil;
    static dispatch_once_t oncePredicate;
    
    dispatch_once(&oncePredicate, ^{
        _sharedInstance = [[self alloc] init];
    });
    
    return _sharedInstance;
}

- (id)init {
    if (self = [super init]) {
        NSAssert([NSThread isMainThread], @"Countly class should be initialized on the main thread");
        
        self.UUID = [[[NSUserDefaults standardUserDefaults] objectForKey:@"OpenUDID"] objectForKey:@"OpenUDID"]; //legacy UDID
        
        if (!self.UUID) {
            self.UUID = [[NSUserDefaults standardUserDefaults] objectForKey:CountlyUserDefaultsUUID];
            
            if (!self.UUID) {
                NSString *uudid = CLYUUIDString();
                NSData *hash = CLYSHA1Hash([uudid dataUsingEncoding:NSUTF8StringEncoding]);
                self.UUID = CLYHexStringFromData(hash);
                [[NSUserDefaults standardUserDefaults] setObject:self.UUID forKey:CountlyUserDefaultsUUID];
                [[NSUserDefaults standardUserDefaults] synchronize];
            }
        }
        
        self.httpQueue = [[NSMutableArray alloc] init];
        self.eventQueue = [[CLYEventQueue alloc] init];

#if defined(__IPHONE_OS_VERSION_MIN_REQUIRED)
        _backgroundTaskIdentifier = UIBackgroundTaskInvalid;
#endif
        
#if defined(__IPHONE_OS_VERSION_MIN_REQUIRED)
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didEnterBackgroundNotification:) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(willEnterForegroundNotification:) name:UIApplicationWillEnterForegroundNotification object:nil];
#endif
    }
    
    return self;
}

- (void)dealloc {
#if defined(__IPHONE_OS_VERSION_MIN_REQUIRED)
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidEnterBackgroundNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationWillEnterForegroundNotification object:nil];
#endif
    [self.sessionTimer invalidate];
    [self.connection cancel];
}

#pragma mark - Public Methods

- (void)start:(NSString *)appKey withHost:(NSString *)appHost {
    NSParameterAssert(appKey);
    NSParameterAssert(appHost);
    
    self.appKey = appKey;
    self.appHost = appHost;
    self.sessionStarted = YES;
}

- (void)recordEvent:(NSString *)key count:(NSUInteger)count {
    [self recordEvent:key segmentation:nil count:count sum:0.];
}

- (void)recordEvent:(NSString *)key count:(NSUInteger)count sum:(CGFloat)sum {
    [self recordEvent:key segmentation:nil count:count sum:sum];
}

- (void)recordEvent:(NSString *)key segmentation:(NSDictionary *)segmentation count:(NSUInteger)count {
    [self recordEvent:key segmentation:segmentation count:count sum:0.];
}

- (void)recordEvent:(NSString *)key segmentation:(NSDictionary *)segmentation count:(NSUInteger)count sum:(CGFloat)sum {
    NSParameterAssert(key);
#ifdef DEBUG
    [segmentation.allKeys enumerateObjectsWithOptions:0 usingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        NSAssert([obj isKindOfClass:[NSString class]], @"keys of the segmentation dictionary should be NSString objects");
    }];
    [segmentation.allValues enumerateObjectsWithOptions:0 usingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        NSAssert([obj isKindOfClass:[NSString class]] || [obj isKindOfClass:[NSNumber class]], @"keys of the segmentation dictionary should be NSString or NSNumber objects");
    }];
#endif
    
    [self.eventQueue recordEvent:key segmentation:segmentation count:count sum:sum];
    
    if (self.eventQueue.count >= 5) [self recordPendingEvents];
}

#pragma mark - Session Management

- (void)setSessionStarted:(BOOL)sessionStarted {
    if (sessionStarted != _sessionStarted) {
        _sessionStarted = sessionStarted;
        if (sessionStarted) {
            [self beginSession];
            [self.sessionTimer invalidate];
            self.sessionTimer = [NSTimer scheduledTimerWithTimeInterval:30.0 target:self selector:@selector(timerFired:) userInfo:nil repeats:YES];
            self.sessionsLastTime = CFAbsoluteTimeGetCurrent();
        }
        else {
            [self.sessionTimer invalidate];
            self.sessionTimer = nil;
            [self recordPendingEvents];
            [self endSession];
        }
    }
}

- (void)timerFired:(NSTimer *)timer {
    if (self.sessionStarted) {
        [self recordPendingEvents];
        [self updateSession];
    }
}

#pragma mark - Notifications

#if defined(__IPHONE_OS_VERSION_MIN_REQUIRED)
- (void)didEnterBackgroundNotification:(NSNotification *)notification {
    COUNTLY_LOG(@"Countly didEnterBackgroundCallBack");
    self.sessionStarted = NO;
}

- (void)willEnterForegroundNotification:(NSNotification *)notification {
    COUNTLY_LOG(@"Countly willEnterForegroundCallBack");
    self.sessionStarted = YES;
}
#endif

#pragma mark - Back-End API

- (void)beginSession {
    
    NSMutableDictionary *metrics = [NSMutableDictionary dictionary];
    
    // LOCALE
    [metrics setObject:[[NSLocale currentLocale] localeIdentifier] forKey:@"_locale"];
    
    
    // APP VERSION
    {
        NSString *version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
        
        if ([version length] == 0) version = [[NSBundle mainBundle] objectForInfoDictionaryKey:(NSString *)kCFBundleVersionKey];
        
        [metrics setObject:version forKey:@"_app_version"];
    }
    
    // DEVICE
#if defined(__IPHONE_OS_VERSION_MIN_REQUIRED)
    [metrics setObject:CLYSystemInfoForKey("hw.machine") forKey:@"_device"];
#else
    [metrics setObject:CLYSystemInfoForKey("hw.model") forKey:@"_device"];
#endif
    
    // OS
#if defined(__IPHONE_OS_VERSION_MIN_REQUIRED)
    [metrics setObject:@"iOS" forKey:@"_os"];
#else
    [metrics setObject:@"MAC" forKey:@"_os"];
#endif
    
    
    // OS VERSION
#if defined(__IPHONE_OS_VERSION_MIN_REQUIRED)
    [metrics setObject:[[UIDevice currentDevice] systemVersion] forKey:@"_os_version"];
#else
    {
        SInt32 versionMajor = 0, versionMinor = 0, versionBugFix = 0;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        Gestalt(gestaltSystemVersionMajor, &versionMajor);
        Gestalt(gestaltSystemVersionMinor, &versionMinor);
        Gestalt(gestaltSystemVersionBugFix, &versionBugFix);
#pragma clang diagnostic pop
        NSString *version = [NSString stringWithFormat:@"%d.%d.%d", versionMajor, versionMinor, versionBugFix];
        
        [metrics setObject:version forKey:@"_os_version"];
    }
#endif
    
    // RESOLUTION
#if defined(__IPHONE_OS_VERSION_MIN_REQUIRED)
    {
        CGRect bounds = [[UIScreen mainScreen] bounds];
        CGFloat scale = [[UIScreen mainScreen] scale];
        CGSize res = CGSizeMake(bounds.size.width * scale, bounds.size.height * scale);
        NSString *resolution = [NSString stringWithFormat:@"%gx%g", res.width, res.height];
        
        [metrics setObject:resolution forKey:@"_resolution"];
    }
#else
    {
        NSRect frame = [[NSScreen mainScreen] frame];
        NSRect res = [[NSScreen mainScreen] convertRectToBacking:frame];
        NSString *resolution = [NSString stringWithFormat:@"%gx%g", res.size.width, res.size.height];
        
        [metrics setObject:resolution forKey:@"_resolution"];
    }
#endif
    
    
    // CARRIER
#if defined(__IPHONE_OS_VERSION_MIN_REQUIRED)
    {
        CTTelephonyNetworkInfo *netinfo = [[CTTelephonyNetworkInfo alloc] init];
        NSString *carrierName = [[netinfo subscriberCellularProvider] carrierName];
        
        if (carrierName) [metrics setObject:carrierName forKey:@"_carrier"];
    }
#endif
    
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:metrics options:0 error:nil];
    
    NSString *jsonEncodedMetrics = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    
    
    NSString *data = [NSString stringWithFormat:@"app_key=%@&device_id=%@&timestamp=%ld&sdk_version=%@&begin_session=1&metrics=%@",
                      CLYPercentEscapedQueryStringPairMemberFromStringWithEncoding(self.appKey),
                      CLYPercentEscapedQueryStringPairMemberFromStringWithEncoding(self.UUID),
                      time(NULL),
                      kCountlyVersion,
                      CLYPercentEscapedQueryStringPairMemberFromStringWithEncoding(jsonEncodedMetrics)];
    
    [self.httpQueue addObject:data];
    [self tick];
}

- (void)updateSession {
    CFTimeInterval lastTime = CFAbsoluteTimeGetCurrent();
    CFTimeInterval duration = lastTime - self.sessionsLastTime;
    self.sessionsLastTime = lastTime;
    
    NSString *data = [NSString stringWithFormat:@"app_key=%@&device_id=%@&timestamp=%ld&session_duration=%d",
                      CLYPercentEscapedQueryStringPairMemberFromStringWithEncoding(self.appKey),
                      CLYPercentEscapedQueryStringPairMemberFromStringWithEncoding(self.UUID),
                      time(NULL),
                      (int)duration];
    
    [self.httpQueue addObject:data];
    [self tick];
}

- (void)endSession {
    CFTimeInterval lastTime = CFAbsoluteTimeGetCurrent();
    CFTimeInterval duration = lastTime - self.sessionsLastTime;
    self.sessionsLastTime = lastTime;
    
    NSString *data = [NSString stringWithFormat:@"app_key=%@&device_id=%@&timestamp=%ld&end_session=1&session_duration=%d",
                      CLYPercentEscapedQueryStringPairMemberFromStringWithEncoding(self.appKey),
                      CLYPercentEscapedQueryStringPairMemberFromStringWithEncoding(self.UUID),
                      time(NULL),
                      (int)duration];
    
    [self.httpQueue addObject:data];
    [self tick];
}

- (void)recordPendingEvents {
    NSArray *events = [self.eventQueue flushAllEvents];
    if (events.count > 0) {
        
        NSMutableArray *mutableArray = [NSMutableArray array];
        
        [events enumerateObjectsWithOptions:0 usingBlock:^(CLYEvent *event, NSUInteger idx, BOOL *stop) {
            NSMutableDictionary *mutableDictionary = [NSMutableDictionary dictionary];
            [mutableDictionary setObject:event.key forKey:@"key"];
            [mutableDictionary setObject:@(event.count) forKey:@"count"];
            [mutableDictionary setObject:@(event.timestamp) forKey:@"timestamp"];
            if (event.sum > 0) [mutableDictionary setObject:@(event.sum) forKey:@"sum"];
            if (event.segmentation.allKeys.count > 0) [mutableDictionary setObject:event.segmentation forKey:@"segmentation"];
            
            [mutableArray addObject:mutableDictionary];
        }];
                
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:mutableArray options:0 error:nil];
        NSString *jsonEncodedEvents = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        
        NSString *data = [NSString stringWithFormat:@"app_key=%@&device_id=%@&timestamp=%ld&events=%@",
                          CLYPercentEscapedQueryStringPairMemberFromStringWithEncoding(self.appKey),
                          CLYPercentEscapedQueryStringPairMemberFromStringWithEncoding(self.UUID),
                          time(NULL),
                          CLYPercentEscapedQueryStringPairMemberFromStringWithEncoding(jsonEncodedEvents)];
        
        [self.httpQueue addObject:data];
        [self tick];
    }
}

#pragma mark - HTTP Connection

- (void)tick {    
    if (self.connection || [self.httpQueue count] == 0) return;
    
#if defined(__IPHONE_OS_VERSION_MIN_REQUIRED)
    _backgroundTaskIdentifier = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
        [self endBackgroundTask];
    }];
#endif
    
    NSString *data = [self.httpQueue objectAtIndex:0];
    NSString *urlString = [NSString stringWithFormat:@"%@/i?%@", self.appHost, data];
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    self.connection = [NSURLConnection connectionWithRequest:request delegate:self];
}

- (void)endBackgroundTask {
    self.connection = nil;
#if defined(__IPHONE_OS_VERSION_MIN_REQUIRED)
    UIApplication *app = [UIApplication sharedApplication];
    [app endBackgroundTask:_backgroundTaskIdentifier];
    _backgroundTaskIdentifier = UIBackgroundTaskInvalid;
#endif
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
    COUNTLY_LOG(@"ok -> %@", [self.httpQueue objectAtIndex:0]);
    [self endBackgroundTask];
    [self.httpQueue removeObjectAtIndex:0];
    [self tick];
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)err {
    COUNTLY_LOG(@"error -> %@: %@", [self.httpQueue objectAtIndex:0], err);
    [self endBackgroundTask];
}

#ifdef COUNTLY_ALLOW_INVALID_SSL_CERTIFICATES
- (void)connection:(NSURLConnection *)connection willSendRequestForAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge {
    if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) [challenge.sender useCredential:[NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust] forAuthenticationChallenge:challenge];
    
    [[challenge sender] continueWithoutCredentialForAuthenticationChallenge:challenge];
}

#endif

@end
