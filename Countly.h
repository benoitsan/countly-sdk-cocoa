
// Countly.h
//
// This code is provided under the MIT License.
//
// Please visit www.count.ly for more information.

#import <Foundation/Foundation.h>

extern NSString * const CountlyAttributesAPIKey;
extern NSString * const CountlyAttributesHost;
extern NSString * const CountlyAttributesSessionDurationTrackingEnabled; // optional, enabled by default

extern NSString * const CountlyUserDefaultsUUID;

@interface Countly : NSObject

+ (instancetype)sharedInstance;

- (void)startWithAttributes:(NSDictionary *)attributes;

- (void)recordEvent:(NSString *)key count:(NSUInteger)count;
- (void)recordEvent:(NSString *)key count:(NSUInteger)count sum:(CGFloat)sum;
- (void)recordEvent:(NSString *)key segmentation:(NSDictionary *)segmentation count:(NSUInteger)count;
- (void)recordEvent:(NSString *)key segmentation:(NSDictionary *)segmentation count:(NSUInteger)count sum:(CGFloat)sum;

@end
