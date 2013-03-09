// Countly.m
//
// This code is provided under the MIT License.
//
// Please visit www.count.ly for more information.

#import "Countly.h"
#import <Foundation/Foundation.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <CommonCrypto/CommonKeyDerivation.h>
#include <sys/sysctl.h>

#if defined(__IPHONE_OS_VERSION_MIN_REQUIRED)
#import <UIKit/UIKit.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <CoreTelephony/CTCarrier.h>
#endif

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
    
    COUNTLY_LOG(@"flushAllEvents (%lu events)", (unsigned long)retEvents.count);
    
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

typedef NS_ENUM(NSUInteger, CountlySessionState) {
    CountlySessionStateStopped,
    CountlySessionStateBegan,
    CountlySessionStateUpdated,
    CountlySessionStatePending
};

typedef enum {
    CLYNetworkReachabilityStatusUnknown          = -1,
    CLYNetworkReachabilityStatusNotReachable     = 0,
    CLYNetworkReachabilityStatusReachableViaWWAN = 1,
    CLYNetworkReachabilityStatusReachableViaWiFi = 2,
} CLYNetworkReachabilityStatus;

typedef SCNetworkReachabilityRef CLYNetworkReachabilityRef;
typedef void (^CLYNetworkReachabilityStatusBlock)(CLYNetworkReachabilityStatus status);

@interface Countly () 

@property (nonatomic) NSTimer *sessionTimer;
@property (nonatomic) CFTimeInterval sessionsLastTime;
@property (nonatomic) CLYEventQueue *eventQueue;
@property (nonatomic) NSString *appKey;
@property (nonatomic) NSString *appHost;
@property (nonatomic) NSString *UUID;
@property (nonatomic) CountlySessionState sessionState;
@property (nonatomic) BOOL applicationInBackgroundState;
@property (nonatomic) NSOperationQueue *httpOperationQueue;
@property (nonatomic) CLYNetworkReachabilityRef networkReachability;
@property (nonatomic) CLYNetworkReachabilityStatus networkReachabilityStatus;
@property (nonatomic, readonly) BOOL isHostReachable;
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
        
        self.httpOperationQueue = [[NSOperationQueue alloc] init];
        self.httpOperationQueue.maxConcurrentOperationCount = 2;
        
        self.networkReachabilityStatus = CLYNetworkReachabilityStatusUnknown;
        
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
        
        self.eventQueue = [[CLYEventQueue alloc] init];
        
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
    [self stopMonitoringNetworkReachability];
    [self.httpOperationQueue cancelAllOperations];
    [self.sessionTimer invalidate];
}

#pragma mark - Public Methods

- (void)start:(NSString *)appKey withHost:(NSString *)appHost {
    NSParameterAssert(appKey);
    NSParameterAssert(appHost);
    
    self.sessionsLastTime = CFAbsoluteTimeGetCurrent();
    self.appKey = appKey;
    self.appHost = appHost;
    
    [self startMonitoringNetworkReachability];
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
    
    if (!self.isHostReachable && self.networkReachabilityStatus != CLYNetworkReachabilityStatusUnknown) {
        return; // avoid to accumulate events if the connection is failing.
    }
    
#ifdef DEBUG
    [segmentation.allKeys enumerateObjectsWithOptions:0 usingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        NSAssert([obj isKindOfClass:[NSString class]], @"keys of the segmentation dictionary should be NSString objects");
    }];
    [segmentation.allValues enumerateObjectsWithOptions:0 usingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        NSAssert([obj isKindOfClass:[NSString class]] || [obj isKindOfClass:[NSNumber class]], @"keys of the segmentation dictionary should be NSString or NSNumber objects");
    }];
#endif
    
    [self.eventQueue recordEvent:key segmentation:segmentation count:count sum:sum];
    
    if (self.eventQueue.count >= 5) [self sendPendingEvents];
    
}

#pragma mark - Session Management

- (void)updateSessionState {
    if (self.applicationInBackgroundState || !self.isHostReachable) {
        [self.sessionTimer invalidate];
        self.sessionTimer = nil;
    }
    else if (!self.sessionTimer) {
        self.sessionTimer = [NSTimer scheduledTimerWithTimeInterval:30.0 target:self selector:@selector(timerFired:) userInfo:nil repeats:YES];
    }
    
    if (self.sessionState == CountlySessionStateStopped) {
        self.sessionState = CountlySessionStatePending;
        
#if defined(__IPHONE_OS_VERSION_MIN_REQUIRED)
        __block UIBackgroundTaskIdentifier backgroundTaskIdentifier = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
            self.sessionState = CountlySessionStateStopped;
            [[UIApplication sharedApplication] endBackgroundTask:backgroundTaskIdentifier];
        }];
#endif
        [NSURLConnection sendAsynchronousRequest:[self urlRequestForSessionBegin]  queue:self.httpOperationQueue completionHandler:^(NSURLResponse *response, NSData *data, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^(void) {
                if (!error) {
                    self.sessionState = CountlySessionStateBegan;
                }
                else {
                    COUNTLY_LOG(@"updateSessionState - connection error: %@",error);
                    self.sessionState = CountlySessionStateStopped;
                }
#if defined(__IPHONE_OS_VERSION_MIN_REQUIRED)
                [[UIApplication sharedApplication] endBackgroundTask:backgroundTaskIdentifier];
#endif
            });
        }];
    }
    else if (self.sessionState == CountlySessionStateBegan || self.sessionState == CountlySessionStateUpdated) {
        
        CFTimeInterval lastTime = CFAbsoluteTimeGetCurrent();
        CFTimeInterval duration = round(lastTime - self.sessionsLastTime);
        self.sessionsLastTime = lastTime;
        COUNTLY_LOG(@"session duration: %f sec.",duration);
        
        if (duration > 0) {
            self.sessionState = CountlySessionStatePending;
            
#if defined(__IPHONE_OS_VERSION_MIN_REQUIRED)
            __block UIBackgroundTaskIdentifier backgroundTaskIdentifier = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
                self.sessionState = CountlySessionStateBegan;
                [[UIApplication sharedApplication] endBackgroundTask:backgroundTaskIdentifier];
            }];
#endif
            
            [NSURLConnection sendAsynchronousRequest:[self urlRequestForSessionUpdateWithDuration:duration]  queue:self.httpOperationQueue completionHandler:^(NSURLResponse *response, NSData *data, NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^(void) {
                    if (!error) {
                        self.sessionState = CountlySessionStateUpdated;
                    }
                    else {
                        COUNTLY_LOG(@"updateSessionState - connection error: %@",error);
                        self.sessionState = CountlySessionStateBegan;
                    }
#if defined(__IPHONE_OS_VERSION_MIN_REQUIRED)
                    [[UIApplication sharedApplication] endBackgroundTask:backgroundTaskIdentifier];
#endif
                });
            }];
        }
    }
}

- (void)setSessionState:(CountlySessionState)sessionState {
    if (sessionState != _sessionState) {
        _sessionState = sessionState;
#ifdef DEBUG
        if (_sessionState == CountlySessionStateBegan) {
            COUNTLY_LOG(@"session state: began");
        }
        if (_sessionState == CountlySessionStateUpdated) {
            COUNTLY_LOG(@"session state: updated");
        }
        else if (_sessionState == CountlySessionStatePending) {
            COUNTLY_LOG(@"session state: pending");
        }
        else if (_sessionState == CountlySessionStateStopped) {
            COUNTLY_LOG(@"session state: stopped");
        }
#endif
    }
}

- (void)timerFired:(NSTimer *)timer {
    [self sendPendingEvents];
    [self updateSessionState];
}

#pragma mark - Notifications

#if defined(__IPHONE_OS_VERSION_MIN_REQUIRED)
- (void)didEnterBackgroundNotification:(NSNotification *)notification {
    COUNTLY_LOG(@"Countly didEnterBackgroundCallBack");
    self.applicationInBackgroundState = YES;
    [self updateSessionState];
}

- (void)willEnterForegroundNotification:(NSNotification *)notification {
    COUNTLY_LOG(@"Countly willEnterForegroundCallBack");
    self.applicationInBackgroundState = NO;
    self.sessionsLastTime = CFAbsoluteTimeGetCurrent();
    [self updateSessionState];
}
#endif

#pragma mark - Countly Events Management

- (void)sendPendingEvents {
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
        
        NSString *urlString = [NSString stringWithFormat:@"%@/i?%@", self.appHost, data];
        NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:urlString]];
        
#if defined(__IPHONE_OS_VERSION_MIN_REQUIRED)
        __block UIBackgroundTaskIdentifier backgroundTaskIdentifier = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
            [[UIApplication sharedApplication] endBackgroundTask:backgroundTaskIdentifier];
        }];
#endif
        
        COUNTLY_LOG(@"sendPendingEvents - start");
        [NSURLConnection sendAsynchronousRequest:request queue:self.httpOperationQueue completionHandler:^(NSURLResponse *response, NSData *data, NSError *error) {
            COUNTLY_LOG(@"sendPendingEvents - finished");
#if defined(__IPHONE_OS_VERSION_MIN_REQUIRED)
            [[UIApplication sharedApplication] endBackgroundTask:backgroundTaskIdentifier];
#endif
        }];
        
    }
}

#pragma mark - Countly API Requests

- (NSURLRequest *)urlRequestForSessionBegin {
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
    
    NSString *urlString = [NSString stringWithFormat:@"%@/i?%@", self.appHost, data];
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    return request;
}

- (NSURLRequest *)urlRequestForSessionUpdateWithDuration:(CFTimeInterval)duration {
    
    NSString *data = [NSString stringWithFormat:@"app_key=%@&device_id=%@&timestamp=%ld&session_duration=%f",
                      CLYPercentEscapedQueryStringPairMemberFromStringWithEncoding(self.appKey),
                      CLYPercentEscapedQueryStringPairMemberFromStringWithEncoding(self.UUID),
                      time(NULL),
                      round(duration)];
    
    NSString *urlString = [NSString stringWithFormat:@"%@/i?%@", self.appHost, data];
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    return request;
}

#pragma mark - Network Reachability

- (void)setNetworkReachabilityStatus:(CLYNetworkReachabilityStatus)networkReachabilityStatus {
    if (networkReachabilityStatus != _networkReachabilityStatus) {
        _networkReachabilityStatus = networkReachabilityStatus;
        
#ifdef DEBUG
        if (_networkReachabilityStatus == CLYNetworkReachabilityStatusUnknown) {
            COUNTLY_LOG(@"reachability changed: unknown");
        }
        if (_networkReachabilityStatus == CLYNetworkReachabilityStatusNotReachable) {
            COUNTLY_LOG(@"reachability changed: not reachable");
        }
        else {
            COUNTLY_LOG(@"reachability changed: reachable");
        }
#endif
        if (_networkReachabilityStatus != CLYNetworkReachabilityStatusUnknown) {
            [self updateSessionState];
            if (!self.isHostReachable) {
                [self.eventQueue flushAllEvents];
            }
        }
    }
}

- (BOOL)isHostReachable {
    BOOL isHostReachable = (self.networkReachabilityStatus == CLYNetworkReachabilityStatusReachableViaWWAN || self.networkReachabilityStatus == CLYNetworkReachabilityStatusReachableViaWiFi);
    return isHostReachable;
}

// based on the code of AFNetworking (https://github.com/AFNetworking/AFNetworking)

static CLYNetworkReachabilityStatus CLYNetworkReachabilityStatusForFlags(SCNetworkReachabilityFlags flags) {
    BOOL isReachable = ((flags & kSCNetworkReachabilityFlagsReachable) != 0);
    BOOL needsConnection = ((flags & kSCNetworkReachabilityFlagsConnectionRequired) != 0);
    BOOL isNetworkReachable = (isReachable && !needsConnection);
    
    CLYNetworkReachabilityStatus status = CLYNetworkReachabilityStatusUnknown;
    if (isNetworkReachable == NO) {
        status = CLYNetworkReachabilityStatusNotReachable;
    }
#if	TARGET_OS_IPHONE
    else if ((flags & kSCNetworkReachabilityFlagsIsWWAN) != 0) {
        status = CLYNetworkReachabilityStatusReachableViaWWAN;
    }
#endif
    else {
        status = CLYNetworkReachabilityStatusReachableViaWiFi;
    }
    
    return status;
}

static void CLYNetworkReachabilityCallback(SCNetworkReachabilityRef __unused target, SCNetworkReachabilityFlags flags, void *info) {
    CLYNetworkReachabilityStatus status = CLYNetworkReachabilityStatusForFlags(flags);
    CLYNetworkReachabilityStatusBlock block = (__bridge CLYNetworkReachabilityStatusBlock)info;
    if (block) {
        block(status);
    }
}

static const void * CLYNetworkReachabilityRetainCallback(const void *info) {
    return (__bridge_retained const void *)([(__bridge CLYNetworkReachabilityStatusBlock)info copy]);
}

static void CLYNetworkReachabilityReleaseCallback(const void *info) {
    if (info) {
        CFRelease(info);
    }
}

- (void)startMonitoringNetworkReachability {
    [self stopMonitoringNetworkReachability];
    
    if (!self.appHost) {
        return;
    }
    
    self.networkReachability = SCNetworkReachabilityCreateWithName(kCFAllocatorDefault, [[[NSURL URLWithString:self.appHost] host] UTF8String]);
    
    if (!self.networkReachability) {
        return;
    }
    
    __weak __typeof(&*self)weakSelf = self;
    CLYNetworkReachabilityStatusBlock callback = ^(CLYNetworkReachabilityStatus status) {
        __strong __typeof(&*weakSelf)strongSelf = weakSelf;
        dispatch_async(dispatch_get_main_queue(), ^{
            strongSelf.networkReachabilityStatus = status;
        });
    };
    
    SCNetworkReachabilityContext context = {0, (__bridge void *)callback, CLYNetworkReachabilityRetainCallback, CLYNetworkReachabilityReleaseCallback, NULL};
    SCNetworkReachabilitySetCallback(self.networkReachability, CLYNetworkReachabilityCallback, &context);
    SCNetworkReachabilityScheduleWithRunLoop(self.networkReachability, CFRunLoopGetMain(), (CFStringRef)NSRunLoopCommonModes);
    
    SCNetworkReachabilityFlags flags;
    SCNetworkReachabilityGetFlags(self.networkReachability, &flags);
}

- (void)stopMonitoringNetworkReachability {
    if (_networkReachability) {
        SCNetworkReachabilityUnscheduleFromRunLoop(_networkReachability, CFRunLoopGetMain(), (CFStringRef)NSRunLoopCommonModes);
        CFRelease(_networkReachability);
        _networkReachability = NULL;
    }
}

@end




