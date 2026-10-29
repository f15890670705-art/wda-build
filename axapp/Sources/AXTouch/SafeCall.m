#import <Foundation/Foundation.h>
#import <objc/message.h>

// Swift 无法捕获 NSException，用 ObjC 包一层把异常原因带出来。
// 返回 nil 表示没抛异常，否则返回异常描述。
NSString *AXSafeCall(void (^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"%@: %@\nname=%@\ncallStack=%@",
                e.name, e.reason, e.name,
                [[e callStackSymbols] componentsJoinedByString:@"\n"]];
    } @catch (...) {
        return @"unknown exception";
    }
}

// 尝试调用 FBWebServer 的 startHTTPServer，返回异常原因（nil=成功）
NSString *AXStartWDAServer(void) {
    Class cls = NSClassFromString(@"FBWebServer");
    if (cls == Nil) return @"FBWebServer 类不存在";
    __block id server = nil;
    NSString *err = AXSafeCall(^{
        server = [[cls alloc] init];
    });
    if (err) return [@"alloc/init 失败: " stringByAppendingString:err];
    if (server == nil) return @"FBWebServer 实例为 nil";

    SEL sel = NSSelectorFromString(@"startHTTPServer");
    if (![server respondsToSelector:sel]) {
        return @"FBWebServer 无 startHTTPServer 方法";
    }
    __block NSString *callErr = nil;
    NSString *e2 = AXSafeCall(^{
        ((void (*)(id, SEL))objc_msgSend)(server, sel);
    });
    if (e2) callErr = e2;
    // 保留 server 引用防止被释放
    static id retainedServer = nil;
    retainedServer = server;
    return callErr;
}

// 只探测 XCTRunnerDaemonSession 初始化是否抛异常
NSString *AXProbeDaemonSession(void) {
    Class cls = NSClassFromString(@"XCTRunnerDaemonSession");
    if (cls == Nil) return @"XCTRunnerDaemonSession 类不存在（框架未加载）";
    __block id session = nil;
    NSString *err = AXSafeCall(^{
        session = ((id (*)(id, SEL))objc_msgSend)(cls, NSSelectorFromString(@"sharedSession"));
    });
    if (err) return err;
    return session ? nil : @"sharedSession 返回 nil";
}
