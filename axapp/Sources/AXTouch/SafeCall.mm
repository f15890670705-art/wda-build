#import <Foundation/Foundation.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <exception>
#include <string>
#include <cxxabi.h>

// ObjC++ 文件：既能捕 NSException 也能捕 C++ 异常
// （XCTest 内部抛的是 C++ 异常 → std::terminate → abort，纯 .m 里的 @catch(...) 抓不到）

static NSString *describeCPP(std::exception_ptr ep) {
    if (!ep) return @"(no exception_ptr)";
    try {
        std::rethrow_exception(ep);
    } catch (const std::exception &e) {
        int status = 0;
        char *dem = abi::__cxa_demangle(typeid(e).name(), nullptr, nullptr, &status);
        NSString *tn = dem ? [NSString stringWithUTF8String:dem]
                           : [NSString stringWithUTF8String:typeid(e).name()];
        free(dem);
        return [NSString stringWithFormat:@"C++ 异常 %@: %s", tn, e.what()];
    } catch (...) {
        return @"C++ 未知异常（非 std::exception）";
    }
}

extern "C" NSString *AXSafeCall(void (^block)(void)) {
    @try {
        try {
            block();
            return nil;
        } catch (...) {
            return describeCPP(std::current_exception());
        }
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"NSException %@: %@", e.name, e.reason];
    } @catch (...) {
        return @"ObjC 未知异常";
    }
}

extern "C" NSString *AXProbeDaemonSession(void) {
    Class cls = NSClassFromString(@"XCTRunnerDaemonSession");
    if (cls == Nil) return @"XCTRunnerDaemonSession 类不存在（框架未加载）";
    __block id session = nil;
    NSString *err = AXSafeCall(^{
        session = ((id (*)(id, SEL))objc_msgSend)(cls, NSSelectorFromString(@"sharedSession"));
    });
    if (err) return err;
    return session ? nil : @"sharedSession 返回 nil";
}

extern "C" NSString *AXStartWDAServer(void) {
    Class cls = NSClassFromString(@"FBWebServer");
    if (cls == Nil) return @"FBWebServer 类不存在";
    __block id server = nil;
    NSString *e0 = AXSafeCall(^{
        server = [[cls alloc] init];
    });
    if (e0) return [@"alloc/init: " stringByAppendingString:e0];
    if (server == nil) return @"FBWebServer 实例为 nil";

    SEL sel = NSSelectorFromString(@"startHTTPServer");
    if (![server respondsToSelector:sel]) return @"FBWebServer 无 startHTTPServer";

    static id retained = nil;
    retained = server;

    return AXSafeCall(^{
        ((void (*)(id, SEL))objc_msgSend)(server, sel);
    });
}

extern "C" void AXStartWDAServerThread(NSString **outLog) {
    NSThread *t = [[NSThread alloc] initWithBlock:^{
        NSString *err = AXStartWDAServer();
        if (outLog) {
            *outLog = err ? [NSString stringWithFormat:@"❌ %@", err]
                          : @"✅ startHTTPServer 已调用（线程保持运行）";
        }
        // 线程永不退出 → autorelease pool 永不 pop → WDA 内部的 NSXPCConnection 不会被释放
        while (YES) { [NSThread sleepForTimeInterval:86400.0]; }
    }];
    t.name = @"WDA-Server-Thread";
    [t start];
}

extern "C" void AXLoadXCTestThread(void) {
    NSThread *t = [[NSThread alloc] initWithBlock:^{
        NSString *fwDir = [NSString stringWithFormat:@"%@/Frameworks", [[NSBundle mainBundle] bundlePath]];
        setenv("DYLD_FRAMEWORK_PATH", [fwDir UTF8String], 1);
        NSArray *order = @[@"Testing", @"XCTestCore", @"XCTAutomationSupport", @"XCTest",
                           @"XCTestSupport", @"XCUIAutomation", @"XCUnit", @"WebDriverAgentLib"];
        for (NSString *name in order) {
            NSString *path = [NSString stringWithFormat:@"%@/%@.framework/%@", fwDir, name, name];
            dlerror();
            if (!dlopen([path UTF8String], RTLD_NOW | RTLD_GLOBAL)) {
                const char *e = dlerror();
                NSLog(@"[WDA-Thread] ❌ %@: %s", name, e ? e : "?");
            } else {
                NSLog(@"[WDA-Thread] ✅ %@", name);
            }
        }
        if (NSClassFromString(@"FBWebServer")) {
            NSString *e = AXStartWDAServer();
            NSLog(@"[WDA-Thread] server: %@", e ? e : @"✅ 已启动");
        }
        // 永不退出：所有 XPC 对象保活
        while (YES) { [NSThread sleepForTimeInterval:86400.0]; }
    }];
    t.name = @"WDA-Load-Thread";
    [t start];
}
