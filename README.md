#Countly-sdk-cocoa
This is an iOS and Mac OS X client library for [Countly](http://count.ly). It's based on the [official library](https://github.com/Countly/countly-sdk-ios).


##Main differences with the official library

- Universal: iOS and OS X.
- Not using [OpenUDID](https://github.com/ylechelle/OpenUDID).
- Option to disable the session duration tracking.
- Clean-up of the requests in case of network failure.

## Requirements

Earliest supported deployment target - iOS 5.0 / Mac OS 10.7

It uses ARC.

Worked with OS X Sandboxing (add the `com.apple.security.app-sandbox` entitlement).

## Installation

* Drag the `Countly.h` and `Countly.m` class files into your project. 
* Add the System Configuration framework `SystemConfiguration.framework`.
* For iOS, Add the Core Telephony framework `CoreTelephony.framework`.
* Register your app:

``` objective-c
#import "Countly.h"
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [[Countly sharedInstance] startWithAttributes:@{
        CountlyAttributesAPIKey : @"MY_APP_KEY",
          CountlyAttributesHost : @"https://MY-SERVER.com"
     }];
    return YES;
}
```

## License

MIT license.






