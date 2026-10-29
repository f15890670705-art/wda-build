//
//  AXStream.mm
//  H.264 屏幕推流
//
//  协议完全照 go-screen/internal/iosscreen 的既有实现（PC 端零改动）：
//
//    连接后设备依次发：
//      [4B BE 0xFFFFFFFE] 哨兵
//      [4B w][4B h][4B maxSide]
//      [4B udidLen][udid]
//      [4B nameLen][name]              ← v46.1 起有；不发 PC 会等 400ms 超时
//      [4B BE 'h264' = 0x68323634]     ← 置 v2：之后按 12B 包头
//
//    12B 包头 = [8B BE ptsAndFlags][4B BE size]（+ payload）
//      bit63(SESSION)  : 无 payload，[4B flags][4B w][4B h]
//      bit62(CONFIG)   : payload = SPS+PPS（Annex-B）
//      bit61(KEY_FRAME): 该帧是 IDR
//      低 61 位        : pts（真实墙钟毫秒，严格单调 —— 照 mirror_stream.m v33 的结论）
//
//  编码器参数照 ios-daemon/Sources/Engine/mirror_stream.m 的 vt_create_inner：
//    RealTime / H264_High / 禁帧重排 / MaxKeyFrameInterval / ExpectedFrameRate / ABR。
//
//  采集不用它那套私有 IOKit（IOMobileFramebuffer，普通签名调不动），
//  改用实测 25ms 的 XCTest IPC 截图（见 AXAgentShotLowLevel 的同一条路）。
//
#import "AXStream.h"
#import <UIKit/UIKit.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <pthread.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <fcntl.h>
#import <errno.h>
#import <string.h>

extern "C" void ALogShim(NSString *fmt, ...);   /* 由 AXAgent.mm 提供（C 链接）*/

/* ---------------- 全局状态 ---------------- */
static int              g_listenFd = -1;
static volatile BOOL    g_running = NO;
static pthread_t        g_acceptTid;
static pthread_t        g_encTid;
static pthread_mutex_t  g_clientMu = PTHREAD_MUTEX_INITIALIZER;
static int              g_clients[4] = {-1, -1, -1, -1};
static volatile int     g_clientCount = 0;

static VTCompressionSessionRef g_vt = NULL;
static int              g_encW = 0, g_encH = 0;
static int              g_bitrate = 2000000;   /* 2 Mbps */
static int              g_fps = 20;
static int              g_maxSide = 720;

static volatile long long g_ptsMs = 0;         /* 真实墙钟毫秒，严格单调 */
static volatile BOOL    g_needConfig = YES;    /* 首帧 / 编码器重建后要发 SPS/PPS */
static volatile int     g_sentFrames = 0;
static volatile int     g_lastErr = 0;
static NSString         *g_lastErrMsg = nil;
static volatile int     g_preambleSent = 0;

/* ---------------- 小工具 ---------------- */

static long long AXNowMs(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (long long)tv.tv_sec * 1000LL + tv.tv_usec / 1000;
}

/* 严格单调递增（同毫秒内 +1），照 mirror_stream.m v33 的 PTS 处理 */
static long long AXNextPts(void) {
    long long now = AXNowMs();
    long long prev = g_ptsMs;
    if (now <= prev) now = prev + 1;
    g_ptsMs = now;
    return now;
}

static void AXSetErr(int code, NSString *msg) {
    g_lastErr = code;
    g_lastErrMsg = msg;
}

static BOOL AXWriteAll(int fd, const void *buf, size_t len) {
    const uint8_t *p = (const uint8_t *)buf;
    size_t off = 0;
    while (off < len) {
        ssize_t n = send(fd, p + off, len - off, 0);
        if (n <= 0) {
            if (errno == EINTR) continue;
            return NO;
        }
        off += (size_t)n;
    }
    return YES;
}

/* 发给所有已连接客户端；任一失败就把它摘掉 */
static void AXBroadcast(const void *hdr, size_t hdrLen, const void *payload, size_t payLen) {
    pthread_mutex_lock(&g_clientMu);
    for (int i = 0; i < 4; i++) {
        int fd = g_clients[i];
        if (fd < 0) continue;
        BOOL ok = AXWriteAll(fd, hdr, hdrLen);
        if (ok && payload && payLen) ok = AXWriteAll(fd, payload, payLen);
        if (!ok) {
            close(fd);
            g_clients[i] = -1;
            g_clientCount--;
            ALogShim(@"📺 客户端断开 fd=%d", fd);
        }
    }
    pthread_mutex_unlock(&g_clientMu);
}

static void AXPut32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v >> 24); p[1] = (uint8_t)(v >> 16);
    p[2] = (uint8_t)(v >> 8);  p[3] = (uint8_t)v;
}
static void AXPut64(uint8_t *p, uint64_t v) {
    for (int i = 0; i < 8; i++) p[i] = (uint8_t)(v >> (56 - i * 8));
}

/* ---------------- 握手 ---------------- */

static void AXSendPreamble(int fd, int w, int h, int maxSide) {
    NSMutableData *d = [NSMutableData data];
    uint8_t b[4];

    AXPut32(b, 0xFFFFFFFEu); [d appendBytes:b length:4];   /* 哨兵 */
    AXPut32(b, (uint32_t)w); [d appendBytes:b length:4];
    AXPut32(b, (uint32_t)h); [d appendBytes:b length:4];
    AXPut32(b, (uint32_t)maxSide); [d appendBytes:b length:4];

    /* UDID：普通 App 拿不到真 UDID，PC 端只是存起来备用、不校验 */
    NSString *udid = [[[UIDevice currentDevice] identifierForVendor] UUIDString] ?: @"axtouch";
    NSData *ud = [udid dataUsingEncoding:NSUTF8StringEncoding];
    AXPut32(b, (uint32_t)ud.length); [d appendBytes:b length:4];
    [d appendData:ud];

    /* 设备名：不发的话 PC 侧会白等 400ms 超时 */
    NSString *nm = [[UIDevice currentDevice] name] ?: @"AXTouch";
    NSData *nd = [nm dataUsingEncoding:NSUTF8StringEncoding];
    AXPut32(b, (uint32_t)nd.length); [d appendBytes:b length:4];
    [d appendData:nd];

    /* codec id：置 v2，之后按 12B 包头 */
    AXPut32(b, 0x68323634u); [d appendBytes:b length:4];

    if (AXWriteAll(fd, d.bytes, d.length)) {
        ALogShim(@"📺 preamble 已发 fd=%d %dx%d maxSide=%d", fd, w, h, maxSide);
    } else {
        ALogShim(@"📺 preamble 发送失败 fd=%d", fd);
    }
}

/* session 头：12B，无 payload —— [4B flags(bit31)][4B w][4B h] */
static void AXSendSessionHeader(int w, int h) {
    uint8_t pkt[12];
    memset(pkt, 0, sizeof(pkt));
    pkt[0] = 0x80;                      /* bit31 of first 4 bytes = SESSION */
    AXPut32(pkt + 4, (uint32_t)w);
    AXPut32(pkt + 8, (uint32_t)h);
    AXBroadcast(pkt, 12, NULL, 0);
}

/* 普通包：[8B ptsAndFlags][4B size][payload] */
static void AXSendPacket(uint64_t ptsAndFlags, const void *payload, size_t len) {
    uint8_t hdr[12];
    AXPut64(hdr, ptsAndFlags);
    AXPut32(hdr + 8, (uint32_t)len);
    AXBroadcast(hdr, 12, payload, len);
}

/* ---------------- 编码器 ---------------- */

static void AXVTCompressionCallback(void *outRefCon, void *srcFrameRefCon,
                                    OSStatus status, VTEncodeInfoFlags infoFlags,
                                    CMSampleBufferRef sbuf) {
    if (status != noErr || !sbuf) {
        if (status != noErr) AXSetErr((int)status, @"VT 编码失败");
        return;
    }

    /* 首次（或重建后）先补 SPS/PPS：CONFIG 包 */
    if (g_needConfig) {
        CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sbuf);
        if (fmt) {
            size_t cnt = 0;
            if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, 0, NULL, NULL, &cnt, NULL) == noErr && cnt > 0) {
                NSMutableData *cfg = [NSMutableData data];
                for (size_t i = 0; i < cnt; i++) {
                    const uint8_t *ps = NULL;
                    size_t psLen = 0;
                    if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, i, &ps, &psLen, NULL, NULL) == noErr && ps && psLen) {
                        uint8_t sc[4] = {0, 0, 0, 1};
                        [cfg appendBytes:sc length:4];
                        [cfg appendBytes:ps length:psLen];
                    }
                }
                if (cfg.length) {
                    AXSendPacket((uint64_t)1 << 62, cfg.bytes, cfg.length);   /* CONFIG */
                    ALogShim(@"📺 已发 SPS/PPS %lu 字节", (unsigned long)cfg.length);
                }
            }
        }
        g_needConfig = NO;
    }

    /* 取 NAL（VT 输出已是 Annex-B，带起始码） */
    CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sbuf);
    if (!bb) return;
    size_t len = CMBlockBufferGetDataLength(bb);
    if (len == 0) return;

    NSMutableData *nal = [NSMutableData dataWithLength:len];
    if (CMBlockBufferCopyDataBytes(bb, 0, len, nal.mutableBytes) != kCMBlockBufferNoErr) return;

    /* 关键帧判断 */
    BOOL keyframe = YES;
    CFArrayRef atts = CMSampleBufferGetSampleAttachmentsArray(sbuf, false);
    if (atts && CFArrayGetCount(atts) > 0) {
        NSDictionary *d = (__bridge NSDictionary *)CFArrayGetValueAtIndex(atts, 0);
        if (d && [d objectForKey:(__bridge id)kCMSampleAttachmentKey_NotSync]) keyframe = NO;
    }

    uint64_t pts = (uint64_t)(AXNextPts() & 0x1FFFFFFFFFFFFFFFULL);   /* 低 61 位 */
    if (keyframe) pts |= ((uint64_t)1 << 61);
    AXSendPacket(pts, nal.bytes, nal.length);
    g_sentFrames++;
}

static BOOL AXVTEnsure(int w, int h) {
    if (g_vt && g_encW == w && g_encH == h) return YES;
    if (g_vt) {
        VTCompressionSessionCompleteFrames(g_vt, kCMTimeInvalid);
        VTCompressionSessionInvalidate(g_vt);
        CFRelease(g_vt);
        g_vt = NULL;
    }
    NSDictionary *srcAttrs = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (NSString *)kCVPixelBufferWidthKey: @(w),
        (NSString *)kCVPixelBufferHeightKey: @(h),
    };
    OSStatus st = VTCompressionSessionCreate(NULL, (int32_t)w, (int32_t)h,
                                             kCMVideoCodecType_H264, NULL,
                                             (__bridge CFDictionaryRef)srcAttrs,
                                             NULL, AXVTCompressionCallback, NULL, &g_vt);
    if (st != noErr || !g_vt) {
        AXSetErr((int)st, [NSString stringWithFormat:@"VTCompressionSessionCreate 失败 st=%d", (int)st]);
        ALogShim(@"❌ VT 创建失败 st=%d w=%d h=%d", (int)st, w, h);
        return NO;
    }
    VTSessionSetProperty(g_vt, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(g_vt, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel);
    VTSessionSetProperty(g_vt, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    VTSessionSetProperty(g_vt, kVTCompressionPropertyKey_MaxKeyFrameInterval, (__bridge CFNumberRef)@(g_fps * 10));
    VTSessionSetProperty(g_vt, kVTCompressionPropertyKey_ExpectedFrameRate, (__bridge CFNumberRef)@(g_fps));
    VTSessionSetProperty(g_vt, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFNumberRef)@(g_bitrate));
    VTCompressionSessionPrepareToEncodeFrames(g_vt);

    g_encW = w; g_encH = h;
    g_needConfig = YES;
    g_ptsMs = 0;
    ALogShim(@"✅ VT 编码器就绪 %dx%d  %d kbps  %d fps", w, h, g_bitrate / 1000, g_fps);
    return YES;
}

/* ---------------- 采集：XCTest IPC 截图（与 shot2 同一条路） ---------------- */

/* 返回：编码数据（NSData）或 nil。走 XCUIScreen 的 screenDataSource → screenshotIPCInterface。
   rect 用真实尺寸（IPC 不认 CGRectNull）。 */
static NSData *AXGrabEncodedData(CGSize *outSize) {
    Class scrCls = NSClassFromString(@"XCUIScreen");
    if (!scrCls) { AXSetErr(-1, @"XCUIScreen 不存在"); return nil; }
    id screen = ((id (*)(id, SEL))objc_msgSend)(scrCls, NSSelectorFromString(@"mainScreen"));
    if (!screen) { AXSetErr(-2, @"mainScreen 为 nil"); return nil; }

    SEL sdSel = NSSelectorFromString(@"screenDataSource");
    if (![screen respondsToSelector:sdSel]) { AXSetErr(-3, @"无 screenDataSource"); return nil; }
    id ds = ((id (*)(id, SEL))objc_msgSend)(screen, sdSel);
    SEL ipcSel = NSSelectorFromString(@"screenshotIPCInterface");
    if (![ds respondsToSelector:ipcSel]) { AXSetErr(-4, @"无 screenshotIPCInterface"); return nil; }
    id ipc = ((id (*)(id, SEL))objc_msgSend)(ds, ipcSel);
    if (!ipc) { AXSetErr(-5, @"ipc 为 nil"); return nil; }

    Class reqCls = NSClassFromString(@"XCTScreenshotRequest");
    Class qCls = NSClassFromString(@"XCTImageQuality");
    if (!reqCls || ![reqCls instancesRespondToSelector:NSSelectorFromString(@"initWithScreenID:rect:encoding:options:")]) {
        AXSetErr(-6, @"无 XCTScreenshotRequest"); return nil;
    }

    id q = nil;
    if (qCls) {
        id qa = ((id (*)(id, SEL))objc_msgSend)(qCls, NSSelectorFromString(@"alloc"));
        SEL qi = NSSelectorFromString(@"initWithImageQuality:");
        if ([qa respondsToSelector:qi]) q = ((id (*)(id, SEL, double))objc_msgSend)(qa, qi, 1.0);
    }

    CGSize pts = [UIScreen mainScreen].bounds.size;
    CGRect rect = CGRectMake(0, 0, pts.width, pts.height);
    long long sid = 0;
    SEL dSel = NSSelectorFromString(@"displayID");
    if ([screen respondsToSelector:dSel]) sid = ((long long (*)(id, SEL))objc_msgSend)(screen, dSel);

    id reqObj = ((id (*)(id, SEL))objc_msgSend)(reqCls, NSSelectorFromString(@"alloc"));
    typedef id (*InitReqFn)(id, SEL, long long, CGRect, id, unsigned long);
    id req = ((InitReqFn)objc_msgSend)(reqObj, NSSelectorFromString(@"initWithScreenID:rect:encoding:options:"),
                                       sid, rect, q, 0UL);
    if (!req) { AXSetErr(-7, @"request 构造失败"); return nil; }

    SEL callSel = NSSelectorFromString(@"requestScreenshotWithRequest:withReply:");
    if (![ipc respondsToSelector:callSel]) { AXSetErr(-8, @"ipc 无 requestScreenshot"); return nil; }

    __block NSData *result = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    void (^reply)(id, id) = ^(id v, id e) {
        if (v && [v respondsToSelector:NSSelectorFromString(@"data")]) {
            id d = ((id (*)(id, SEL))objc_msgSend)(v, NSSelectorFromString(@"data"));
            if ([d isKindOfClass:[NSData class]]) result = (NSData *)d;
        }
        dispatch_semaphore_signal(sem);
    };
    ((void (*)(id, SEL, id, id))objc_msgSend)(ipc, callSel, req, reply);
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC))) != 0) {
        AXSetErr(-9, @"截图超时");
        return nil;
    }
    if (!result) { AXSetErr(-10, @"截图返回空"); return nil; }

    /* 尺寸信息从解码后的图里拿（调用方还要用来算编码尺寸） */
    if (outSize) {
        CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)result, NULL);
        if (src) {
            NSDictionary *props = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(src, 0, NULL));
            NSNumber *pw = props[(NSString *)kCGImagePropertyPixelWidth];
            NSNumber *ph = props[(NSString *)kCGImagePropertyPixelHeight];
            if (pw && ph) *outSize = CGSizeMake(pw.doubleValue, ph.doubleValue);
            CFRelease(src);
        }
    }
    return result;
}

/* ---------------- 编码循环 ---------------- */

static void *AXEncodeLoop(void *arg) {
    (void)arg;
    ALogShim(@"🎬 编码循环启动");
    int frameCount = 0;
    long long statT0 = AXNowMs();
    int statFrames = 0;

    while (g_running) {
        @autoreleasepool {
            if (g_clientCount <= 0) {
                /* 没人看就不抓，省电省 CPU */
                usleep(50 * 1000);
                continue;
            }

            long long t0 = AXNowMs();
            CGSize px = CGSizeZero;
            NSData *enc = AXGrabEncodedData(&px);
            if (!enc) {
                usleep(30 * 1000);
                continue;
            }
            long long t1 = AXNowMs();

            /* 目标编码尺寸：长边 = maxSide，保持比例、对齐到偶数 */
            int tw = g_encW, th = g_encH;
            if (tw == 0 || th == 0) {
                CGFloat longSide = MAX(px.width, px.height);
                CGFloat k = longSide > 0 ? (CGFloat)g_maxSide / longSide : 1.0;
                if (k > 1.0) k = 1.0;
                /* 竖屏：宽 = min(px.w,px.h)*k，高 = max*k；横屏反过来 */
                if (px.height >= px.width) {
                    tw = (int)(round(px.width * k)); th = (int)(round(px.height * k));
                } else {
                    tw = (int)(round(px.width * k)); th = (int)(round(px.height * k));
                }
                tw &= ~1; th &= ~1;   /* 偶数 */
                if (tw < 16) tw = 16;
                if (th < 16) th = 16;
            }
            if (!AXVTEnsure(tw, th)) { usleep(100 * 1000); continue; }

            /* 只有第一次连上（或重建后）才发 session 头 + preamble */
            if (!g_preambleSent) {
                pthread_mutex_lock(&g_clientMu);
                for (int i = 0; i < 4; i++) {
                    int fd = g_clients[i];
                    if (fd < 0) continue;
                    AXSendPreamble(fd, tw, th, g_maxSide);
                }
                pthread_mutex_unlock(&g_clientMu);
                AXSendSessionHeader(tw, th);
                g_preambleSent = 1;
                g_needConfig = YES;
            }

            /* 解码 + 一次绘制到 CVPixelBuffer（缩放合并进这一步） */
            CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)enc, NULL);
            CGImageRef img = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
            if (src) CFRelease(src);
            if (!img) { usleep(20 * 1000); continue; }

            CVPixelBufferRef pb = NULL;
            NSDictionary *pbAttrs = @{
                (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
                (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            };
            CVReturn cr = CVPixelBufferCreate(kCFAllocatorDefault, tw, th,
                                              kCVPixelFormatType_32BGRA,
                                              (__bridge CFDictionaryRef)pbAttrs, &pb);
            if (cr != kCVReturnSuccess || !pb) {
                CGImageRelease(img);
                AXSetErr((int)cr, @"CVPixelBufferCreate 失败");
                usleep(50 * 1000);
                continue;
            }
            CVPixelBufferLockBaseAddress(pb, 0);
            void *base = CVPixelBufferGetBaseAddress(pb);
            size_t bpr = CVPixelBufferGetBytesPerRow(pb);
            CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
            CGContextRef ctx = CGBitmapContextCreate(base, tw, th, 8, bpr, cs,
                kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst);
            CGColorSpaceRelease(cs);
            if (ctx) {
                CGContextDrawImage(ctx, CGRectMake(0, 0, tw, th), img);
                CGContextRelease(ctx);
            }
            CVPixelBufferUnlockBaseAddress(pb, 0);
            CGImageRelease(img);
            long long t2 = AXNowMs();

            /* 先强制每帧 IDR，跑通再开帧间预测 */
            CFDictionaryRef frameProps = (__bridge CFDictionaryRef)@{
                (NSString *)kVTEncodeFrameOptionKey_ForceKeyFrame: @YES
            };
            CMTime pcm = CMTimeMake(AXNextPts(), 1000);
            VTEncodeInfoFlags flags = 0;
            OSStatus es = VTCompressionSessionEncodeFrame(g_vt, pb, pcm, kCMTimeInvalid,
                                                          frameProps, NULL, &flags);
            CVPixelBufferRelease(pb);
            if (es != noErr) {
                AXSetErr((int)es, @"EncodeFrame 失败");
                usleep(20 * 1000);
                continue;
            }
            long long t3 = AXNowMs();

            frameCount++;
            statFrames++;
            if (frameCount % 30 == 0) {
                long long el = AXNowMs() - t0;
                ALogShim(@"🎬 第 %d 帧  抓%.0f 转%.0f 提交%.0f ms  %dx%d  已发%d",
                         frameCount, (double)(t1 - t0), (double)(t2 - t1),
                         (double)(t3 - t2), tw, th, g_sentFrames);
            }

            /* 节奏控制：目标 fps */
            long long el = AXNowMs() - t0;
            long long budget = 1000 / (g_fps > 0 ? g_fps : 20);
            if (el < budget) usleep((useconds_t)((budget - el) * 1000));
        }
    }
    ALogShim(@"🎬 编码循环退出（共 %d 帧）", frameCount);
    return NULL;
}

/* ---------------- 监听 ---------------- */

static void *AXAcceptLoop(void *arg) {
    (void)arg;
    ALogShim(@"📡 accept 循环启动");
    while (g_running) {
        struct sockaddr_in addr;
        socklen_t alen = sizeof(addr);
        int fd = accept(g_listenFd, (struct sockaddr *)&addr, &alen);
        if (fd < 0) {
            if (errno == EINTR) continue;
            if (!g_running) break;
            usleep(50 * 1000);
            continue;
        }
        int one = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        char ip[64] = {0};
        inet_ntop(AF_INET, &addr.sin_addr, ip, sizeof(ip));
        ALogShim(@"📡 PC 连上来了 %s", ip);

        pthread_mutex_lock(&g_clientMu);
        int slot = -1;
        for (int i = 0; i < 4; i++) if (g_clients[i] < 0) { slot = i; break; }
        if (slot < 0) {
            pthread_mutex_unlock(&g_clientMu);
            close(fd);
            ALogShim(@"📡 客户端已满，拒绝 %s", ip);
            continue;
        }
        g_clients[slot] = fd;
        g_clientCount++;
        pthread_mutex_unlock(&g_clientMu);

        /* 立刻发 preamble（用当前编码尺寸；还没编码过就先给 0，PC 会等 session 头修正） */
        int w = g_encW > 0 ? g_encW : g_maxSide;
        int h = g_encH > 0 ? g_encH : (int)(g_maxSide * 2796.0 / 1290.0);
        AXSendPreamble(fd, w, h, g_maxSide);
        AXSendSessionHeader(w, h);
        g_needConfig = YES;
        g_preambleSent = 1;
    }
    ALogShim(@"📡 accept 循环退出");
    return NULL;
}

/* ---------------- 对外接口 ---------------- */

BOOL AXStreamStart(uint16_t port) {
    if (g_running) return YES;

    g_listenFd = socket(AF_INET, SOCK_STREAM, 0);
    if (g_listenFd < 0) {
        AXSetErr(errno, @"socket() 失败");
        ALogShim(@"❌ socket() 失败 errno=%d", errno);
        return NO;
    }
    int one = 1;
    setsockopt(g_listenFd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(port);

    if (bind(g_listenFd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        AXSetErr(errno, [NSString stringWithFormat:@"bind(%d) 失败 errno=%d", port, errno]);
        ALogShim(@"❌ bind %d 失败 errno=%d（端口被占？）", port, errno);
        close(g_listenFd);
        g_listenFd = -1;
        return NO;
    }
    if (listen(g_listenFd, 4) != 0) {
        AXSetErr(errno, @"listen 失败");
        close(g_listenFd);
        g_listenFd = -1;
        return NO;
    }

    g_running = YES;
    g_ptsMs = 0;
    g_preambleSent = 0;
    g_sentFrames = 0;
    g_encW = g_encH = 0;

    pthread_create(&g_acceptTid, NULL, AXAcceptLoop, NULL);
    pthread_create(&g_encTid, NULL, AXEncodeLoop, NULL);
    ALogShim(@"✅ 推流服务已在 0.0.0.0:%d 监听", port);
    return YES;
}

void AXStreamStop(void) {
    if (!g_running) return;
    g_running = NO;

    if (g_listenFd >= 0) { close(g_listenFd); g_listenFd = -1; }

    pthread_mutex_lock(&g_clientMu);
    for (int i = 0; i < 4; i++) {
        if (g_clients[i] >= 0) { close(g_clients[i]); g_clients[i] = -1; }
    }
    g_clientCount = 0;
    pthread_mutex_unlock(&g_clientMu);

    if (g_vt) {
        VTCompressionSessionCompleteFrames(g_vt, kCMTimeInvalid);
        VTCompressionSessionInvalidate(g_vt);
        CFRelease(g_vt);
        g_vt = NULL;
    }
    g_encW = g_encH = 0;
    g_preambleSent = 0;
    ALogShim(@"🛑 推流服务已停止");
}

BOOL AXStreamIsRunning(void) { return g_running; }

void AXStreamSetParams(int bitrateBps, int fps, int maxSide) {
    if (bitrateBps > 0) g_bitrate = bitrateBps;
    if (fps > 0) g_fps = fps;
    if (maxSide > 0) g_maxSide = maxSide;
    ALogShim(@"⚙️ 推流参数：%d kbps  %d fps  maxSide=%d", g_bitrate / 1000, g_fps, g_maxSide);
    /* 码率/帧率变了要重建编码器 */
    if (g_vt) { g_encW = 0; g_encH = 0; }
}

NSDictionary *AXStreamStats(void) {
    return @{
        @"running": @(g_running),
        @"clients": @(g_clientCount),
        @"sent": @(g_sentFrames),
        @"w": @(g_encW),
        @"h": @(g_encH),
        @"bitrate": @(g_bitrate),
        @"fps": @(g_fps),
        @"maxSide": @(g_maxSide),
        @"err": @(g_lastErr),
        @"errMsg": g_lastErrMsg ?: @"",
    };
}
