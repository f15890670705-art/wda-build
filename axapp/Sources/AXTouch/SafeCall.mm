#import <Foundation/Foundation.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <exception>
#include <string>
#include <cxxabi.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>

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
        while (YES) { [NSThread sleepForTimeInterval:86400.0]; }
    }];
    t.name = @"WDA-Load-Thread";
    [t start];
}

/// 测试 /var/run/usbmuxd（unix socket，预期 errno=2）
extern "C" NSString *AXTestLocalSocket(void) {
    NSMutableString *out = [NSMutableString string];
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return @"socket() 失败";
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    const char *path = "/var/run/usbmuxd";
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);
    int r = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
    if (r != 0) {
        int e = errno;
        close(fd);
        return [NSString stringWithFormat:@"❌ connect /var/run/usbmuxd errno=%d (%s)", e, strerror(e)];
    }
    [out appendFormat:@"✅ connect /var/run/usbmuxd 成功\n"];
    NSDictionary *hello = @{@"ClientVersionString": @"axtouch-1.0",
                            @"MessageType": @"Hello",
                            @"ProgName": @"AXTouch"};
    NSData *plist = [NSPropertyListSerialization dataWithPropertyList:hello
                                                               format:NSPropertyListBinaryFormat_v1_0
                                                              options:0 error:nil];
    uint32_t hdr[4] = {(uint32_t)(plist.length + 16), 1, 1, 1};
    NSMutableData *msg = [NSMutableData dataWithBytes:hdr length:16];
    [msg appendData:plist];
    ssize_t w = write(fd, msg.bytes, msg.length);
    if (w < 0) { close(fd); return [NSString stringWithFormat:@"❌ write Hello errno=%d", errno]; }
    [out appendFormat:@"✅ Hello 已发送 (%zd 字节)\n", w];
    uint8_t rhdr[16];
    ssize_t got = 0;
    while (got < 16) {
        ssize_t n = read(fd, rhdr + got, 16 - got);
        if (n <= 0) { close(fd); return [NSString stringWithFormat:@"❌ 读响应头失败 got=%zd errno=%d", got, errno]; }
        got += n;
    }
    uint32_t rlen, rver, rtype, rtag;
    memcpy(&rlen, rhdr, 4); memcpy(&rver, rhdr + 4, 4); memcpy(&rtype, rhdr + 8, 4); memcpy(&rtag, rhdr + 12, 4);
    [out appendFormat:@"✅ 响应头: len=%u ver=%u type=%u tag=%u\n", rlen, rver, rtype, rtag];
    close(fd);
    return out;
}

/// 测试 ::1:62078 lockdown TCP（AScript 内核路线的第一跳）
extern "C" NSString *AXTestLockdownTCP(void) {
    NSMutableString *out = [NSMutableString string];
    int fd = socket(AF_INET6, SOCK_STREAM, 0);
    if (fd < 0) return [NSString stringWithFormat:@"socket(AF_INET6) 失败 errno=%d", errno];
    struct sockaddr_in6 addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin6_family = AF_INET6;
    addr.sin6_port = htons(62078);
    inet_pton(AF_INET6, "::1", &addr.sin6_addr);
    int r = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
    if (r != 0) {
        int e = errno;
        close(fd);
        return [NSString stringWithFormat:@"❌ connect [::1]:62078 errno=%d (%s)", e, strerror(e)];
    }
    [out appendFormat:@"✅ TCP connect [::1]:62078 成功！lockdown 监听 loopback\n"];
    NSDictionary *q = @{@"Label": @"axtouch-poc", @"Request": @"QueryType"};
    NSData *pl = [NSPropertyListSerialization dataWithPropertyList:q format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    uint32_t len = htonl((uint32_t)pl.length);
    NSMutableData *msg = [NSMutableData dataWithBytes:&len length:4];
    [msg appendData:pl];
    ssize_t w = write(fd, msg.bytes, msg.length);
    if (w < 0) { close(fd); return [NSString stringWithFormat:@"❌ write QueryType errno=%d", errno]; }
    [out appendFormat:@"✅ QueryType 已发送 (%zd 字节)\n", w];
    uint8_t lh[4];
    ssize_t got = 0;
    while (got < 4) {
        ssize_t n = read(fd, lh + got, 4 - got);
        if (n <= 0) { close(fd); return [NSString stringWithFormat:@"❌ 读长度头失败 got=%zd errno=%d", got, errno]; }
        got += n;
    }
    uint32_t rlen;
    memcpy(&rlen, lh, 4);
    rlen = ntohl(rlen);
    [out appendFormat:@"✅ 响应长度: %u\n", rlen];
    if (rlen > 0 && rlen < 1048576) {
        NSMutableData *body = [NSMutableData dataWithCapacity:rlen];
        uint8_t buf[8192];
        while (body.length < rlen) {
            ssize_t n = read(fd, buf, MIN((uint32_t)sizeof(buf), rlen - (uint32_t)body.length));
            if (n <= 0) break;
            [body appendBytes:buf length:n];
        }
        id obj = [NSPropertyListSerialization propertyListWithData:body options:0 format:nil error:nil];
        [out appendFormat:@"响应: %@\n", obj];
    }
    close(fd);
    return out;
}
