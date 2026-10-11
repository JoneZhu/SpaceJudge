// Minimal launch control: no SpaceJudge code, disk scan, helper, or authorization API.
#import <Cocoa/Cocoa.h>
#import <os/log.h>

#ifndef PROBE_LABEL
#error PROBE_LABEL must be supplied by the diagnostic builder
#endif

@interface LaunchProbeDelegate : NSObject <NSApplicationDelegate>
@property(strong) NSWindow *window;
@end

@implementation LaunchProbeDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    self.window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 580, 200)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
        backing:NSBackingStoreBuffered defer:NO];
    self.window.releasedWhenClosed = NO;
    self.window.title = @PROBE_LABEL;
    NSTextField *label = [NSTextField wrappingLabelWithString:
        @"启动成功\n\n这是独立的安装授权对照程序，不是 SpaceJudge。\n不扫描磁盘、不访问网络、不修改权限或系统设置。\n看到此窗口只代表本次启动成功，不代表首次安装问题已修复。"];
    label.frame = NSMakeRect(24, 24, 532, 150);
    label.font = [NSFont systemFontOfSize:15];
    [self.window.contentView addSubview:label];
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    os_log_with_type(os_log_create("com.hongdazhu.SpaceJudgeLaunchProbe", "Launch"),
                     OS_LOG_TYPE_DEFAULT, "windowReady %{public}s", PROBE_LABEL);
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return YES;
}
@end

int main(void) {
    @autoreleasepool {
        os_log_with_type(os_log_create("com.hongdazhu.SpaceJudgeLaunchProbe", "Launch"),
                         OS_LOG_TYPE_DEFAULT, "processEntry %{public}s", PROBE_LABEL);
        NSApplication *app = [NSApplication sharedApplication];
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        __attribute__((objc_precise_lifetime)) LaunchProbeDelegate *delegate = [LaunchProbeDelegate new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
