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
        block();
        return nil;
    } @catch (NSException *e) {
        // NSException 必须最先匹配（ObjC 异常在底层也是 C++ 异常，catch(...) 会把它吃掉）
        return [NSString stringWithFormat:@"NSException [%@] reason: %@\nstack:\n%@",
                e.name, e.reason, [e.callStackSymbols componentsJoinedByString:@"\n"]];
    } @catch (...) {
        return describeCPP(std::current_exception());
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

#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

extern "C" NSString *AXTestLocalSocket(void) {
    NSMutableString *out = [NSMutableString string];
    // 连接 /var/run/usbmuxd
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return @"socket() 失败";
    struct sockaddr_un addr; memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    const char *path = "/var/run/usbmuxd";
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);
    int r = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
    if (r != 0) {
        int e = errno;
        close(fd);
        return [NSString stringWithFormat:@"❌ connect /var/run/usbmuxd errno=%d (%s)", e, strerror(e)];
    }
    [out appendFormat:@"✅ connect /var/run/usbmuxd 成功
"];
    // 发 usbmux Hello（16 字节头 + binary plist）
    NSDictionary *hello = @{@"ClientVersionString": @"axtouch-1.0",
                            @"MessageType": @"Hello",
                            @"ProgName": @"AXTouch"};
    NSData *plist = [NSPropertyListSerialization dataWithPropertyList:hello
                                                               format:NSPropertyListBinaryFormat_v1_0
                                                              options:0 error:nil];
    uint32_t hdr[4] = {(uint32_t)(plist.length + 16), 1, 1, 1};  // len, version=1, type=1(Hello), tag=1
    NSMutableData *msg = [NSMutableData dataWithBytes:hdr length:16];
    [msg appendData:plist];
    ssize_t w = write(fd, msg.bytes, msg.length);
    if (w < 0) { close(fd); return [NSString stringWithFormat:@"❌ write Hello errno=%d", errno]; }
    [out appendFormat:@"✅ Hello 已发送 (%zd 字节)
", w];
    // 读响应头 16 字节
    uint8_t rhdr[16];
    ssize_t got = 0;
    while (got < 16) {
        ssize_t n = read(fd, rhdr + got, 16 - got);
        if (n <= 0) { close(fd); return [NSString stringWithFormat:@"❌ 读响应头失败 got=%zd errno=%d", got, errno]; }
        got += n;
    }
    uint32_t rlen, rver, rtype, rtag;
    memcpy(&rlen, rhdr, 4); memcpy(&rver, rhdr + 4, 4); memcpy(&rtype, rhdr + 8, 4); memcpy(&rtag, rhdr + 12, 4);
    [out appendFormat:@"✅ 响应头: len=%u ver=%u type=%u tag=%u
", rlen, rver, rtype, rtag];
    if (rlen > 16 && rlen < 65536) {
        uint32_t bodyLen = rlen - 16;
        NSMutableData *body = [NSMutableData dataWithCapacity:bodyLen];
        uint8_t buf[4096];
        while (body.length < bodyLen) {
            ssize_t n = read(fd, buf, MIN((uint32_t)sizeof(buf), bodyLen - (uint32_t)body.length));
            if (n <= 0) break;
            [body appendBytes:buf length:n];
        }
        if (body.length == bodyLen) {
            id obj = [NSPropertyListSerialization propertyListWithData:body options:0 format:nil error:nil];
            [out appendFormat:@"响应内容: %@
", obj];
        }
    }
    close(fd);
    return out;
}
