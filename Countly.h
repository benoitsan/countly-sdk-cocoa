
// Countly.h
//
// This code is provided under the MIT License.
//
// Please visit www.count.ly for more information.

#import <Foundation/Foundation.h>

extern NSString * const CountlyUserDefaultsUUID;

@interface Countly : NSObject

+ (Countly *)sharedInstance;

- (void)start:(NSString *)appKey withHost:(NSString *)appHost;

- (void)recordEvent:(NSString *)key count:(NSUInteger)count;
- (void)recordEvent:(NSString *)key count:(NSUInteger)count sum:(CGFloat)sum;
- (void)recordEvent:(NSString *)key segmentation:(NSDictionary *)segmentation count:(NSUInteger)count;
- (void)recordEvent:(NSString *)key segmentation:(NSDictionary *)segmentation count:(NSUInteger)count sum:(CGFloat)sum;

@end
