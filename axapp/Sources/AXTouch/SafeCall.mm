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
#include <fcntl.h>

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

extern "C" NSString *AXScanLoopbackPorts(void);

/// 对一个端口发 lockdown QueryType，返回响应描述（nil=不是 lockdown）
static NSString *queryLockdownPort(int port) {
    int fd = socket(AF_INET6, SOCK_STREAM, 0);
    if (fd < 0) return nil;
    struct sockaddr_in6 addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin6_family = AF_INET6;
    addr.sin6_port = htons((uint16_t)port);
    inet_pton(AF_INET6, "::1", &addr.sin6_addr);
    // 连接带超时，避免卡死
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    int r = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
    if (r != 0 && errno == EINPROGRESS) {
        fd_set wset; FD_ZERO(&wset); FD_SET(fd, &wset);
        struct timeval tv = {1, 0};
        if (select(fd + 1, NULL, &wset, NULL, &tv) <= 0) { close(fd); return nil; }
        int err = 0; socklen_t elen = sizeof(err);
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &elen);
        if (err != 0) { close(fd); return nil; }
    } else if (r != 0) {
        close(fd);
        return nil;
    }
    fcntl(fd, F_SETFL, flags);

    NSDictionary *q = @{@"Label": @"axtouch-poc", @"Request": @"QueryType"};
    NSData *pl = [NSPropertyListSerialization dataWithPropertyList:q format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    uint32_t len = htonl((uint32_t)pl.length);
    NSMutableData *msg = [NSMutableData dataWithBytes:&len length:4];
    [msg appendData:pl];
    if (write(fd, msg.bytes, msg.length) < 0) { close(fd); return nil; }

    // 读长度头（1 秒超时）
    fd_set rset; FD_ZERO(&rset); FD_SET(fd, &rset);
    struct timeval rtv = {1, 0};
    if (select(fd + 1, &rset, NULL, NULL, &rtv) <= 0) { close(fd); return nil; }
    uint8_t lh[4];
    ssize_t got = 0;
    while (got < 4) {
        ssize_t n = read(fd, lh + got, 4 - got);
        if (n <= 0) { close(fd); return nil; }
        got += n;
    }
    uint32_t rlen;
    memcpy(&rlen, lh, 4);
    rlen = ntohl(rlen);
    if (rlen == 0 || rlen > 1048576) { close(fd); return nil; }
    NSMutableData *body = [NSMutableData dataWithCapacity:rlen];
    uint8_t buf[8192];
    while (body.length < rlen) {
        ssize_t n = read(fd, buf, MIN((uint32_t)sizeof(buf), rlen - (uint32_t)body.length));
        if (n <= 0) break;
        [body appendBytes:buf length:n];
    }
    close(fd);
    id obj = [NSPropertyListSerialization propertyListWithData:body options:0 format:nil error:nil];
    return obj ? [NSString stringWithFormat:@"%@", obj] : nil;
}

/// 对候选端口逐个发 lockdown QueryType，找出真正的 lockdown
extern "C" NSString *AXTestLockdownTCP(void) {
    NSMutableString *out = [NSMutableString string];
    // 先扫一遍可达端口，再对每个发 QueryType
    NSString *ports = AXScanLoopbackPorts();
    [out appendFormat:@"可达端口: %@\n", ports];
    NSArray *items = [ports componentsSeparatedByString:@" "];
    for (NSString *it in items) {
        int port = [it intValue];
        if (port <= 0) continue;
        NSString *resp = queryLockdownPort(port);
        if (resp) {
            [out appendFormat:@"✅ 端口 %d 是 lockdown!\n响应: %@\n", port, resp];
        } else {
            [out appendFormat:@"端口 %d: 非 lockdown\n", port];
        }
    }
    return out;
}

/// 旧的单端口版本（保留对照，不再调用）
extern "C" NSString *AXTestLockdownTCP_legacy_49152(void) {
    NSMutableString *out = [NSMutableString string];
    int fd = socket(AF_INET6, SOCK_STREAM, 0);
    if (fd < 0) return [NSString stringWithFormat:@"socket(AF_INET6) 失败 errno=%d", errno];
    struct sockaddr_in6 addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin6_family = AF_INET6;
    addr.sin6_port = htons(49152);
    inet_pton(AF_INET6, "::1", &addr.sin6_addr);
    int r = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
    if (r != 0) {
        int e = errno;
        close(fd);
        return [NSString stringWithFormat:@"❌ connect [::1]:49152 errno=%d (%s)", e, strerror(e)];
    }
    [out appendFormat:@"✅ TCP connect [::1]:49152 成功！lockdown loopback 端口\n"];
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

#include <dispatch/dispatch.h>

/// 扫描 ::1 上所有可达端口（非阻塞 connect + 100ms 超时），列出本机 loopback 监听的服务
extern "C" NSString *AXScanLoopbackPorts(void) {
    NSMutableString *out = [NSMutableString string];
    NSMutableArray *found = [NSMutableArray array];
    // iOS 没有便捷的非阻塞 connect 等待，用 dispatch 组 + 每端口独立 socket
    dispatch_group_t group = dispatch_group_create();
    __block NSLock *lock = [[NSLock alloc] init];
    for (int port = 1024; port <= 65535; port++) {
        dispatch_group_enter(group);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            int fd = socket(AF_INET6, SOCK_STREAM, 0);
            if (fd < 0) { dispatch_group_leave(group); return; }
            // 非阻塞
            int flags = fcntl(fd, F_GETFL, 0);
            fcntl(fd, F_SETFL, flags | O_NONBLOCK);
            struct sockaddr_in6 addr; memset(&addr, 0, sizeof(addr));
            addr.sin6_family = AF_INET6;
            addr.sin6_port = htons((uint16_t)port);
            inet_pton(AF_INET6, "::1", &addr.sin6_addr);
            int r = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
            if (r == 0) {
                [lock lock]; [found addObject:@(port)]; [lock unlock];
                close(fd);
                dispatch_group_leave(group);
                return;
            }
            if (errno == EINPROGRESS) {
                struct timeval tv = {0, 120000};  // 120ms
                fd_set wset; FD_ZERO(&wset); FD_SET(fd, &wset);
                if (select(fd + 1, NULL, &wset, NULL, &tv) > 0) {
                    int err = 0; socklen_t elen = sizeof(err);
                    getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &elen);
                    if (err == 0) {
                        [lock lock]; [found addObject:@(port)]; [lock unlock];
                    }
                }
            }
            close(fd);
            dispatch_group_leave(group);
        });
    }
    dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));
    for (NSNumber *p in found) {
        [out appendFormat:@"%@ ", p];
    }
    if (found.count == 0) [out appendString:@"（无可达端口）"];
    return out;
}

#include <ifaddrs.h>
#include <net/if.h>
#include <dns_sd.h>
#include <netdb.h>

// ASAgent bootstrap：按 AScript 的实际流程实现
// 1) 检查 /Developer/Library/Frameworks/XCTest.framework 是否存在（DDI 挂载标志）
// 2) mDNS 查询 com.apple.internal.dt.coredevice.untrusted.tunnelservice（本机回环）
// 3) 列出本机所有网卡的 IPv6 地址（AScript 用 ::1 + mDNS 找端点）

static void bootstrapBrowseReply(DNSServiceRef sref, DNSServiceFlags flags, uint32_t idx,
                                 DNSServiceErrorType err, const char *name, const char *type,
                                 const char *domain, void *ctx) {
    if (err == kDNSServiceErr_NoError) {
        NSLog(@"[Bootstrap] mDNS: %s (%s)", name, type);
    }
}

extern "C" NSString *AXBootstrapProbe(void) {
    NSMutableString *out = [NSMutableString string];

    // 1) DDI 挂载检查
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *ddiPaths = @[@"/Developer/Library/Frameworks/XCTest.framework",
                          @"/System/Developer/Library/Frameworks/XCTest.framework",
                          @"/private/preboot/Cryptexes/OS/Developer/Library/Frameworks/XCTest.framework"];
    BOOL ddiMounted = NO;
    for (NSString *p in ddiPaths) {
        BOOL isDir;
        if ([fm fileExistsAtPath:p isDirectory:&isDir] && isDir) {
            ddiMounted = YES;
            [out appendFormat:@"✅ DDI 已挂载: %s\n", [p UTF8String]];
        }
    }
    if (!ddiMounted) [out appendString:@"❌ DDI 未挂载（/Developer 路径全部不存在）\n"];

    // 2) 本机网卡 IPv6 地址（AScript 的 mDNS/连接用）
    [out appendString:@"== 本机 IPv6 地址 ==\n"];
    struct ifaddrs *ifap = NULL, *ifa = NULL;
    if (getifaddrs(&ifap) == 0) {
        for (ifa = ifap; ifa; ifa = ifa->ifa_next) {
            if (ifa->ifa_addr && ifa->ifa_addr->sa_family == AF_INET6) {
                char host[128] = {0};
                getnameinfo(ifa->ifa_addr, sizeof(struct sockaddr_in6), host, sizeof(host), NULL, 0, NI_NUMERICHOST);
                [out appendFormat:@"%@: %s\n", ifa->ifa_name, host];
            }
        }
        freeifaddrs(ifap);
    }

    // 3) mDNS 查询 untrusted.tunnelservice（异步，5 秒窗口）
    [out appendString:@"== mDNS 查询 untrusted.tunnelservice（5 秒）==\n"];
    DNSServiceRef sd = NULL;
    DNSServiceErrorType berr = DNSServiceBrowse(&sd, 0, 0, "_remoted._tcp", "local",
                     (DNSServiceBrowseReply)bootstrapBrowseReply, NULL);
    if (berr != kDNSServiceErr_NoError) {
        [out appendFormat:@"mDNS Browse 失败 err=%d\n", berr];
    } else {
        int dnsfd = DNSServiceRefSockFD(sd);
        if (dnsfd >= 0) {
            fd_set rset;
            struct timeval tv;
            for (int i = 0; i < 50; i++) {
                FD_ZERO(&rset); FD_SET(dnsfd, &rset);
                tv.tv_sec = 0; tv.tv_usec = 100000;
                if (select(dnsfd + 1, &rset, NULL, NULL, &tv) > 0) {
                    DNSServiceProcessResult(sd);
                }
            }
        }
        if (sd) DNSServiceRefDeallocate(sd);
    }
    [out appendString:@"mDNS 窗口结束\n"];
    return out;
}

#pragma mark - 本机 lockdown 取 UDID

/* ★ AXStream 的 UDID 写入口（AXAgent.mm 里实现） */
extern "C" void AXStreamSetUDID(NSString *udid);

/// 连接 ::1:port 发一个 lockdown 请求并读完整响应（nil=失败）
/// 请求/响应都是 [4B 大端长度][二进制 plist]
static NSDictionary *AXLockdownRoundtrip(int port, NSDictionary *req) {
    int fd = socket(AF_INET6, SOCK_STREAM, 0);
    if (fd < 0) return nil;
    struct sockaddr_in6 addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin6_family = AF_INET6;
    addr.sin6_port = htons((uint16_t)port);
    inet_pton(AF_INET6, "::1", &addr.sin6_addr);

    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    int r = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
    if (r != 0 && errno == EINPROGRESS) {
        fd_set wset; FD_ZERO(&wset); FD_SET(fd, &wset);
        struct timeval tv = {2, 0};
        if (select(fd + 1, NULL, &wset, NULL, &tv) <= 0) { close(fd); return nil; }
        int err = 0; socklen_t elen = sizeof(err);
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &elen);
        if (err != 0) { close(fd); return nil; }
    } else if (r != 0) {
        close(fd); return nil;
    }
    fcntl(fd, F_SETFL, flags);

    /* ★ 恢复阻塞后必须给收发加超时：否则对端收了请求不回（比如非 lockdown 服务）
       read 会永远阻塞 —— b57 上线即把控制队列卡死的根因 */
    struct timeval iotv = {3, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &iotv, sizeof(iotv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &iotv, sizeof(iotv));

    NSData *pl = [NSPropertyListSerialization dataWithPropertyList:req
                                                            format:NSPropertyListBinaryFormat_v1_0
                                                           options:0 error:nil];
    if (!pl.length) { close(fd); return nil; }
    uint32_t len = htonl((uint32_t)pl.length);
    NSMutableData *msg = [NSMutableData dataWithBytes:&len length:4];
    [msg appendData:pl];
    if (write(fd, msg.bytes, msg.length) != (ssize_t)msg.length) { close(fd); return nil; }

    uint8_t lh[4];
    ssize_t got = 0;
    while (got < 4) {
        ssize_t n = read(fd, lh + got, 4 - got);
        if (n <= 0) { close(fd); return nil; }
        got += n;
    }
    uint32_t rlen;
    memcpy(&rlen, lh, 4);
    rlen = ntohl(rlen);
    if (rlen == 0 || rlen > 4194304) { close(fd); return nil; }

    NSMutableData *body = [NSMutableData dataWithCapacity:rlen];
    uint8_t buf[16384];
    while (body.length < rlen) {
        ssize_t n = read(fd, buf, MIN((uint32_t)sizeof(buf), rlen - (uint32_t)body.length));
        if (n <= 0) break;
        [body appendBytes:buf length:n];
    }
    close(fd);
    return [NSPropertyListSerialization propertyListWithData:body options:0 format:nil error:nil];
}

static BOOL AXIsLockdownResp(NSDictionary *r) {
    return r && [r isKindOfClass:[NSDictionary class]]
        && [r[@"Type"] isKindOfClass:[NSString class]];
}

/// 取真 UDID：先认出 lockdown 端口，再 GetValue UniqueDeviceID（免配对可读）。
/// 成功 → 同步给推流 preamble 并返回 UDID 字符串；失败 → 返回诊断信息。
extern "C" NSString *AXLockdownUDID(void) {
    NSMutableString *out = [NSMutableString string];

    /* 1) 认端口：62078 是 lockdown 标准端口；扫描兜底 */
    int lport = 0;
    for (int p : {62078, 49152}) {
        NSDictionary *r = AXLockdownRoundtrip(p, @{@"Label": @"axtouch", @"ProtocolVersion": @"2", @"Request": @"QueryType"});
        if (AXIsLockdownResp(r)) {
            [out appendFormat:@"✅ 端口 %d 是 lockdown (Type=%@)\n", p, r[@"Type"]];
            lport = p;
            break;
        }
    }
    if (!lport) {
        NSString *scan = AXScanLoopbackPorts() ?: @"";
        for (NSString *it in [scan componentsSeparatedByString:@" "]) {
            int p = [it intValue];
            if (p <= 0) continue;
            NSDictionary *r = AXLockdownRoundtrip(p, @{@"Label": @"axtouch", @"ProtocolVersion": @"2", @"Request": @"QueryType"});
            if (AXIsLockdownResp(r)) { lport = p; break; }
        }
    }
    if (!lport) return @"no lockdown port (62078/scan 均未命中)";

    /* 2) GetValue：单 key。UniqueDeviceID 不要求配对 */
    NSDictionary *resp = AXLockdownRoundtrip(lport, @{
        @"Label": @"axtouch",
        @"ProtocolVersion": @"2",
        @"Request": @"GetValue",
        @"Key": @"UniqueDeviceID",
    });
    id val = resp[@"Value"];
    if ([val isKindOfClass:[NSString class]] && [(NSString *)val length] > 10) {
        AXStreamSetUDID(val);
        return (NSString *)val;
    }
    [out appendFormat:@"单key响应: %@\n", resp ?: @"nil"];

    /* 3) 兜底：全量 GetValue（本机连的 lockdown 视为本机信任，可能给得更多） */
    resp = AXLockdownRoundtrip(lport, @{@"Label": @"axtouch", @"ProtocolVersion": @"2", @"Request": @"GetValue"});
    val = resp[@"Value"];
    if ([val isKindOfClass:[NSDictionary class]]) {
        NSDictionary *vv = (NSDictionary *)val;
        id u = vv[@"UniqueDeviceID"];
        if ([u isKindOfClass:[NSString class]] && [(NSString *)u length] > 10) {
            AXStreamSetUDID(u);
            return (NSString *)u;
        }
        [out appendFormat:@"全量响应键: %@\n", [vv.allKeys componentsJoinedByString:@","]];
    } else {
        [out appendFormat:@"全量响应: %@\n", resp ?: @"nil"];
    }
    return out;
}


#pragma mark - 异步包装（b58：控制队列绝不阻塞）

static NSString *g_ldResult = nil;   /* idle / running / 结果 */

/// 后台线程跑完整探测；立即返回。结果用 AXLockdownUDIDResult 取。
extern "C" NSString *AXLockdownUDIDStart(void) {
    @synchronized ([NSString class]) {
        if ([g_ldResult isEqualToString:@"running"]) return @"running";
    }
    g_ldResult = @"running";
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *r = AXLockdownUDID() ?: @"nil";
        g_ldResult = r;
        NSLog(@"[ldudid] %@", r);
    });
    return @"started";
}

extern "C" NSString *AXLockdownUDIDResult(void) {
    NSString *r = nil;
    @synchronized ([NSString class]) { r = g_ldResult; }
    return r ?: @"idle";
}
