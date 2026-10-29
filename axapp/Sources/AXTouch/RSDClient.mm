#import <Foundation/Foundation.h>
#import <dns_sd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <unistd.h>
#include <fcntl.h>

// RSD 客户端：按 pymobiledevice3 的 remote_service_discovery.py 1:1 移植
// 流程（与 AScript 完全一致）：
//   1) mDNS Browse _remoted._tcp → 拿到设备广播的 host:port
//   2) TCP 连接
//   3) 发 RSDCheckin {Label, ProtocolVersion:"2", Request:"RSDCheckin"}
//   4) 收响应：peer info + 服务表（含各服务的 Port）
//   5) 从服务表取 com.apple.internal.dt.coredevice.untrusted.tunnelservice 的端口
// 全部结果写入日志文件，供 PC 端 house_arrest 拉取。

static NSMutableArray<NSString *> *gRSDEndpoints = nil;
static NSMutableString *gRSDLog = nil;

static void rsdAppend(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (!gRSDLog) gRSDLog = [NSMutableString string];
    [gRSDLog appendString:s];
    [gRSDLog appendString:@"\n"];
    NSLog(@"[RSD] %@", s);
}

// mDNS 回调：收集 _remoted._tcp 实例
static void rsdBrowseCallback(DNSServiceRef sdRef, DNSServiceFlags flags, uint32_t ifIndex,
                              DNSServiceErrorType err, const char *serviceName, const char *regtype,
                              const char *replyDomain, void *context) {
    if (err != kDNSServiceErr_NoError) {
        rsdAppend(@"mDNS 回调错误: %d", err);
        return;
    }
    rsdAppend(@"mDNS 发现服务: %@ (%@)", @(serviceName), @(regtype));
    // 解析该实例的 host/port
    DNSServiceRef resolveRef = NULL;
    DNSServiceErrorType rerr = DNSServiceResolve(&resolveRef, 0, ifIndex, serviceName, regtype, replyDomain,
        ^(DNSServiceRef r, DNSServiceFlags f, uint32_t idx, DNSServiceErrorType e,
          const char *fullname, const char *hosttarget, uint16_t port, uint16_t txtLen, const unsigned char *txtRecord) {
            if (e == kDNSServiceErr_NoError) {
                NSString *ep = [NSString stringWithFormat:@"%s:%u", hosttarget, ntohs(port)];
                if (!gRSDEndpoints) gRSDEndpoints = [NSMutableArray array];
                if (![gRSDEndpoints containsObject:ep]) [gRSDEndpoints addObject:ep];
                rsdAppend(@"mDNS 解析: %@ (port %u)", @(hosttarget), ntohs(port));
            } else {
                rsdAppend(@"mDNS 解析失败: %d", e);
            }
            DNSServiceRefDeallocate(r);
        }, NULL);
    if (rerr != kDNSServiceErr_NoError) {
        rsdAppend(@"DNSServiceResolve 启动失败: %d", rerr);
        return;
    }
    // 处理 resolve 结果（最多 1 秒）
    int fd = DNSServiceRefSockFD(resolveRef);
    if (fd >= 0) {
        fd_set rset; FD_ZERO(&rset); FD_SET(fd, &rset);
        struct timeval tv = {1, 0};
        if (select(fd + 1, &rset, NULL, NULL, &tv) > 0) DNSServiceProcessResult(resolveRef);
    } else {
        DNSServiceRefDeallocate(resolveRef);
    }
}

static NSString *rsdReadPlistMessage(int fd, NSTimeInterval timeout) {
    // 4 字节大端长度 + binary plist
    fd_set rset; FD_ZERO(&rset); FD_SET(fd, &rset);
    struct timeval tv = {(time_t)timeout, 0};
    if (select(fd + 1, &rset, NULL, NULL, &tv) <= 0) return nil;
    uint8_t lh[4];
    ssize_t got = 0;
    while (got < 4) {
        ssize_t n = read(fd, lh + got, 4 - got);
        if (n <= 0) return nil;
        got += n;
    }
    uint32_t rlen; memcpy(&rlen, lh, 4); rlen = ntohl(rlen);
    if (rlen == 0 || rlen > 4 * 1024 * 1024) return nil;
    NSMutableData *body = [NSMutableData dataWithCapacity:rlen];
    uint8_t buf[16384];
    while (body.length < rlen) {
        ssize_t n = read(fd, buf, MIN((uint32_t)sizeof(buf), rlen - (uint32_t)body.length));
        if (n <= 0) break;
        [body appendBytes:buf length:n];
    }
    return [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding]
        ?: [NSString stringWithFormat:@"[二进制 %lu 字节]", (unsigned long)body.length];
}

static BOOL rsdSendPlist(int fd, NSDictionary *dict) {
    NSData *pl = [NSPropertyListSerialization dataWithPropertyList:dict
                                                            format:NSPropertyListBinaryFormat_v1_0
                                                           options:0 error:nil];
    if (!pl) return NO;
    uint32_t len = htonl((uint32_t)pl.length);
    NSMutableData *msg = [NSMutableData dataWithBytes:&len length:4];
    [msg appendData:pl];
    return write(fd, msg.bytes, msg.length) == (ssize_t)msg.length;
}

static int rsdConnectHostPort(NSString *hostPort, int *outErrno) {
    NSRange colon = [hostPort rangeOfString:@":" options:NSBackwardsSearch];
    if (colon.location == NSNotFound) { if (outErrno) *outErrno = EINVAL; return -1; }
    NSString *host = [hostPort substringToIndex:colon.location];
    int port = [[hostPort substringFromIndex:colon.location + 1] intValue];

    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo([host UTF8String], NULL, &hints, &res) != 0 || !res) {
        if (outErrno) *outErrno = EHOSTUNREACH;
        return -1;
    }
    int fd = socket(res->ai_family, SOCK_STREAM, 0);
    if (fd < 0) { freeaddrinfo(res); if (outErrno) *outErrno = errno; return -1; }
    if (res->ai_family == AF_INET6) {
        ((struct sockaddr_in6 *)res->ai_addr)->sin6_port = htons((uint16_t)port);
    } else {
        ((struct sockaddr_in *)res->ai_addr)->sin_port = htons((uint16_t)port);
    }
    int r = connect(fd, res->ai_addr, res->ai_addrlen);
    int e = errno;
    freeaddrinfo(res);
    if (r != 0) { close(fd); if (outErrno) *outErrno = e; return -1; }
    return fd;
}

/// 完整 RSD 探测：mDNS → connect → RSDCheckin → 解析服务表
extern "C" NSString *AXRunRSDProbe(void) {
    gRSDLog = [NSMutableString string];
    gRSDEndpoints = [NSMutableArray array];

    // 1) mDNS Browse _remoted._tcp（5 秒窗口）
    rsdAppend(@"=== 第 1 步：mDNS 查询 _remoted._tcp ===");
    DNSServiceRef browseRef = NULL;
    DNSServiceErrorType berr = DNSServiceBrowse(&browseRef, 0, 0, "_remoted._tcp", "local.",
                                               (DNSServiceBrowseReply)rsdBrowseCallback, NULL);
    if (berr != kDNSServiceErr_NoError) {
        rsdAppend(@"❌ DNSServiceBrowse 失败: %d", berr);
    } else {
        int bfd = DNSServiceRefSockFD(browseRef);
        if (bfd >= 0) {
            for (int i = 0; i < 25; i++) {  // 25 × 200ms = 5 秒
                fd_set rset; FD_ZERO(&rset); FD_SET(bfd, &rset);
                struct timeval tv = {0, 200000};
                if (select(bfd + 1, &rset, NULL, NULL, &tv) > 0) DNSServiceProcessResult(browseRef);
            }
        }
        DNSServiceRefDeallocate(browseRef);
    }
    rsdAppend(@"mDNS 窗口结束，发现 %lu 个端点", (unsigned long)gRSDEndpoints.count);

    if (gRSDEndpoints.count == 0) {
        rsdAppend(@"❌ 没有发现 _remoted._tcp 端点（App 沙盒内 mDNS 可能被限制）");
        return gRSDLog;
    }

    // 2) 对每个端点尝试 RSDCheckin
    for (NSString *ep in gRSDEndpoints) {
        rsdAppend(@"=== 第 2 步：连接 %@ 并 RSDCheckin ===", ep);
        int err = 0;
        int fd = rsdConnectHostPort(ep, &err);
        if (fd < 0) {
            rsdAppend(@"❌ 连接失败 errno=%d (%s)", err, strerror(err));
            continue;
        }
        rsdAppend(@"✅ TCP 已连接");
        NSDictionary *checkin = @{@"Label": @"axtouch",
                                  @"ProtocolVersion": @"2",
                                  @"Request": @"RSDCheckin"};
        if (!rsdSendPlist(fd, checkin)) {
            rsdAppend(@"❌ RSDCheckin 发送失败");
            close(fd);
            continue;
        }
        rsdAppend(@"✅ RSDCheckin 已发送，等响应…");
        NSString *resp = rsdReadPlistMessage(fd, 10);
        if (resp) {
            rsdAppend(@"✅ RSD 响应（前 3000 字符）：");
            rsdAppend(@"%@", resp.length > 3000 ? [resp substringToIndex:3000] : resp);
        } else {
            rsdAppend(@"❌ 读 RSD 响应失败/超时");
        }
        close(fd);
    }
    return gRSDLog;
}
