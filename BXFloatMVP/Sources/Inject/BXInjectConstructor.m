#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// Swift: @_cdecl("BXFloatInstallCameraHooks")
void BXFloatInstallCameraHooks(void);

static void BXFloatInjectAttempt(void) {
    Class cls = NSClassFromString(@"BXInjectBootstrap");
    if (!cls) {
        cls = NSClassFromString(@"BXFloatInject.BXInjectBootstrap");
    }
    SEL sel = NSSelectorFromString(@"startIfNeeded");
    if (cls && [cls respondsToSelector:sel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [cls performSelector:sel];
#pragma clang diagnostic pop
    } else {
        NSLog(@"BXFloatInject bootstrap class missing");
    }
}

__attribute__((constructor))
static void BXFloatInjectConstructor(void) {
    @autoreleasepool {
        // 尽早挂钩：抖音可能在主线程首帧前就创建 AVCaptureSession
        BXFloatInstallCameraHooks();

        dispatch_async(dispatch_get_main_queue(), ^{
            BXFloatInstallCameraHooks();
            BXFloatInjectAttempt();
            for (NSInteger i = 1; i <= 20; i++) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 1.0 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    BXFloatInstallCameraHooks();
                    BXFloatInjectAttempt();
                });
            }
        });
    }
}
