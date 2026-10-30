//
//  AXAgent.mm
//  1:1 复刻 AScript 的 ASAgen 启动链与触控链（依据其二进制反汇编）
//
//  反汇编依据（ASAgent 类，二进制地址）：
//    -[loadXCTestStack]          @0x100149904
//    -[bootstrap]                @0x100149ba4
//    -[enableInProcessAccessibility] @0x10014a104
//    -[finishBootstrap]          @0x10014ab28
//    -[tuneTestmanagerdStateTimeout] @0x10014b898
//    -[ddiAutomationFrameworkPath]   @0x10014b96c
//    -[installUITestConfiguration]   @0x10014bb00
//    -[touchPathAtPoint:offset:] @0x10014c4dc
//    -[recordWithPath:]          @0x10014c59c
//    -[synthesizeRecord:error:]  @0x10014c6ac
//
//  调用序列（原样）：
//    1. dlopen 框架（DDI 优先，8 条路径，RTLD_NOW|RTLD_GLOBAL）
//    2. NSClassFromString(@"XCTRunnerDaemonSession") == nil 才继续
//    3. _AXSSetAutomationEnabled(YES) + AXCodeLoader + XCAXClient_iOS
//    4. [XCTRunnerDaemonSession sharedSession]
//    5. -requestAutomationSessionForTestTargetWithPID:(getpid()) preferredBackendPath:nil reply:^{}
//    6. -enableAutomationModeWithError:
//    7. -finishInitializationForUIAutomation
//    8. -requestBackgroundAssertionForPID:reply:
//    9. -implicitEventConfirmationIntervalForCurrentContext
//   10. _XCTSetApplicationStateTimeout(0.1)
//   11. XCTestConfiguration initializeForUITesting + sessionIdentifier/productModuleName
//   12. -setImplicitEventConfirmationIntervalForCurrentContext:0
//   13. FBConfiguration setWaitForIdleTimeout:0
//
//  触控：
//    XCPointerEventPath initForTouchAtPoint:offset:
//    XCSynthesizedEventRecord initWithName:interfaceOrientation: + addPointerEventPath:
//    [daemonSession synthesizeEvent:completion:]
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <unistd.h>
#import <stdarg.h>
#import <ctype.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonCryptor.h>
#import <ReplayKit/ReplayKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <CoreLocation/CoreLocation.h>
#import "AXStream.h"
#import <sys/time.h>
#import <signal.h>
#import <string.h>
#import <stdlib.h>
#import <stdio.h>
#import <time.h>
#import <errno.h>
#import <fcntl.h>
#import <arpa/inet.h>
#import <netinet/tcp.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <pthread.h>
#import <ImageIO/ImageIO.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>

static id  gSession = nil;
static BOOL gReady = NO;
static NSString *gLastError = nil;

#pragma mark - 日志（写 Documents/agent.log，PC 可拉取）

static NSString *AXLogPath(void) {
    static NSString *p = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *d = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        p = [d.firstObject stringByAppendingPathComponent:@"agent.log"];
    });
    return p;
}

/* ★ 2026-10-31 修「运行日志满屏乱码」的根因：
   以前 ALog 不加锁，控制队列 / 编码循环 / VT 回调多个线程同时
   「seek 到末尾 + writeData」，写到一半被别的线程插进来 → 字节交错，
   一个汉字的 3 个字节被拆到两处 → 文件里出现非法 UTF-8 序列。
   只要有一处坏字节，日志页整块 UTF-8 解码就失败（以前还会退化成 Latin1，整页花）。
   现在：全局锁串行化 + 复用 NSDateFormatter（顺带省掉每行一次 formatter 创建）。 */
static NSLock *gLogLock = nil;
static NSDateFormatter *gLogDF = nil;

static void ALog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"%@", s);

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gLogLock = [NSLock new];
        gLogDF = [NSDateFormatter new];
        gLogDF.dateFormat = @"HH:mm:ss.SSS";
    });

    [gLogLock lock];
    @try {
        NSString *line = [NSString stringWithFormat:@"%@ %@\n",
                          [gLogDF stringFromDate:[NSDate date]], s];
        NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSString *path = AXLogPath();
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:path]) {
            [d writeToFile:path atomically:YES];
        } else {
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
            if (fh) {
                [fh seekToEndOfFile];
                [fh writeData:d];
                [fh closeFile];
            }
        }
    } @catch (NSException *e) {
        /* 日志失败绝不能影响主流程 */
    }
    [gLogLock unlock];
}

/* AXStream.mm 用的日志入口（ALog 是 static，跨文件用不了） */
extern "C" void ALogShim(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    ALog(@"%@", s);
}

#pragma mark - 动态调用小工具

/* 定义在文件后部（录屏探针那节），这里先声明 */
static void AXDumpClass(NSString *name);

static void AXCallVoid(id obj, NSString *selName) {
    SEL sel = NSSelectorFromString(selName);
    if (!obj || ![obj respondsToSelector:sel]) return;
    @try {
        void (*fp)(id, SEL) = (void (*)(id, SEL))objc_msgSend;
        fp(obj, sel);
    } @catch (NSException *e) { ALog(@"  ❌ %@ 异常: %@", selName, e.reason); }
}

static id AXShared(id cls, NSArray<NSString *> *names) {
    if (!cls) return nil;
    for (NSString *n in names) {
        SEL sel = NSSelectorFromString(n);
        if ([cls respondsToSelector:sel]) {
            @try {
                id (*fp)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
                id r = fp(cls, sel);
                if (r) { ALog(@"  ✅ %@ 取到实例: %@", n, NSStringFromClass([r class])); return r; }
            } @catch (NSException *e) { ALog(@"  ❌ %@ 异常: %@", n, e.reason); }
        }
    }
    return nil;
}

#pragma mark - 1. loadXCTestStack（DDI 优先）

static const char *kXCTestPaths[] = {
    "/Developer/Library/Frameworks/XCTest.framework/XCTest",
    "/System/Developer/Library/Frameworks/XCTest.framework/XCTest",
    "/Developer/Library/PrivateFrameworks/XCTestCore.framework/XCTestCore",
    "/System/Developer/Library/PrivateFrameworks/XCTestCore.framework/XCTestCore",
    "/Developer/Library/PrivateFrameworks/XCTAutomationSupport.framework/XCTAutomationSupport",
    "/System/Developer/Library/PrivateFrameworks/XCTAutomationSupport.framework/XCTAutomationSupport",
    "/Developer/Library/PrivateFrameworks/XCUIAutomation.framework/XCUIAutomation",
    "/System/Developer/Library/PrivateFrameworks/XCUIAutomation.framework/XCUIAutomation",
};

static BOOL AXLoadXCTestStack(void) {
    ALog(@"--- 1) loadXCTestStack（DDI 优先，同 AScript）");

    if (NSClassFromString(@"XCTRunnerDaemonSession")) {
        ALog(@"  ✅ XCTRunnerDaemonSession 已存在，跳过加载");
        return YES;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    int ok = 0, tried = 0;
    for (int i = 0; i < (int)(sizeof(kXCTestPaths) / sizeof(kXCTestPaths[0])); i++) {
        const char *p = kXCTestPaths[i];
        NSString *sp = [NSString stringWithUTF8String:p];
        BOOL exists = [fm fileExistsAtPath:sp];
        if (!exists) continue;
        tried++;
        dlerror();
        void *h = dlopen(p, RTLD_NOW | RTLD_GLOBAL);   // 0xa，与 AScript 一致
        const char *err = dlerror();
        if (h) {
            ok++;
            ALog(@"  ✅ dlopen %@", sp);
        } else {
            ALog(@"  ❌ dlopen %@  err=%s", sp, err ? err : "?");
        }
    }
    ALog(@"  DDI 路径：存在 %d 条，成功 %d 条", tried, ok);

    if (!NSClassFromString(@"XCTRunnerDaemonSession")) {
        ALog(@"  ⚠️ DDI 未提供 XCTRunnerDaemonSession，回退到包内框架");
        NSString *dir = [NSString stringWithFormat:@"%@/Frameworks", [[NSBundle mainBundle] bundlePath]];
        setenv("DYLD_FRAMEWORK_PATH", [dir UTF8String], 1);
        NSArray *order = @[@"Testing", @"XCTestCore", @"XCTAutomationSupport", @"XCTest",
                           @"XCTestSupport", @"XCUIAutomation", @"XCUnit"];
        for (NSString *n in order) {
            NSString *p = [NSString stringWithFormat:@"%@/%@.framework/%@", dir, n, n];
            if (![fm fileExistsAtPath:p]) continue;
            dlerror();
            if (dlopen([p UTF8String], RTLD_NOW | RTLD_GLOBAL)) ALog(@"  ✅ 包内 %@", n);
            else ALog(@"  ❌ 包内 %@: %s", n, dlerror());
        }
    }

    BOOL has = NSClassFromString(@"XCTRunnerDaemonSession") != nil;
    ALog(@"  XCTRunnerDaemonSession 可用: %@", has ? @"YES" : @"NO");
    return has;
}

#pragma mark - 2. enableInProcessAccessibility

static void AXEnableInProcessAccessibility(void) {
    ALog(@"--- 2) enableInProcessAccessibility");
    dlopen("/usr/lib/libAccessibility.dylib", RTLD_LAZY);

    void (*setAuto)(BOOL) = (void (*)(BOOL))dlsym(RTLD_DEFAULT, "_AXSSetAutomationEnabled");
    if (setAuto) {
        @try { setAuto(YES); ALog(@"  ✅ _AXSSetAutomationEnabled(YES)"); }
        @catch (NSException *e) { ALog(@"  ❌ _AXSSetAutomationEnabled: %@", e.reason); }
    } else {
        ALog(@"  ❌ dlsym _AXSSetAutomationEnabled 为空");
    }

    Class loaderCls = NSClassFromString(@"AXCodeLoader");
    ALog(@"  AXCodeLoader: %@", loaderCls ? @"有" : @"无");
    if (loaderCls) {
        id loader = AXShared(loaderCls, @[@"sharedInstance", @"sharedAXCodeLoader", @"sharedLoader", @"shared"]);
        if (loader) {
            if ([loader respondsToSelector:NSSelectorFromString(@"setShouldAutoloadAccessibilityCodeItems:")]) {
                @try {
                    void (*fp)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))objc_msgSend;
                    fp(loader, NSSelectorFromString(@"setShouldAutoloadAccessibilityCodeItems:"), YES);
                    ALog(@"  ✅ setShouldAutoloadAccessibilityCodeItems:YES");
                } @catch (NSException *e) { ALog(@"  ❌ setShouldAutoload: %@", e.reason); }
            }
            AXCallVoid(loader, @"_loadAccessibilityCodeItems");
        }
    }

    Class axCls = NSClassFromString(@"XCAXClient_iOS");
    ALog(@"  XCAXClient_iOS: %@", axCls ? @"有" : @"无");
    if (axCls) {
        id client = AXShared(axCls, @[@"sharedClient"]);
        if (client) ALog(@"  ✅ XCAXClient_iOS.sharedClient 就绪");
    }
}

#pragma mark - 3. bootstrap

static long AXOrientationMainThread(void) {
    long o = UIInterfaceOrientationPortrait;
    UIWindow *w = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *win in ((UIWindowScene *)s).windows) {
            if (win.isKeyWindow) { w = win; break; }
        }
        if (w) break;
    }
    if (w && w.windowScene) o = (long)w.windowScene.interfaceOrientation;
    return o;
}

static long AXInterfaceOrientation(void) {
    if ([NSThread isMainThread]) {
        long o = AXOrientationMainThread();
        ALog(@"  界面方向: %ld", o);
        return o;
    }
    __block long o = UIInterfaceOrientationPortrait;
    dispatch_sync(dispatch_get_main_queue(), ^{ o = AXOrientationMainThread(); });
    ALog(@"  界面方向: %ld", o);
    return o;
}

static BOOL AXAgentBootstrap(void) {
    @try {
        @autoreleasepool {
            ALog(@"===== AXAgent bootstrap 开始（复刻 ASAgen）=====");

            if (!AXLoadXCTestStack()) {
                gLastError = @"框架加载失败";
                ALog(@"❌ 终止：%@", gLastError);
                return NO;
            }

            AXEnableInProcessAccessibility();

            ALog(@"--- 3) XCTRunnerDaemonSession.sharedSession");
            Class cls = NSClassFromString(@"XCTRunnerDaemonSession");
            if (!cls) {
                gLastError = @"XCTRunnerDaemonSession 类不存在";
                ALog(@"❌ 终止：%@", gLastError);
                return NO;
            }
            SEL ss = NSSelectorFromString(@"sharedSession");
            if (![cls respondsToSelector:ss]) {
                gLastError = @"无 sharedSession";
                ALog(@"❌ 终止：%@", gLastError);
                return NO;
            }

            id session = nil;
            @try {
                id (*fp)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
                session = fp(cls, ss);
            } @catch (NSException *e) {
                gLastError = [NSString stringWithFormat:@"sharedSession 抛异常 %@: %@", e.name, e.reason];
                ALog(@"❌ %@", gLastError);
                return NO;
            }
            if (!session) {
                gLastError = @"sharedSession 返回 nil";
                ALog(@"❌ 终止：%@", gLastError);
                return NO;
            }
            gSession = session;
            ALog(@"  ✅ sharedSession = %p", (__bridge void *)session);

            pid_t pid = getpid();
            ALog(@"  目标 PID = %d（自己）", pid);

            // 5) requestAutomationSessionForTestTargetWithPID:preferredBackendPath:reply:
            SEL rs = NSSelectorFromString(@"requestAutomationSessionForTestTargetWithPID:preferredBackendPath:reply:");
            if (session && [session respondsToSelector:rs]) {
                @try {
                    void (^reply)(id) = ^(id a) {
                        // 参数可能是 BOOL/NSError*/裸指针，绝不能用 %@ 格式化（会访问野指针崩）
                        ALog(@"  📥 requestAutomationSession reply 收到（%@）", a ? @"非空" : @"空");
                    };
                    void (*fp)(id, SEL, int, id, id) = (void (*)(id, SEL, int, id, id))objc_msgSend;
                    fp(session, rs, (int)pid, nil, reply);
                    ALog(@"  ✅ requestAutomationSession 已发出");
                } @catch (NSException *e) {
                    ALog(@"  ❌ requestAutomationSession 异常: %@ / %@", e.name, e.reason);
                }
            } else {
                ALog(@"  ⚠️ 无 requestAutomationSession 方法");
            }

            // 6) enableAutomationModeWithError:
            SEL es = NSSelectorFromString(@"enableAutomationModeWithError:");
            if ([session respondsToSelector:es]) {
                @try {
                    NSError *err = nil;
                    BOOL (*fp)(id, SEL, NSError **) = (BOOL (*)(id, SEL, NSError **))objc_msgSend;
                    BOOL ok = fp(session, es, &err);
                    ALog(@"  enableAutomationMode = %@ err=%@", ok ? @"YES" : @"NO", err.localizedDescription ?: @"(nil)");
                } @catch (NSException *e) {
                    ALog(@"  ❌ enableAutomationMode 异常: %@ / %@", e.name, e.reason);
                }
            }

            // 7) finishInitializationForUIAutomation
            AXCallVoid(session, @"finishInitializationForUIAutomation");
            ALog(@"  finishInitializationForUIAutomation 已调用");

            // 8) requestBackgroundAssertionForPID:reply:
            SEL bs = NSSelectorFromString(@"requestBackgroundAssertionForPID:reply:");
            if ([session respondsToSelector:bs]) {
                @try {
                    void (^reply)(id) = ^(id a) { ALog(@"  📥 backgroundAssertion reply 收到（%@）", a ? @"非空" : @"空"); };
                    void (*fp)(id, SEL, int, id) = (void (*)(id, SEL, int, id))objc_msgSend;
                    fp(session, bs, (int)pid, reply);
                    ALog(@"  ✅ requestBackgroundAssertion 已发出");
                } @catch (NSException *e) { ALog(@"  ❌ backgroundAssertion: %@", e.reason); }
            }

            // 9) implicitEventConfirmationIntervalForCurrentContext
            SEL is = NSSelectorFromString(@"implicitEventConfirmationIntervalForCurrentContext");
            if ([session respondsToSelector:is]) {
                @try {
                    double (*fp)(id, SEL) = (double (*)(id, SEL))objc_msgSend;
                    double d = fp(session, is);
                    ALog(@"  implicitEventConfirmationInterval = %.3f", d);
                } @catch (NSException *e) { ALog(@"  ❌ implicitInterval: %@", e.reason); }
            }

            gReady = YES;
            gLastError = nil;
            ALog(@"✅ 会话就绪（gReady=YES）");

            // 10) _XCTSetApplicationStateTimeout(0.1)
            void (*setTimeout)(double) = (void (*)(double))dlsym(RTLD_DEFAULT, "_XCTSetApplicationStateTimeout");
            if (setTimeout) {
                @try { setTimeout(0.1); ALog(@"  ✅ _XCTSetApplicationStateTimeout(0.1)"); }
                @catch (NSException *e) { ALog(@"  ❌ setTimeout: %@", e.reason); }
            }

            // 11) XCTestConfiguration
            Class cfgCls = NSClassFromString(@"XCTestConfiguration");
            if (cfgCls) {
                SEL atc = NSSelectorFromString(@"activeTestConfiguration");
                id cfg = nil;
                if ([cfgCls respondsToSelector:atc]) {
                    @try {
                        id (*fp)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
                        cfg = fp(cfgCls, atc);
                    } @catch (NSException *e) { }
                }
                if (!cfg) {
                    @try {
                        cfg = [[cfgCls alloc] init];
                        if ([cfg respondsToSelector:NSSelectorFromString(@"initializeForUITesting")]) {
                            void (*fp)(id, SEL) = (void (*)(id, SEL))objc_msgSend;
                            fp(cfg, NSSelectorFromString(@"initializeForUITesting"));
                        }
                        [cfg setValue:[NSUUID UUID] forKey:@"sessionIdentifier"];
                        [cfg setValue:@"AXAgent" forKey:@"productModuleName"];
                        ALog(@"  ✅ 新建 XCTestConfiguration（sessionIdentifier/productModuleName=AXAgent）");
                    } @catch (NSException *e) { ALog(@"  ❌ XCTestConfiguration: %@", e.reason); }
                } else {
                    ALog(@"  XCTestConfiguration 已存在: %@", cfg);
                }
            }

            // 12) setImplicitEventConfirmationIntervalForCurrentContext:0
            SEL si = NSSelectorFromString(@"setImplicitEventConfirmationIntervalForCurrentContext:");
            if ([session respondsToSelector:si]) {
                @try {
                    void (*fp)(id, SEL, double) = (void (*)(id, SEL, double))objc_msgSend;
                    fp(session, si, 0.0);
                    ALog(@"  ✅ implicitEventConfirmationInterval := 0");
                } @catch (NSException *e) { ALog(@"  ❌ setImplicit: %@", e.reason); }
            }

            // 13) FBConfiguration setWaitForIdleTimeout:0
            Class fbCls = NSClassFromString(@"FBConfiguration");
            SEL wid = NSSelectorFromString(@"setWaitForIdleTimeout:");
            if (fbCls && [fbCls respondsToSelector:wid]) {
                @try {
                    void (*fp)(id, SEL, double) = (void (*)(id, SEL, double))objc_msgSend;
                    fp(fbCls, wid, 0.0);
                    ALog(@"  ✅ FBConfiguration.waitForIdleTimeout := 0");
                } @catch (NSException *e) { ALog(@"  ❌ FBConfiguration: %@", e.reason); }
            }

            ALog(@"===== AXAgent bootstrap 完成 =====");
            return YES;
        }
    } @catch (NSException *e) {
        gLastError = [NSString stringWithFormat:@"bootstrap 异常 %@: %@", e.name, e.reason];
        ALog(@"❌ %@", gLastError);
        return NO;
    }
}

#pragma mark - 4. 触控（与 ASAgen 同一条链）

extern "C" BOOL AXAgentIsReady(void) { return gReady && gSession != nil; }
extern "C" NSString *AXAgentLastError(void) { return gLastError; }
extern "C" NSString *AXAgentLogPath(void) { return AXLogPath(); }

extern "C" BOOL AXAgentBootstrapNow(void) {
    return AXAgentBootstrap();
}

/* 核心实现（提交完立刻返回，不等待）。控制通道必须用这个 ——
   控制线程是串行的，这里一阻塞，后面的点击/滑动全在队列里排队，
   表现就是"点了半天才反应"。 */
static BOOL AXTapCore(double x, double y) {
    if (!gReady || !gSession) {
        ALog(@"❌ tap 失败：会话未就绪");
        return NO;
    }
    @try {
        Class pathCls = NSClassFromString(@"XCPointerEventPath");
        Class recCls = NSClassFromString(@"XCSynthesizedEventRecord");
        if (!pathCls || !recCls) {
            ALog(@"❌ tap 失败：XCPointerEventPath/XCSynthesizedEventRecord 不存在");
            return NO;
        }
        SEL initPath = NSSelectorFromString(@"initForTouchAtPoint:offset:");
        id (*fp1)(id, SEL, CGPoint, double) = (id (*)(id, SEL, CGPoint, double))objc_msgSend;
        id path = fp1([pathCls alloc], initPath, CGPointMake(x, y), 0.0);
        if (!path) { ALog(@"❌ tap：path 构造失败"); return NO; }

        long orient = AXInterfaceOrientation();
        SEL initRec = NSSelectorFromString(@"initWithName:interfaceOrientation:");
        id (*fp2)(id, SEL, id, long) = (id (*)(id, SEL, id, long))objc_msgSend;
        id rec = fp2([recCls alloc], initRec, @"AXAgent", orient);
        if (!rec) { ALog(@"❌ tap：record 构造失败"); return NO; }

        SEL addPath = NSSelectorFromString(@"addPointerEventPath:");
        void (*fp3)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
        fp3(rec, addPath, path);

        // completion 块绝不能捕获任何 ObjC 对象（__block 变量在函数返回后会失效，
        // XPC 回调再来时 objc_retain 野指针直接 SIGSEGV —— b35/b36 就是这个崩的）
        void (^completion)(id) = ^(id err) { /* 空，只为满足 ABI */ };
        SEL syn = NSSelectorFromString(@"synthesizeEvent:completion:");
        if (![gSession respondsToSelector:syn]) {
            ALog(@"❌ tap：daemonSession 无 synthesizeEvent:completion:");
            return NO;
        }
        void (*fp4)(id, SEL, id, id) = (void (*)(id, SEL, id, id))objc_msgSend;
        long long synT0 = AXSeqMs();
        fp4(gSession, syn, rec, completion);
        long long synMs = AXSeqMs() - synT0;
        /* 合成调用本身若很慢（>100ms），说明卡在 daemon 或 CPU 被采集循环占满 */
        if (synMs > 100) ALog(@"⏱ tap 合成耗时 %lldms（CPU 忙/daemon 慢）", synMs);
        else             ALog(@"  ✅ tap(%.1f, %.1f) 已提交（%lldms）", x, y, synMs);
        return YES;
    } @catch (NSException *e) {
        ALog(@"❌ tap 异常: %@ / %@", e.name, e.reason);
        return NO;
    }
}

/* 对外的 tap：给 10010 用，提交后等 0.1 秒让手势走完再回包 */
extern "C" BOOL AXAgentTap(double x, double y) {
    BOOL ok = AXTapCore(x, y);
    if (ok) [NSThread sleepForTimeInterval:0.1];
    return ok;
}

/// 在永不退出、且不 pop autorelease pool 的线程里跑 bootstrap：
/// XCTest 内部创建的 XPC 连接不会被释放，避免 _xpc_api_misuse 崩溃。
/* 正在 bootstrap 的标志：防止连点「重建会话」叠加多条常驻线程、反复覆盖 gSession */
static volatile int gStickyBusy = 0;

extern "C" BOOL AXAgentIsBootstrapping(void) {
    return gStickyBusy != 0;
}

extern "C" void AXAgentStartSticky(void) {
    /* ★ 原子占位：已经在建就忽略（返回 YES 表示"这次没建"由调用方提示） */
    if (__sync_lock_test_and_set(&gStickyBusy, 1)) {
        ALog(@"⏳ 会话正在建立中，忽略重复的 bootstrap 请求");
        return;
    }
    NSThread *t = [[NSThread alloc] initWithBlock:^{
        ALog(@"常驻线程启动，开始 bootstrap");
        AXAgentBootstrap();
        __sync_lock_release(&gStickyBusy);   /* 建完（无论成败）放开，允许失败后重试 */
        while (YES) { [NSThread sleepForTimeInterval:86400.0]; }
    }];
    t.name = @"AXAgent-Sticky";
    [t start];
}


#pragma mark - 5. 手势（swipe / longpress / 任意轨迹）

/// xy: [x0,y0, x1,y1, ...]  t: 每个点的时间偏移(秒)，最后一个点是 liftUp
/* 按 Home 键（用自动化会话里的 XCUIDevice.pressButton:），用于自己复现"退到后台" */
extern "C" BOOL AXAgentPressHome(void) {
    if (!gReady) { ALog(@"❌ pressHome: 会话未就绪"); return NO; }
    Class scrCls = NSClassFromString(@"XCUIScreen");
    if (!scrCls) return NO;
    id screen = ((id (*)(id, SEL))objc_msgSend)(scrCls, NSSelectorFromString(@"mainScreen"));
    if (!screen) return NO;
    id dev = ((id (*)(id, SEL))objc_msgSend)(screen, NSSelectorFromString(@"device"));
    if (!dev) { ALog(@"❌ pressHome: 无 device"); return NO; }
    SEL pb = NSSelectorFromString(@"pressButton:");
    if (![dev respondsToSelector:pb]) { ALog(@"❌ pressHome: 无 pressButton:"); return NO; }
    ((void (*)(id, SEL, long))objc_msgSend)(dev, pb, 1);   /* XCUIDeviceButtonHome = 1 */
    ALog(@"🏠 pressHome 已发送");
    return YES;
}

static BOOL AXGestureCore(const double *xy, const double *t, int n) {
    if (!gReady || !gSession) { ALog(@"❌ gesture 失败：会话未就绪"); return NO; }
    if (n < 2) { ALog(@"❌ gesture 失败：点数不足"); return NO; }
    @try {
        Class pathCls = NSClassFromString(@"XCPointerEventPath");
        Class recCls  = NSClassFromString(@"XCSynthesizedEventRecord");
        if (!pathCls || !recCls) { ALog(@"❌ gesture: 类不存在"); return NO; }

        SEL initPath = NSSelectorFromString(@"initForTouchAtPoint:offset:");
        id (*fpInit)(id, SEL, CGPoint, double) = (id (*)(id, SEL, CGPoint, double))objc_msgSend;
        id path = fpInit([pathCls alloc], initPath, CGPointMake(xy[0], xy[1]), t[0]);
        if (!path) { ALog(@"❌ gesture: path 构造失败"); return NO; }

        SEL mv = NSSelectorFromString(@"moveToPoint:atOffset:");
        void (*fpMv)(id, SEL, CGPoint, double) = (void (*)(id, SEL, CGPoint, double))objc_msgSend;
        SEL up = NSSelectorFromString(@"liftUpAtOffset:");
        void (*fpUp)(id, SEL, double) = (void (*)(id, SEL, double))objc_msgSend;

        for (int i = 1; i < n - 1; i++) {
            if ([path respondsToSelector:mv])
                fpMv(path, mv, CGPointMake(xy[i*2], xy[i*2+1]), t[i]);
        }
        if ([path respondsToSelector:up]) fpUp(path, up, t[n-1]);

        long orient = AXInterfaceOrientation();
        SEL initRec = NSSelectorFromString(@"initWithName:interfaceOrientation:");
        id (*fpRec)(id, SEL, id, long) = (id (*)(id, SEL, id, long))objc_msgSend;
        id rec = fpRec([recCls alloc], initRec, @"AXAgent", orient);
        if (!rec) { ALog(@"❌ gesture: record 构造失败"); return NO; }
        SEL addPath = NSSelectorFromString(@"addPointerEventPath:");
        ((void (*)(id, SEL, id))objc_msgSend)(rec, addPath, path);

        SEL syn = NSSelectorFromString(@"synthesizeEvent:completion:");
        if (![gSession respondsToSelector:syn]) { ALog(@"❌ gesture: 无 synthesizeEvent"); return NO; }
        void (^completion)(id) = ^(id err) { };
        ((void (*)(id, SEL, id, id))objc_msgSend)(gSession, syn, rec, completion);
        ALog(@"  ✅ gesture 已提交（%d 点，末点 %.2fs）", n, t[n-1]);
        return YES;
    } @catch (NSException *e) {
        ALog(@"❌ gesture 异常: %@ / %@", e.name, e.reason);
        return NO;
    }
}

/* 对外的 gesture：给 10010 用，提交后等 0.1 秒 */
extern "C" BOOL AXAgentGesture(const double *xy, const double *t, int n) {
    BOOL ok = AXGestureCore(xy, t, n);
    if (ok) [NSThread sleepForTimeInterval:0.1];
    return ok;
}

extern "C" BOOL AXAgentSwipe(double x1, double y1, double x2, double y2, double dur) {
    if (dur <= 0) dur = 0.25;
    double xy[4] = { x1, y1, x2, y2 };
    double t[2]  = { 0.0, dur };
    return AXAgentGesture(xy, t, 2);
}

extern "C" BOOL AXAgentLongPress(double x, double y, double dur) {
    if (dur <= 0) dur = 1.0;
    double xy[4] = { x, y, x, y };
    double t[2]  = { 0.0, dur };
    return AXAgentGesture(xy, t, 2);
}

#pragma mark - 5b. 双指缩放 / 键盘输入 / 剪贴板

/* 统一提交入口。completion 块绝不能捕获任何 ObjC 对象（函数返回后 __block 变量失效，
   XPC 回调再来会 objc_retain 野指针直接 SIGSEGV —— b35/b36 就是这么崩的）。 */
static BOOL AXSubmitEventRecord(id rec, double waitSec) {
    if (!gReady || !gSession || !rec) return NO;
    SEL syn = NSSelectorFromString(@"synthesizeEvent:completion:");
    if (![gSession respondsToSelector:syn]) {
        ALog(@"❌ daemonSession 无 synthesizeEvent:completion:");
        return NO;
    }
    void (^completion)(id) = ^(id err) { };
    ((void (*)(id, SEL, id, id))objc_msgSend)(gSession, syn, rec, completion);
    if (waitSec > 0) [NSThread sleepForTimeInterval:waitSec];
    return YES;
}

static id AXNewEventRecord(void) {
    Class recCls = NSClassFromString(@"XCSynthesizedEventRecord");
    if (!recCls) return nil;
    SEL initRec = NSSelectorFromString(@"initWithName:interfaceOrientation:");
    id (*fp)(id, SEL, id, long) = (id (*)(id, SEL, id, long))objc_msgSend;
    return fp([recCls alloc], initRec, @"AXAgent", AXInterfaceOrientation());
}

/* 双指缩放：以 (cx,cy) 为中心，两指间距从 startGap 变到 endGap（点）。
   startGap<endGap = 放大；startGap>endGap = 缩小。
   实现：同一个 XCSynthesizedEventRecord 里挂两条 XCPointerEventPath，各代表一根手指，
   同步移动 —— 这是 XCTest 合成多点触控的唯一入口（XCUIElement.pinch 需要有元素，我们没有）。 */
extern "C" BOOL AXAgentPinch(double cx, double cy, double startGap, double endGap, double dur) {
    if (!gReady || !gSession) { ALog(@"❌ pinch 失败：会话未就绪"); return NO; }
    if (startGap <= 0) startGap = 200;
    if (endGap   <= 0) endGap   = 200;
    if (dur      <= 0) dur      = 0.35;
    @try {
        Class pathCls = NSClassFromString(@"XCPointerEventPath");
        id rec = AXNewEventRecord();
        if (!pathCls || !rec) { ALog(@"❌ pinch: 类/record 构造失败"); return NO; }

        SEL initPath = NSSelectorFromString(@"initForTouchAtPoint:offset:");
        SEL mv       = NSSelectorFromString(@"moveToPoint:atOffset:");
        SEL up       = NSSelectorFromString(@"liftUpAtOffset:");
        SEL addPath  = NSSelectorFromString(@"addPointerEventPath:");

        for (int side = -1; side <= 1; side += 2) {
            CGPoint p0 = CGPointMake(cx + side * startGap / 2.0, cy);
            CGPoint p1 = CGPointMake(cx + side * endGap   / 2.0, cy);
            id path = ((id (*)(id, SEL, CGPoint, double))objc_msgSend)(
                          [pathCls alloc], initPath, p0, 0.0);
            if (!path) { ALog(@"❌ pinch: path 构造失败"); return NO; }
            ((void (*)(id, SEL, CGPoint, double))objc_msgSend)(path, mv, p1, dur);
            ((void (*)(id, SEL, double))objc_msgSend)(path, up, dur);
            ((void (*)(id, SEL, id))objc_msgSend)(rec, addPath, path);
        }

        BOOL ok = AXSubmitEventRecord(rec, dur + 0.15);
        ALog(@"  ✅ pinch(%.0f,%.0f) %.0f→%.0f ok=%d", cx, cy, startGap, endGap, ok);
        return ok;
    } @catch (NSException *e) {
        ALog(@"❌ pinch 异常: %@ / %@", e.name, e.reason);
        return NO;
    }
}

/* 文本输入：XCPointerEventPath initForTextInput + typeText:atOffset:typingSpeed:shouldRedact:
   （反汇编确认签名 v44@0:8@16d24Q32B40）
   ★ ASCII 稳；CJK 建议走 paste（HID 注入对非键盘字符不可靠）。 */
extern "C" BOOL AXAgentTypeText(NSString *text) {
    if (!gReady || !gSession) { ALog(@"❌ text 失败：会话未就绪"); return NO; }
    if (text.length == 0) return NO;
    @try {
        Class pathCls = NSClassFromString(@"XCPointerEventPath");
        id rec = AXNewEventRecord();
        if (!pathCls || !rec) { ALog(@"❌ text: 类/record 构造失败"); return NO; }

        id path = ((id (*)(id, SEL))objc_msgSend)([pathCls alloc],
                                                  NSSelectorFromString(@"initForTextInput"));
        if (!path) { ALog(@"❌ text: initForTextInput 返回 nil"); return NO; }

        SEL tt = NSSelectorFromString(@"typeText:atOffset:typingSpeed:shouldRedact:");
        if (![path respondsToSelector:tt]) { ALog(@"❌ text: 无 typeText: 方法"); return NO; }
        ((void (*)(id, SEL, id, double, unsigned long, BOOL))objc_msgSend)(
            path, tt, text, 0.0, (unsigned long)0, NO);

        ((void (*)(id, SEL, id))objc_msgSend)(rec,
            NSSelectorFromString(@"addPointerEventPath:"), path);

        BOOL ok = AXSubmitEventRecord(rec, 0.15 + MIN(2.0, text.length * 0.02));
        ALog(@"  ⌨️ 文本输入 %lu 字 ok=%d", (unsigned long)text.length, ok);
        return ok;
    } @catch (NSException *e) {
        ALog(@"❌ text 异常: %@ / %@", e.name, e.reason);
        return NO;
    }
}

/* 单键 / 组合键：typeKey:modifiers:atOffset:（签名 v40@0:8@16Q24d32）
   key 传字符串（如 "v"、@"\r" 回车）；mods 用 UIKeyModifierFlags：
     Shift=1<<17  Control=1<<18  Option=1<<19  Cmd=1<<20 */
extern "C" BOOL AXAgentKey(NSString *key, unsigned long mods) {
    if (!gReady || !gSession) { ALog(@"❌ key 失败：会话未就绪"); return NO; }
    if (key.length == 0) return NO;
    @try {
        Class pathCls = NSClassFromString(@"XCPointerEventPath");
        id rec = AXNewEventRecord();
        if (!pathCls || !rec) return NO;

        id path = ((id (*)(id, SEL))objc_msgSend)([pathCls alloc],
                                                  NSSelectorFromString(@"initForTextInput"));
        if (!path) return NO;

        SEL tk = NSSelectorFromString(@"typeKey:modifiers:atOffset:");
        if (![path respondsToSelector:tk]) { ALog(@"❌ key: 无 typeKey: 方法"); return NO; }
        ((void (*)(id, SEL, id, unsigned long, double))objc_msgSend)(path, tk, key, mods, 0.0);

        ((void (*)(id, SEL, id))objc_msgSend)(rec,
            NSSelectorFromString(@"addPointerEventPath:"), path);

        BOOL ok = AXSubmitEventRecord(rec, 0.2);
        ALog(@"  ⌨️ 按键 %@ mods=0x%lx ok=%d", key, mods, ok);
        return ok;
    } @catch (NSException *e) {
        ALog(@"❌ key 异常: %@ / %@", e.name, e.reason);
        return NO;
    }
}

/* 粘贴：把文本写进系统剪贴板，再发 Cmd+V。
   CJK 只能走这条（HID 逐键打不出中文）。
   ★ iOS 16+ 目标 App 首次读剪贴板会弹「允许粘贴」，不点允许就粘不上 —— 系统行为，绕不过。 */
extern "C" BOOL AXAgentPaste(NSString *text) {
    if (text) [UIPasteboard generalPasteboard].string = text;
    BOOL ok = AXAgentKey(@"v", (1UL << 20));
    ALog(@"  📋 粘贴 %lu 字（已写剪贴板 + Cmd+V）ok=%d", (unsigned long)text.length, ok);
    return ok;
}

/* 读系统剪贴板（手机 → PC 的"复制"） */
extern "C" NSString *AXAgentPasteboardGet(void) {
    NSString *v = [UIPasteboard generalPasteboard].string ?: @"";
    return v;
}

/* 只写剪贴板，不发按键（PC 端要自己控制粘贴时机时用） */
extern "C" BOOL AXAgentPasteboardSet(NSString *text) {
    if (!text) return NO;
    [UIPasteboard generalPasteboard].string = text;
    return YES;
}

#pragma mark - 5c. 流式触控实验（分段提交 vs 整段提交）

/* 把一次拖动切成若干段分别 synthesizeEvent，用来验证 XCTest 是否支持
   「跨 record 保持手指按下」：
     mode 0 = 整段一条 record 一次提交（现在的正式做法，作为对照）
     mode 1 = 分段提交：首段 beginsPersistentState、末段 endsPersistentState，
              中间每段从上一位置 move 到新位置
   两次都从 (x1,y1) 拖到 (x2,y2)，steps 段，段间停顿 gapMs。
   返回一段摘要（每段耗时），同时打日志 —— 判断依据就看"手指有没有真的跟着走"。 */
/* 本文件后面的 AXNowMs 定义在流那一段，这里先用一个本地计时器（单调时钟） */
static long long AXSeqMs(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* 把一次拖动切成若干段分别 synthesizeEvent，用来验证 XCTest 是否支持
   「跨 record 保持手指按下」：
     mode 0 = 整段一条 record 一次提交（现在的正式做法，作为对照）
     mode 1 = 分段提交：首段 beginsPersistentState、末段 endsPersistentState，
              中间每段从上一位置 move 到新位置
   两次都从 (x1,y1) 拖到 (x2,y2)，steps 段，段间停顿 gapMs。
   返回值带每段耗时 —— 判断依据就看"手指有没有真的跟着走"。 */
extern "C" NSString *AXAgentTouchSeq(int mode, double x1, double y1, double x2, double y2,
                                     int steps, int gapMs) {
    if (!gReady || !gSession) return @"not ready";
    if (steps < 2)  steps = 10;
    if (steps > 60) steps = 60;
    if (gapMs < 0)  gapMs = 0;

    Class pathCls = NSClassFromString(@"XCPointerEventPath");
    Class recCls  = NSClassFromString(@"XCSynthesizedEventRecord");
    if (!pathCls || !recCls) return @"no class";

    SEL initPath = NSSelectorFromString(@"initForTouchAtPoint:offset:");
    SEL mv       = NSSelectorFromString(@"moveToPoint:atOffset:");
    SEL up       = NSSelectorFromString(@"liftUpAtOffset:");
    SEL addPath  = NSSelectorFromString(@"addPointerEventPath:");
    SEL initRec  = NSSelectorFromString(@"initWithName:interfaceOrientation:");

    long long t0 = AXSeqMs();

    if (mode == 0) {
        double dur = steps * 0.02;
        id rec = ((id (*)(id, SEL, id, long))objc_msgSend)([recCls alloc], initRec,
                                                           @"AXSeqWhole", AXInterfaceOrientation());
        if (!rec) return @"no record";
        id path = ((id (*)(id, SEL, CGPoint, double))objc_msgSend)(
                      [pathCls alloc], initPath, CGPointMake(x1, y1), 0.0);
        if (!path) return @"no path";
        for (int i = 1; i <= steps; i++) {
            double k = (double)i / (double)steps;
            ((void (*)(id, SEL, CGPoint, double))objc_msgSend)(path, mv,
                CGPointMake(x1 + (x2 - x1) * k, y1 + (y2 - y1) * k), dur * k);
        }
        ((void (*)(id, SEL, double))objc_msgSend)(path, up, dur);
        ((void (*)(id, SEL, id))objc_msgSend)(rec, addPath, path);
        BOOL ok = AXSubmitEventRecord(rec, dur + 0.1);
        long long el = AXSeqMs() - t0;
        ALog(@"🧪 [seq] mode=0 整段提交 steps=%d ok=%d %lldms", steps, ok, el);
        return [NSString stringWithFormat:@"mode=0 ok=%d %lldms", ok, el];
    }

    /* mode 1：分段 + persistent state */
    NSMutableString *spent = [NSMutableString string];
    double px = x1, py = y1;
    BOOL anyFail = NO;

    for (int i = 0; i <= steps && !anyFail; i++) {
        @autoreleasepool {
            double k = (double)i / (double)steps;
            CGPoint p = CGPointMake(x1 + (x2 - x1) * k, y1 + (y2 - y1) * k);
            BOOL first = (i == 0);
            BOOL last  = (i == steps);

            id rec = ((id (*)(id, SEL, id, long))objc_msgSend)([recCls alloc], initRec,
                                                               @"AXSeqSeg", AXInterfaceOrientation());
            if (!rec) {
                anyFail = YES;
            } else {
                /* KVC：类上确实有 setBeginsPersistentState: / setEndsPersistentState: */
                if (first) [rec setValue:@YES forKey:@"beginsPersistentState"];
                if (last)  [rec setValue:@YES forKey:@"endsPersistentState"];

                id path = ((id (*)(id, SEL, CGPoint, double))objc_msgSend)(
                              [pathCls alloc], initPath, CGPointMake(px, py), 0.0);
                if (!path) {
                    anyFail = YES;
                } else {
                    if (!first) {
                        ((void (*)(id, SEL, CGPoint, double))objc_msgSend)(path, mv, p, 0.0);
                    }
                    if (last) {
                        ((void (*)(id, SEL, double))objc_msgSend)(path, up, 0.0);
                    }
                    ((void (*)(id, SEL, id))objc_msgSend)(rec, addPath, path);

                    long long s0 = AXSeqMs();
                    if (!AXSubmitEventRecord(rec, 0)) anyFail = YES;
                    [spent appendFormat:@"%lld,", AXSeqMs() - s0];
                }
            }
            px = p.x; py = p.y;
            if (gapMs > 0) usleep((useconds_t)(gapMs * 1000));
        }
    }

    long long el = AXSeqMs() - t0;
    ALog(@"🧪 [seq] mode=1 分段提交 %d 段 gap=%dms fail=%d 总%lldms 每段[%@]",
         steps + 1, gapMs, anyFail, el, spent);
    return [NSString stringWithFormat:@"mode=1 segs=%d fail=%d %lldms [%@]",
            steps + 1, anyFail, el, spent];
}

#pragma mark - 6. 截图（JPEG + 缩放，返回 base64）

static BOOL gShotProbed = NO;

extern "C" NSString *AXAgentShot(double maxSide, double quality) {
    if (!gReady) { ALog(@"❌ shot 失败：会话未就绪"); return nil; }
    @autoreleasepool {
        Class scrCls = NSClassFromString(@"XCUIScreen");
        if (!scrCls) { ALog(@"❌ shot: XCUIScreen 不存在（DDI 未挂载？）"); return nil; }

        id screen = nil;
        SEL ms = NSSelectorFromString(@"mainScreen");
        if ([scrCls respondsToSelector:ms]) screen = ((id (*)(id, SEL))objc_msgSend)(scrCls, ms);
        if (!screen) { ALog(@"❌ shot: mainScreen 为 nil"); return nil; }

        SEL ss = NSSelectorFromString(@"screenshot");
        if (![screen respondsToSelector:ss]) { ALog(@"❌ shot: 无 screenshot 方法"); return nil; }

        /* ===== 段1：截图请求（XCUIScreen → XCUIScreenshot 对象） ===== */
        CFTimeInterval t0 = CACurrentMediaTime();
        id shot = ((id (*)(id, SEL))objc_msgSend)(screen, ss);
        CFTimeInterval t1 = CACurrentMediaTime();
        if (!shot) { ALog(@"❌ shot: screenshot 返回 nil"); return nil; }

        /* 首次调用：把 shot 对象的家底摊开，并单独计时几个可能更快的取图方式 */
        if (!gShotProbed) {
            gShotProbed = YES;
            ALog(@"  🔍 [shot 探测] screenshot 返回类 = %@", NSStringFromClass([shot class]));
            AXDumpClass(NSStringFromClass([shot class]));

            SEL sp = NSSelectorFromString(@"pngRepresentation");
            if ([shot respondsToSelector:sp]) {
                CFTimeInterval p0 = CACurrentMediaTime();
                id png = ((id (*)(id, SEL))objc_msgSend)(shot, sp);
                CFTimeInterval p1 = CACurrentMediaTime();
                NSUInteger n = [png isKindOfClass:[NSData class]] ? [(NSData *)png length] : 0;
                ALog(@"  🔍 [shot 探测] pngRepresentation → %@  %.1fKB  %.0fms",
                     png ? NSStringFromClass([png class]) : @"nil",
                     n / 1024.0, (p1 - p0) * 1000.0);
            } else {
                ALog(@"  🔍 [shot 探测] 无 pngRepresentation");
            }

            SEL cg = NSSelectorFromString(@"CGImage");
            if ([shot respondsToSelector:cg]) {
                CFTimeInterval p0 = CACurrentMediaTime();
                id g = ((id (*)(id, SEL))objc_msgSend)(shot, cg);
                CFTimeInterval p1 = CACurrentMediaTime();
                ALog(@"  🔍 [shot 探测] CGImage → %@  %.0fms", g ? @"ok" : @"nil", (p1 - p0) * 1000.0);
            } else {
                ALog(@"  🔍 [shot 探测] 无 CGImage");
            }
        }

        /* ===== 段2：解成 UIImage ===== */
        CFTimeInterval t2a = CACurrentMediaTime();
        SEL im = NSSelectorFromString(@"image");
        id img = [shot respondsToSelector:im] ? ((id (*)(id, SEL))objc_msgSend)(shot, im) : nil;
        CFTimeInterval t2b = CACurrentMediaTime();
        if (!img) { ALog(@"❌ shot: image 为 nil"); return nil; }

        /* ===== 段3：缩放 ===== */
        UIImage *ui = (UIImage *)img;
        CGSize sz = ui.size;
        CGFloat longSide = MAX(sz.width, sz.height);
        UIImage *out = ui;
        CFTimeInterval t3a = CACurrentMediaTime();
        if (maxSide > 0 && longSide > maxSide) {
            CGFloat k = maxSide / longSide;
            CGSize ns = CGSizeMake(round(sz.width * k), round(sz.height * k));
            UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
            fmt.scale = 1.0;            // 关键：否则按屏幕 3 倍渲染，像素数 ×9、编码变慢 5 倍
            fmt.opaque = YES;
            UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:ns format:fmt];
            out = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
                [ui drawInRect:CGRectMake(0, 0, ns.width, ns.height)];
            }];
        }
        CFTimeInterval t3b = CACurrentMediaTime();

        /* ===== 段4：JPEG 编码 ===== */
        if (quality <= 0) quality = 0.6;
        NSData *jpeg = UIImageJPEGRepresentation(out, quality);
        CFTimeInterval t4 = CACurrentMediaTime();
        if (!jpeg) { ALog(@"❌ shot: JPEG 编码失败"); return nil; }

        ALog(@"  📷 shot %.0fx%.0f -> %.0fx%.0f %luKB | 请求%.0f 解码%.0f 缩放%.0f 编码%.0f ms",
             sz.width, sz.height, out.size.width, out.size.height,
             (unsigned long)(jpeg.length / 1024),
             (t1 - t0) * 1000.0, (t2b - t2a) * 1000.0,
             (t3b - t3a) * 1000.0, (t4 - t3b) * 1000.0);
        return [jpeg base64EncodedStringWithOptions:0];
    }
}


#pragma mark - 7. 录屏流探针（runtime dump + 试调私有 API）

static void AXDumpClass(NSString *name) {
    Class cls = NSClassFromString(name);
    if (!cls) { ALog(@"  [dump] %@ → 不存在", name); return; }
    ALog(@"  [dump] %@", name);

    unsigned int n = 0;
    Method *ms = class_copyMethodList(cls, &n);
    NSMutableString *sb = [NSMutableString string];
    for (unsigned i = 0; i < n; i++) {
        [sb appendFormat:@"%@ |", NSStringFromSelector(method_getName(ms[i]))];
        if (sb.length > 900) break;
    }
    free(ms);
    ALog(@"     方法(%u): %@", n, sb.length ? sb : @"(无)");

    /* ★ b44：类方法（metaclass）单独 dump —— sharedClient 这类工厂方法全在这里，
       只看实例方法会误判"类里没有 sharedClient" */
    Class meta = object_getClass(cls);
    unsigned int mn = 0;
    Method *mms = class_copyMethodList(meta, &mn);
    NSMutableString *sm = [NSMutableString string];
    for (unsigned i = 0; i < mn; i++) {
        [sm appendFormat:@"+%@ |", NSStringFromSelector(method_getName(mms[i]))];
        if (sm.length > 700) break;
    }
    free(mms);
    ALog(@"     类方法(%u): %@", mn, sm.length ? sm : @"(无)");

    unsigned int ivn = 0;
    Ivar *iv = class_copyIvarList(cls, &ivn);
    NSMutableString *s2 = [NSMutableString string];
    for (unsigned i = 0; i < ivn; i++) {
        const char *nm = ivar_getName(iv[i]);
        const char *tp = ivar_getTypeEncoding(iv[i]);
        [s2 appendFormat:@"%s(%s) |", nm ? nm : "?", tp ? tp : "?"];
        if (s2.length > 600) break;
    }
    free(iv);
    ALog(@"     成员(%u): %@", ivn, s2.length ? s2 : @"(无)");
}

extern "C" NSString *AXAgentProbeRecording(void) {
    ALog(@"===== 录屏流探针开始 =====");
    if (!gReady || !gSession) { ALog(@"❌ 会话未就绪"); return @"not ready"; }

    SEL sSupp = NSSelectorFromString(@"supportsScreenRecording");
    SEL sActive = NSSelectorFromString(@"isScreenRecordingActive");
    SEL sPref = NSSelectorFromString(@"preferScreenshotsOverScreenRecording");
    ALog(@"会话 respondsToSelector:");
    ALog(@"   supportsScreenRecording            = %d", (int)[gSession respondsToSelector:sSupp]);
    ALog(@"   isScreenRecordingActive            = %d", (int)[gSession respondsToSelector:sActive]);
    ALog(@"   preferScreenshotsOverScreenRecording = %d", (int)[gSession respondsToSelector:sPref]);

    if ([gSession respondsToSelector:sSupp]) {
        @try {
            BOOL b = ((BOOL (*)(id, SEL))objc_msgSend)(gSession, sSupp);
            ALog(@"   supportsScreenRecording 返回值 = %d", (int)b);
        } @catch (NSException *e) { ALog(@"   调用异常: %@", e.reason); }
    }
    if ([gSession respondsToSelector:sActive]) {
        @try {
            BOOL b = ((BOOL (*)(id, SEL))objc_msgSend)(gSession, sActive);
            ALog(@"   isScreenRecordingActive 返回值 = %d", (int)b);
        } @catch (NSException *e) { ALog(@"   调用异常: %@", e.reason); }
    }

    ALog(@"--- 类结构 ---");
    AXDumpClass(@"XCTScreenRecordingRequest");
    AXDumpClass(@"XCTAttachmentFuture");
    AXDumpClass(@"XCUILocalDeviceScreenRecordingIPCInterface");
    AXDumpClass(@"XCUILocalDeviceScreenDataSource");

    // 试构造 request
    Class reqCls = NSClassFromString(@"XCTScreenRecordingRequest");
    id req = nil;
    if (reqCls) {
        @try {
            req = [[reqCls alloc] init];
            ALog(@"✅ [[XCTScreenRecordingRequest alloc] init] = %p", (__bridge void *)req);
            // 打印所有可读属性值
            unsigned int pn = 0;
            objc_property_t *props = class_copyPropertyList(reqCls, &pn);
            for (unsigned i = 0; i < pn; i++) {
                const char *nm = property_getName(props[i]);
                @try {
                    id v = [req valueForKey:[NSString stringWithUTF8String:nm]];
                    ALog(@"     属性 %s = %@", nm, v);
                } @catch (NSException *e) { ALog(@"     属性 %s → %@", nm, e.reason); }
            }
            free(props);
        } @catch (NSException *e) {
            ALog(@"❌ request init 异常: %@ / %@", e.name, e.reason);
        }
    }

    // 真调一次
    SEL start = NSSelectorFromString(@"startScreenRecordingWithRequest:withReply:");
    ALog(@"startScreenRecordingWithRequest:withReply: 存在 = %d", (int)[gSession respondsToSelector:start]);
    if (req && [gSession respondsToSelector:start]) {
        @try {
            void (^reply)(id, id) = ^(id future, id err) {
                ALog(@"  📥 录屏 reply: future=%@(%@)  err=%@",
                     future ? NSStringFromClass([future class]) : @"nil",
                     future ?: @"",
                     err ?: @"nil");
                if (future) {
                    AXDumpClass(NSStringFromClass([future class]));
                    @try {
                        if ([future respondsToSelector:NSSelectorFromString(@"isFulfilled")]) {
                            BOOL f = ((BOOL (*)(id, SEL))objc_msgSend)(future, NSSelectorFromString(@"isFulfilled"));
                            ALog(@"     future.isFulfilled = %d", (int)f);
                        }
                    } @catch (NSException *e) { ALog(@"     future 探测异常: %@", e.reason); }
                }
            };
            void (*fp)(id, SEL, id, id) = (void (*)(id, SEL, id, id))objc_msgSend;
            fp(gSession, start, req, reply);
            ALog(@"✅ 已发起 startScreenRecording（等 3 秒看回调）");
            [NSThread sleepForTimeInterval:3.0];
        } @catch (NSException *e) {
            ALog(@"❌ startScreenRecording 异常: %@ / %@", e.name, e.reason);
        }
    }
    ALog(@"===== 录屏流探针结束 =====");
    return @"probe done";
}

#pragma mark - 节点树（AX 元素树读取）

/* 对任意 AX 元素取属性：优先 attributeValueForKey:，退回 valueForKey: */
static id AXNodeAttr(id elem, NSString *key) {
    if (!elem) return nil;
    SEL s1 = NSSelectorFromString(@"attributeValueForKey:");
    if ([elem respondsToSelector:s1]) {
        @try {
            id (*fp)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
            id v = fp(elem, s1, key);
            if (v) return v;
        } @catch (NSException *e) { }
    }
    SEL s2 = NSSelectorFromString(@"valueForKey:");
    if ([elem respondsToSelector:s2]) {
        @try {
            id (*fp)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
            return fp(elem, s2, key);
        } @catch (NSException *e) { }
    }
    return nil;
}

static NSString *AXShort(id v) {
    if (!v) return @"-";
    if ([v isKindOfClass:[NSString class]]) {
        NSString *s = (NSString *)v;
        if (s.length == 0) return @"\"\"";
        if (s.length > 60) s = [[s substringToIndex:60] stringByAppendingString:@"…"];
        return s;
    }
    if ([v isKindOfClass:[NSNumber class]]) return [v description];
    if ([v isKindOfClass:[NSArray class]])
        return [NSString stringWithFormat:@"<array %lu>", (unsigned long)[(NSArray *)v count]];
    return NSStringFromClass([v class]);
}

static void AXDumpNode(id elem, int depth, int *count, int maxNodes) {
    if (!elem || *count >= maxNodes || depth > 8) return;
    (*count)++;

    NSString *label = AXShort(AXNodeAttr(elem, @"label"));
    NSString *ident = AXShort(AXNodeAttr(elem, @"identifier"));
    NSString *value = AXShort(AXNodeAttr(elem, @"value"));
    NSString *type  = AXShort(AXNodeAttr(elem, @"elementType"));

    NSMutableString *pad = [NSMutableString string];
    for (int i = 0; i < depth; i++) [pad appendString:@"  "];
    ALog(@"%@· %@ type=%@ label=%@ id=%@ val=%@",
         pad, NSStringFromClass([elem class]), type, label, ident, value);

    id kids = AXNodeAttr(elem, @"children");
    if (![kids isKindOfClass:[NSArray class]]) return;
    for (id k in (NSArray *)kids) {
        if (*count >= maxNodes) break;
        AXDumpNode(k, depth + 1, count, maxNodes);
    }
}

/* ★ 探测设备标识：XCUIScreen.device（XCUIDevice）的 uniqueIdentifier。
   mirror_stream 那套私有 IOKit 我们用不了，但自动化会话里的 XCUIDevice 可能
   曝光了设备标识 —— 有它就不需要 PC 端经 10010 传 UDID 了。 */
/* ★ MobileGestalt 试探：普通签名大概率 NULL，但一次构建能验证全部 key */
extern "C" NSString *AXTryMobileGestalt(void) {
    ALogShim(@"===== MobileGestalt 试探 =====");
    void *h = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_NOW);
    if (!h) { ALogShim(@"  ❌ libMobileGestalt 打不开: %s", dlerror()); return @"no lib"; }
    typedef CFTypeRef (*MGFn)(CFStringRef);
    MGFn fn = (MGFn)dlsym(h, "MGCopyAnswer");
    if (!fn) { ALogShim(@"  ❌ 无 MGCopyAnswer"); return @"no fn"; }

    NSString *keys[] = { @"UniqueDeviceID", @"UniqueDeviceIDData", @"SerialNumber",
                         @"ProductType", @"ModelNumber", @"MobileEquipmentIdentifier",
                         @"InternationalMobileSubscriberIdentity", @"DeviceName",
                         @"ProductVersion", @"BuildVersion", @"CPUArchitecture" };
    int nk = (int)(sizeof(keys) / sizeof(keys[0]));
    NSString *found = nil;
    for (int ki = 0; ki < nk; ki++) {
        NSString *k = keys[ki];
        @try {
            CFTypeRef v = fn((__bridge CFStringRef)k);
            NSString *desc = @"(NULL)";
            if (v) {
                if (CFGetTypeID(v) == CFStringGetTypeID()) desc = [(__bridge NSString *)v copy];
                else if (CFGetTypeID(v) == CFDataGetTypeID()) desc = [NSString stringWithFormat:@"<data %lu>", (unsigned long)CFDataGetLength((CFDataRef)v)];
                else desc = NSStringFromClass([(__bridge id)v class]);
            }
            ALogShim(@"  · %@ → %@", k, desc);
            if (v && found == nil && [k isEqualToString:@"UniqueDeviceID"] && desc.length > 5) found = desc;
            if (v && CFGetTypeID(v)) CFRelease(v);
        } @catch (NSException *e) { ALogShim(@"  · %@ 异常: %@", k, e.reason); }
    }
    return found ?: @"gestalt-no-udid";
}

extern "C" NSString *AXProbeDeviceInfo(void) {
    ALogShim(@"===== 设备标识探测 =====");
    ALogShim(@"--- 0) MobileGestalt ---");
    NSString *g = AXTryMobileGestalt();
    if (g && ![g hasPrefix:@"gestalt-"] && ![g hasPrefix:@"no "]) {
        ALogShim(@"✅ MobileGestalt 给出了 UDID，直接采用");
        AXStreamSetUDID(g);
        return g;
    }
    if (!gReady) { ALogShim(@"❌ 会话未就绪"); return @"not ready"; }

    Class scrCls = NSClassFromString(@"XCUIScreen");
    if (!scrCls) return @"no XCUIScreen";
    id screen = ((id (*)(id, SEL))objc_msgSend)(scrCls, NSSelectorFromString(@"mainScreen"));
    if (!screen) return @"no screen";

    /* 1) XCUIScreen.device */
    SEL devSel = NSSelectorFromString(@"device");
    id dev = nil;
    if ([screen respondsToSelector:devSel]) {
        dev = ((id (*)(id, SEL))objc_msgSend)(screen, devSel);
        ALogShim(@"  · screen.device → %@ (%s)", dev ? @"有" : @"nil",
                 dev ? object_getClassName(dev) : "-");
    } else {
        ALogShim(@"  · screen 无 device 属性");
    }

    /* 2) XCUIDevice sharedDevice 路线 */
    Class devCls = NSClassFromString(@"XCUIDevice");
    id sd = dev;
    if (!sd && devCls) {
        sd = AXShared(devCls, @[@"sharedDevice", @"localDevice"]);
    }
    if (!sd) { ALogShim(@"❌ 拿不到 XCUIDevice 实例"); return @"no device"; }

    /* 3) uniqueIdentifier */
    SEL uidSel = NSSelectorFromString(@"uniqueIdentifier");
    if ([sd respondsToSelector:uidSel]) {
        @try {
            id v = ((id (*)(id, SEL))objc_msgSend)(sd, uidSel);
            ALogShim(@"  ✅ uniqueIdentifier = %@", v);
            if ([v isKindOfClass:[NSString class]] && ((NSString *)v).length > 0) {
                AXStreamSetUDID(v);
                ALogShim(@"  ✅ 已同步给 AXStream（preamble 将使用该标识）");
                return v;
            }
        } @catch (NSException *e) { ALogShim(@"  ❌ uniqueIdentifier 异常: %@", e.reason); }
    } else {
        ALogShim(@"  · uniqueIdentifier 不存在");
    }

    /* 4) 顺带 dump 这个类，看还有没有别的标识接口 */
    AXDumpClass(@"XCUIDevice");
    return @"no uid";
}

/* 路线 B：直接用 XCUIApplication 拿 accessibilityElement（不走 XCAXClient_iOS） */
static id AXElementViaXCUIApplication(void) {
    Class appCls = NSClassFromString(@"XCUIApplication");
    if (!appCls) { ALog(@"  · XCUIApplication 不存在"); return nil; }

    SEL sAlloc = NSSelectorFromString(@"alloc");
    SEL sInitBid = NSSelectorFromString(@"initWithBundleIdentifier:");
    SEL sInit = NSSelectorFromString(@"init");
    SEL sAccEl = NSSelectorFromString(@"accessibilityElement");

    /* B1: initWithBundleIdentifier: */
    if ([appCls instancesRespondToSelector:sInitBid]) {
        for (NSString *bid in @[@"com.apple.springboard"]) {
            @try {
                id obj = ((id (*)(id, SEL))objc_msgSend)(appCls, sAlloc);
                id app = ((id (*)(id, SEL, id))objc_msgSend)(obj, sInitBid, bid);
                ALog(@"  · XCUIApplication(%@) = %@", bid, app ? @"ok" : @"nil");
                if (!app) continue;
                ALog(@"     respondsToSelector(accessibilityElement) = %d",
                     (int)[app respondsToSelector:sAccEl]);
                if ([app respondsToSelector:sAccEl]) {
                    id el = ((id (*)(id, SEL))objc_msgSend)(app, sAccEl);
                    ALog(@"     accessibilityElement → %@",
                         el ? NSStringFromClass([el class]) : @"nil");
                    if (el) return el;
                }
            } @catch (NSException *e) {
                ALog(@"  · XCUIApplication(%@) 异常: %@ / %@", bid, e.name, e.reason);
            }
        }
    } else {
        ALog(@"  · XCUIApplication 无 initWithBundleIdentifier:");
    }

    /* B2: 无参 init（用测试配置里的 target） */
    if ([appCls instancesRespondToSelector:sInit]) {
        @try {
            id obj = ((id (*)(id, SEL))objc_msgSend)(appCls, sAlloc);
            id app = ((id (*)(id, SEL))objc_msgSend)(obj, sInit);
            ALog(@"  · XCUIApplication() = %@", app ? @"ok" : @"nil");
            if (app && [app respondsToSelector:sAccEl]) {
                id el = ((id (*)(id, SEL))objc_msgSend)(app, sAccEl);
                ALog(@"     accessibilityElement → %@",
                     el ? NSStringFromClass([el class]) : @"nil");
                if (el) return el;
            }
        } @catch (NSException *e) {
            ALog(@"  · XCUIApplication() 异常: %@ / %@", e.name, e.reason);
        }
    }
    return nil;
}

#pragma mark - 路线 C：AXRuntime + AXUIElement（照 AScript 的做法）

/* AScript 二进制里的做法（反编译所得）：
     dlopen "/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime"
     dlsym  AXUIElementCreateSystemWide / AXUIElementGetPid / AXUIElementCopyAttributeValue
     读 AXFocusedApplication → 递归 AXChildren，属性名用 "AXRole"/"AXTitle"/"AXValue"
   它在普通签名下就能跑（二进制里没有 platform-application 等特权 entitlements），
   所以这条路不依赖 UI test bundle，也不依赖 DDI。 */

typedef void *(*AXCreateSystemWideFn)(void);
typedef void *(*AXCreateAppFn)(pid_t pid);
typedef int (*AXCopyAttrFn)(void *elem, CFStringRef attr, CFTypeRef *out);
typedef int (*AXGetPidFn)(void *elem, pid_t *pid);

static void *AXFindSymbol(const char *name) {
    void *p = dlsym(RTLD_DEFAULT, name);
    if (p) return p;
    static const char *fws[] = {
        "/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime",
        "/System/Developer/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime",
        "/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities",
        NULL
    };
    for (int i = 0; fws[i]; i++) {
        void *h = dlopen(fws[i], RTLD_NOW | RTLD_GLOBAL);
        if (!h) continue;
        p = dlsym(h, name);
        if (p) return p;
    }
    return NULL;
}

/* 读一个 AX 属性并转成可打印字符串（只处理 String/Number，其它返回类名） */
static NSString *AXAttrToStr(void *elem, AXCopyAttrFn copyAttr, NSString *key) {
    if (!elem || !copyAttr) return nil;
    CFTypeRef v = NULL;
    int err = copyAttr(elem, (__bridge CFStringRef)key, &v);
    if (err != 0 || !v) return nil;
    NSString *s = nil;
    CFTypeID t = CFGetTypeID(v);
    if (t == CFStringGetTypeID()) {
        s = [(__bridge NSString *)v copy];
    } else if (t == CFNumberGetTypeID()) {
        s = [(__bridge NSNumber *)v description];
    } else if (t == CFBooleanGetTypeID()) {
        s = [(__bridge NSNumber *)v boolValue] ? @"true" : @"false";
    } else if (t == CFArrayGetTypeID()) {
        s = [NSString stringWithFormat:@"<array %ld>", (long)CFArrayGetCount((CFArrayRef)v)];
    }
    CFRelease(v);
    if (s && s.length > 60) s = [[s substringToIndex:60] stringByAppendingString:@"…"];
    return s;
}

static void AXDumpAXNode(void *node, int depth, int *count, int maxNodes,
                         AXCopyAttrFn copyAttr, AXGetPidFn getPid) {
    if (!node || *count >= maxNodes || depth > 10) return;
    (*count)++;

    NSString *role   = AXAttrToStr(node, copyAttr, @"AXRole");
    NSString *title  = AXAttrToStr(node, copyAttr, @"AXTitle");
    NSString *label  = AXAttrToStr(node, copyAttr, @"AXLabel");
    NSString *value  = AXAttrToStr(node, copyAttr, @"AXIdentifier");
    NSString *val    = AXAttrToStr(node, copyAttr, @"AXValue");
    pid_t p = -1;
    if (getPid) { @try { getPid(node, &p); } @catch (NSException *e) { } }

    NSMutableString *pad = [NSMutableString string];
    for (int i = 0; i < depth; i++) [pad appendString:@"  "];
    ALog(@"%@· %@ pid=%d role=%@ title=%@ label=%@ id=%@ val=%@",
         pad, role ?: @"?", (int)p, role ?: @"-", title ?: @"-", label ?: @"-",
         value ?: @"-", val ?: @"-");

    CFTypeRef kids = NULL;
    int err = copyAttr(node, CFSTR("AXChildren"), &kids);
    if (err == 0 && kids && CFGetTypeID(kids) == CFArrayGetTypeID()) {
        CFArrayRef arr = (CFArrayRef)kids;
        CFIndex n = CFArrayGetCount(arr);
        for (CFIndex i = 0; i < n; i++) {
            if (*count >= maxNodes) break;
            void *ch = (void *)CFArrayGetValueAtIndex(arr, i);
            AXDumpAXNode(ch, depth + 1, count, maxNodes, copyAttr, getPid);
        }
    }
    if (kids) CFRelease(kids);
}

/* 打印某个方法完整的 type encoding —— 决定能不能安全调用它 */
static const char *AXMethodTypes(Class cls, NSString *selName, char *buf, size_t buflen) {
    if (!cls) return NULL;
    Method m = class_getInstanceMethod(cls, NSSelectorFromString(selName));
    if (!m) return NULL;
    const char *t = method_getTypeEncoding(m);
    if (!t) return NULL;
    snprintf(buf, buflen, "%s", t);
    return buf;
}

/* 解析返回值 + 第一个参数的类型字符（跳过 self/_cmd 和偏移数字） */
static void AXParseTypes(const char *types, char *ret, size_t rl, char *arg1, size_t al) {
    ret[0] = 0; arg1[0] = 0;
    if (!types) return;
    const char *p = types;
    size_t i = 0;
    while (*p && *p != ':' && i + 1 < rl) ret[i++] = *p++;
    ret[i] = 0;
    /* 找到第二个 ':' 之后 */
    const char *c = strchr(types, ':');
    if (!c) return;
    c++;
    while (*c && (isdigit((unsigned char)*c) || *c == '+' || *c == '-')) c++;
    c = strchr(c, ':');
    if (!c) return;
    c++;
    while (*c && isdigit((unsigned char)*c)) c++;
    i = 0;
    while (*c && i + 1 < al) arg1[i++] = *c++;
    arg1[i] = 0;
}

/* 尝试调用 XCAXClient_iOS 的 loadAccessibility:（AScript 里出现 8 次的那个）
   ★ 参数类型不明确时只记录、不调用 —— 传错 block 会 SIGSEGV，@try 接不住 */
static BOOL AXTryLoadAccessibility(id client) {
    if (!client) return NO;
    BOOL any = NO;
    NSArray<NSString *> *sels = @[@"loadAccessibility:", @"_loadAccessibility:"];
    for (NSString *name in sels) {
        SEL s = NSSelectorFromString(name);
        if (![client respondsToSelector:s]) { ALog(@"  · %@ 不存在", name); continue; }

        char tb[128]; char ret[32]; char arg[32];
        const char *t = AXMethodTypes([client class], name, tb, sizeof(tb));
        if (!t) { ALog(@"  · %@ 无 type encoding", name); continue; }
        AXParseTypes(t, ret, sizeof(ret), arg, sizeof(arg));
        ALog(@"  · %@ types=%s  返回=%s  参数1=%s", name, t, ret, arg);

        /* 指针参数（NSError**）→ 传 NULL，安全 */
        if (arg[0] == '^') {
            @try {
                ((void (*)(id, SEL, void *))objc_msgSend)(client, s, NULL);
                ALog(@"  ✅ %@(NULL) 调用完成", name);
                any = YES;
            } @catch (NSException *e) { ALog(@"  ❌ %@ 异常: %@", name, e.reason); }
        } else if (arg[0] == 'd' || arg[0] == 'f') {
            @try {
                ((void (*)(id, SEL, double))objc_msgSend)(client, s, 3.0);
                ALog(@"  ✅ %@(3.0) 调用完成", name);
                any = YES;
            } @catch (NSException *e) { ALog(@"  ❌ %@ 异常: %@", name, e.reason); }
        } else {
            ALog(@"  ⚠️ %@ 参数是 '%s'（可能是 block），本版不调用，避免崩溃", name, arg);
        }
    }
    return any;
}

/* 返回读到的节点数（-1 = 失败）；每一步的 AXError 都打进日志（err=0 才是成功） */
static int AXRootViaAXRuntime(int maxNodes) {
    AXCreateSystemWideFn createSW = (AXCreateSystemWideFn)AXFindSymbol("AXUIElementCreateSystemWide");
    AXCopyAttrFn copyAttr = (AXCopyAttrFn)AXFindSymbol("AXUIElementCopyAttributeValue");
    AXGetPidFn getPid = (AXGetPidFn)AXFindSymbol("AXUIElementGetPid");

    ALog(@"  · dlsym: CreateSystemWide=%p CopyAttributeValue=%p GetPid=%p",
         (void *)createSW, (void *)copyAttr, (void *)getPid);
    if (!createSW || !copyAttr) { ALog(@"  · ❌ AXRuntime 符号拿不到"); return -1; }

    /* ★ 先开 AX 开关：建 XCAXClient_iOS 实例并调 loadAccessibility:
       （AScript 二进制里 loadAccessibility 出现 8 次，我们之前一次都没调 —— 这大概率是
         kAXErrorAPIDisabled(-25211) 的根源） */
    Class axCls2 = NSClassFromString(@"XCAXClient_iOS");
    if (axCls2) {
        id client2 = nil;
        @try {
            id obj = ((id (*)(id, SEL))objc_msgSend)(axCls2, NSSelectorFromString(@"alloc"));
            SEL ini = NSSelectorFromString(@"init");
            if ([obj respondsToSelector:ini])
                client2 = ((id (*)(id, SEL))objc_msgSend)(obj, ini);
        } @catch (NSException *e) { ALog(@"  · client init 异常: %@", e.reason); }
        ALog(@"  · XCAXClient_iOS 实例 = %p", (__bridge void *)client2);
        AXTryLoadAccessibility(client2);
    }

    void *sys = createSW();
    ALog(@"  · AXUIElementCreateSystemWide → %p", sys);
    if (!sys) return -1;

    /* 依次试几个入口属性（AScript 里这三个名字都出现过）
       ★ CFSTR() 只接受字符串字面量，变量名必须走 (__bridge CFStringRef) */
    NSArray<NSString *> *attrs = @[@"AXFocusedApplication",
                                   @"AXFrontmostApplication",
                                   @"AXFocusedUIElement"];
    void *root = NULL;
    for (NSString *a in attrs) {
        CFTypeRef v = NULL;
        int err = copyAttr(sys, (__bridge CFStringRef)a, &v);
        ALog(@"  · %@ → err=%d val=%p", a, err, v);
        if (err == 0 && v && !root) {
            root = (void *)v;      /* 持有，稍后释放 */
        } else if (v) {
            CFRelease(v);
        }
    }
    CFRelease(sys);

    /* 自测：AXUIElementCreateApplication(自己) —— 如果连自己都 -25211，说明 AX 全局 disabled；
       如果自己能读、只有 SystemWide 不行，那是跨进程权限问题，方向不同 */
    if (!root) {
        AXCreateAppFn createApp = (AXCreateAppFn)AXFindSymbol("AXUIElementCreateApplication");
        ALog(@"  · dlsym CreateApplication=%p", (void *)createApp);
        if (createApp) {
            void *me = createApp((pid_t)getpid());
            ALog(@"  · CreateApplication(self pid=%d) → %p", (int)getpid(), me);
            if (me) {
                CFTypeRef v = NULL;
                int e2 = copyAttr(me, CFSTR("AXRole"), &v);
                ALog(@"  · self AXRole → err=%d val=%p", e2, v);
                if (v) CFRelease(v);
                CFTypeRef k2 = NULL;
                int e3 = copyAttr(me, CFSTR("AXChildren"), &k2);
                ALog(@"  · self AXChildren → err=%d", e3);
                if (k2) CFRelease(k2);
                CFRelease(me);
            }
        }
    }

    if (!root) return -1;

    int count = 0;
    AXDumpAXNode(root, 0, &count, maxNodes, copyAttr, getPid);
    ALog(@"  ✅ AX 树读到 %d 个节点", count);
    CFRelease(root);
    return count;
}

/* 动态调整 _XCTSetApplicationStateTimeout（截图 101ms 疑似被 100ms 超时吃掉） */
extern "C" BOOL AXAgentSetAppStateTimeout(double v) {
    void (*fn)(double) = (void (*)(double))AXFindSymbol("_XCTSetApplicationStateTimeout");
    if (!fn) { ALog(@"❌ 找不到 _XCTSetApplicationStateTimeout"); return NO; }
    @try {
        fn(v);
        ALog(@"✅ _XCTSetApplicationStateTimeout(%.3f)", v);
        return YES;
    } @catch (NSException *e) {
        ALog(@"❌ 设置异常: %@", e.reason);
        return NO;
    }
}

#pragma mark - 底层截图（绕过 XCUIScreen 的三层包装，直接打 IPC）

/* 反汇编得到的调用链：
     -[XCUIScreen screenshot]
       → screenshotWithEncoding:options:
         → screenshotWithPreferredEncoding:rect:options:error:   (futureWithTimeout 包装)
           → XCUILocalDeviceScreenDataSource requestScreenshotWithRequest:withReply:
             → screenshotIPCInterface requestScreenshotWithRequest:withReply:   ← 真正的 101ms
   这里直接构造 XCTScreenshotRequest 丢给 screenshotIPCInterface，跳过三层包装，
   并把 IPC 对象的真实类名/方法表 dump 出来（之前按名字猜一直是错的）。 */
extern "C" NSString *AXAgentShotLowLevel(int mode, double quality) {
    if (!gReady) return @"not ready";
    @autoreleasepool {
        Class scrCls = NSClassFromString(@"XCUIScreen");
        if (!scrCls) return @"no XCUIScreen";
        id screen = ((id (*)(id, SEL))objc_msgSend)(scrCls, NSSelectorFromString(@"mainScreen"));
        if (!screen) return @"no screen";

        SEL sdSel = NSSelectorFromString(@"screenDataSource");
        if (![screen respondsToSelector:sdSel]) return @"no screenDataSource";
        id ds = ((id (*)(id, SEL))objc_msgSend)(screen, sdSel);
        if (!ds) return @"nil datasource";

        SEL ipcSel = NSSelectorFromString(@"screenshotIPCInterface");
        if (![ds respondsToSelector:ipcSel]) return @"no screenshotIPCInterface";
        id ipc = ((id (*)(id, SEL))objc_msgSend)(ds, ipcSel);
        if (!ipc) return @"nil ipc";

        /* ★ 真实类名（之前按 "XCUILocalDeviceScreenshotIPCInterface" 猜一直是错的） */
        const char *ipcCls = object_getClassName(ipc);
        static BOOL shot2Dumped = NO;
        if (!shot2Dumped) {
            shot2Dumped = YES;
            ALog(@"  🔬 [shot2] datasource 类 = %s", object_getClassName(ds));
            ALog(@"  🔬 [shot2] ipc 类 = %s", ipcCls);
            AXDumpClass(@(ipcCls));
        }

        /* legacy 标志只是读一下，看当前值 */
        SEL legSel = NSSelectorFromString(@"useLegacyScreenshotPath");
        if ([ipc respondsToSelector:legSel]) {
            BOOL b = ((BOOL (*)(id, SEL))objc_msgSend)(ipc, legSel);
            ALog(@"  🔬 [shot2] useLegacyScreenshotPath = %d", (int)b);
        } else {
            ALog(@"  🔬 [shot2] 无 useLegacyScreenshotPath");
        }

        /* 构造 XCTScreenshotRequest */
        Class reqCls = NSClassFromString(@"XCTScreenshotRequest");
        if (!reqCls) { ALog(@"  ❌ 无 XCTScreenshotRequest"); return @"no request class"; }

        Class qCls = NSClassFromString(@"XCTImageQuality");
        id q = nil;
        if (qCls) {
            id qa = ((id (*)(id, SEL))objc_msgSend)(qCls, NSSelectorFromString(@"alloc"));
            SEL qi = NSSelectorFromString(@"initWithImageQuality:");
            if ([qa respondsToSelector:qi]) q = ((id (*)(id, SEL, double))objc_msgSend)(qa, qi, quality);
        }
        if (!q) { ALog(@"  ⚠️ 没有 XCTImageQuality，用 nil"); }

        /* ★ IPC 层不认 CGRectNull / CGRectZero —— 必须给真实矩形，否则
           daemon 直接回 "Empty screenshot requested."（反汇编里 datasource 会把 rect
           原样重建丢给 IPC，null 就变成空请求）。
           mode: 0 = 整屏(点) 1 = 半屏(点) 2 = 整屏(像素) */
        CGSize pts = [UIScreen mainScreen].bounds.size;
        CGFloat sc = [UIScreen mainScreen].scale;
        CGRect rect;
        if (mode == 1)      rect = CGRectMake(0, 0, pts.width * 0.5, pts.height * 0.5);
        else if (mode == 2) rect = CGRectMake(0, 0, pts.width * sc, pts.height * sc);
        else                rect = CGRectMake(0, 0, pts.width, pts.height);
        ALog(@"  🔬 [shot2] rect = %.0f,%.0f %.0fx%.0f (mode=%d)", rect.origin.x, rect.origin.y,
             rect.size.width, rect.size.height, mode);

        /* screenID 用真实 displayID，硬传 0 也可能被判空 */
        long long sid = 0;
        SEL dSel = NSSelectorFromString(@"displayID");
        if ([screen respondsToSelector:dSel]) {
            sid = ((long long (*)(id, SEL))objc_msgSend)(screen, dSel);
        }
        ALog(@"  🔬 [shot2] screenID = %lld", sid);

        SEL ri = NSSelectorFromString(@"initWithScreenID:rect:encoding:options:");
        if (![reqCls instancesRespondToSelector:ri]) { ALog(@"  ❌ 无 initWithScreenID:rect:encoding:options:"); return @"no init"; }
        id reqObj = ((id (*)(id, SEL))objc_msgSend)(reqCls, NSSelectorFromString(@"alloc"));
        typedef id (*InitReqFn)(id, SEL, long long, CGRect, id, unsigned long);
        id req = ((InitReqFn)objc_msgSend)(reqObj, ri, sid, rect, q, 0UL);
        if (!req) { ALog(@"  ❌ request 构造失败"); return @"req nil"; }

        SEL callSel = NSSelectorFromString(@"requestScreenshotWithRequest:withReply:");
        if (![ipc respondsToSelector:callSel]) { ALog(@"  ❌ ipc 无 requestScreenshotWithRequest:withReply:"); return @"no call"; }

        __block id gotValue = nil;
        __block id gotErr = nil;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);

        CFTimeInterval t0 = CACurrentMediaTime();
        void (^reply)(id, id) = ^(id v, id e) {
            gotValue = v;
            gotErr = e;
            dispatch_semaphore_signal(sem);
        };
        @try {
            ((void (*)(id, SEL, id, id))objc_msgSend)(ipc, callSel, req, reply);
        } @catch (NSException *ex) {
            ALog(@"  ❌ 调用异常: %@", ex.reason);
            return @"call threw";
        }
        long waited = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)));
        CFTimeInterval dt = (CACurrentMediaTime() - t0) * 1000.0;
        if (waited != 0) { ALog(@"  ⏱ [shot2] 5s 超时，无回调"); return @"timeout"; }

        ALog(@"  ⏱ [shot2] IPC 往返 %.0fms", dt);
        if (gotErr) ALog(@"  ⚠️ [shot2] err = %@", gotErr);
        if (!gotValue) { ALog(@"  ❌ [shot2] 返回 nil"); return @"nil image"; }

        ALog(@"  🔬 [shot2] 返回值类 = %s", object_getClassName(gotValue));
        /* 返回的可能是 XCTImage（有 data 方法）也可能是 UIImage */
        NSData *jpeg = nil;
        CFTimeInterval t1 = CACurrentMediaTime();
        if ([gotValue respondsToSelector:NSSelectorFromString(@"data")]) {
            id d = ((id (*)(id, SEL))objc_msgSend)(gotValue, NSSelectorFromString(@"data"));
            if ([d isKindOfClass:[NSData class]]) {
                NSData *raw = (NSData *)d;
                ALog(@"  🔬 [shot2] data 长度 = %lu 字节", (unsigned long)raw.length);
                UIImage *ui = [UIImage imageWithData:raw];
                if (ui) {
                    CGSize sz = ui.size;
                    CGFloat k = 720.0 / MAX(sz.width, sz.height);
                    if (k > 1.0) k = 1.0;
                    CGSize ns = CGSizeMake(round(sz.width * k), round(sz.height * k));
                    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
                    fmt.scale = 1.0; fmt.opaque = YES;
                    UIImage *out = ui;
                    if (k < 1.0) {
                        UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:ns format:fmt];
                        CGFloat kk = k;
                        out = [r imageWithActions:^(UIGraphicsImageRendererContext *c) {
                            [ui drawInRect:CGRectMake(0, 0, ns.width, ns.height)];
                            (void)kk;
                        }];
                    }
                    jpeg = UIImageJPEGRepresentation(out, quality > 0 ? quality : 0.6);
                    ALog(@"  📷 [shot2] %.0fx%.0f -> %.0fx%.0f  %luKB  (后处理 %.0fms)",
                         sz.width, sz.height, out.size.width, out.size.height,
                         (unsigned long)(jpeg.length / 1024), (CACurrentMediaTime() - t1) * 1000.0);
                }
            }
        }
        if (!jpeg) { ALog(@"  ⚠️ [shot2] 拿不到可编码数据"); return @"no data"; }
        return [jpeg base64EncodedStringWithOptions:0];
    }
}

/* 读当前可达的 AX 元素树。maxNodes 限制节点数（防止界面复杂时刷爆日志）。
   返回摘要字符串；详细内容写 agent.log。 */
extern "C" NSString *AXAgentDumpTree(int maxNodes) {
    if (maxNodes <= 0) maxNodes = 120;
    ALog(@"===== 节点树读取开始（max=%d）=====", maxNodes);
    if (!gReady) { ALog(@"❌ 会话未就绪"); return @"not ready"; }

    /* 无论成败都先把类结构摊开，方法名就是下次要用的线索 */
    ALog(@"--- 类结构 ---");
    AXDumpClass(@"XCAXClient_iOS");
    AXDumpClass(@"XCUIApplication");
    AXDumpClass(@"XCUIRemoteAccessibilityInterface");
    AXDumpClass(@"XCUIApplicationProcessTracker");
    AXDumpClass(@"XCAccessibilityElement");

    /* ===== 路线 C 优先：AXRuntime + AXUIElement（AScript 的做法）===== */
    ALog(@"--- 路线 C: AXRuntime + AXUIElement ---");
    int axNodes = AXRootViaAXRuntime(maxNodes);
    if (axNodes >= 0) {
        ALog(@"===== 节点树结束（AXRuntime 路线，%d 个节点）=====", axNodes);
        return [NSString stringWithFormat:@"nodes=%d", axNodes];
    }
    ALog(@"  · 路线 C 失败，继续试 A/B");

    id root = nil;

    /* 路线 A：XCAXClient_iOS 单例 / 手工 init */
    Class axCls = NSClassFromString(@"XCAXClient_iOS");
    if (axCls) {
        id client = AXShared(axCls, @[@"sharedClient", @"defaultClient",
                                      @"currentClient", @"client"]);
        if (!client) {
            @try {
                id obj = ((id (*)(id, SEL))objc_msgSend)(axCls, NSSelectorFromString(@"alloc"));
                SEL ini = NSSelectorFromString(@"init");
                if ([obj respondsToSelector:ini]) {
                    id c2 = ((id (*)(id, SEL))objc_msgSend)(obj, ini);
                    ALog(@"  · XCAXClient_iOS alloc/init → %@",
                         c2 ? NSStringFromClass([c2 class]) : @"nil");
                    client = c2;
                }
            } @catch (NSException *e) {
                ALog(@"  · XCAXClient_iOS alloc/init 异常: %@ / %@", e.name, e.reason);
            }
        }
        if (client) {
            for (NSString *n in @[@"focusedApplication", @"frontmostApplication",
                                  @"systemWideElement", @"applicationElement"]) {
                SEL s = NSSelectorFromString(n);
                if (![client respondsToSelector:s]) { ALog(@"  · %@ 不存在", n); continue; }
                @try {
                    id r = ((id (*)(id, SEL))objc_msgSend)(client, s);
                    ALog(@"  · %@ → %@", n, r ? NSStringFromClass([r class]) : @"nil");
                    if (r && !root) root = r;
                } @catch (NSException *e) { ALog(@"  · %@ 异常: %@", n, e.reason); }
            }
            if (!root) {
                SEL sp = NSSelectorFromString(@"accessibilityElementForPid:");
                if ([client respondsToSelector:sp]) {
                    @try {
                        id r = ((id (*)(id, SEL, int))objc_msgSend)(client, sp, (int)getpid());
                        ALog(@"  · accessibilityElementForPid(%d) → %@", (int)getpid(),
                             r ? NSStringFromClass([r class]) : @"nil");
                        if (r) root = r;
                    } @catch (NSException *e) { ALog(@"  · pid 版异常: %@", e.reason); }
                }
            }
        }
    }

    /* 路线 B：XCUIApplication（XCAXClient_iOS 拿不到时的备用通道） */
    if (!root) {
        ALog(@"--- 路线 B: XCUIApplication ---");
        root = AXElementViaXCUIApplication();
    }

    if (!root) { ALog(@"❌ 两条路线都没拿到根元素"); return @"no element"; }

    int count = 0;
    AXDumpNode(root, 0, &count, maxNodes);
    ALog(@"===== 节点树结束：共 %d 个节点 =====", count);
    return [NSString stringWithFormat:@"nodes=%d", count];
}

#pragma mark - AXStream 实现（原 AXStream.mm 并入，绕开 XcodeGen 收录问题）

/* ---------------- 全局状态 ---------------- */
static int              g_listenFd = -1;
static volatile BOOL    g_running = NO;
static pthread_t        g_acceptTid;
static pthread_t        g_encTid;
static pthread_mutex_t  g_clientMu = PTHREAD_MUTEX_INITIALIZER;
static int              g_clients[4] = {-1, -1, -1, -1};

/* 采集方案（提前声明：编码循环里要读它） */
static volatile int g_scheme = 0;       /* 0=XCUITest(截图)  1=ReplayKit */
static volatile int g_rkFrames = 0;
static volatile int g_rkFallback = 0;   /* 1=ReplayKit 拿不到帧，已自动回退 */
static volatile int g_profileCapture = 0;  /* 档位期望的采集方式（Start 时生效） */
static void AXReplayKitStopInternal(void);
static volatile int     g_clientCount = 0;

static VTCompressionSessionRef g_vt = NULL;
static int              g_encW = 0, g_encH = 0;
static int              g_bitrate = 2000000;   /* 2 Mbps */
static int              g_fps = 20;
static int              g_maxSide = 720;

static volatile long long g_ptsMs = 0;         /* 真实墙钟毫秒，严格单调 */
static volatile BOOL    g_needConfig = YES;    /* 首帧 / 编码器重建后要发 SPS/PPS */
static volatile double g_imgQuality = 0.70;   /* 截图压缩质量（0~1） */
static volatile int    g_decodeThumb = 0;     /* 0=全解+CGContext(默认)  1=ImageIO thumbnail */
static volatile int    g_inputKick   = 0;     /* 有触控输入 → 让编码循环立刻出一帧 */
static volatile int    g_staticDrop  = 1;     /* 1=静止画面自动降帧（默认开）；测试时可关 */
static char           g_imgUTI[64] = "public.jpeg";  /* 截图编码格式：public.jpeg / public.png */
static volatile long long g_lastImgBytes = 0; /* 上帧 IPC 返回的图片字节数 */
static volatile long long g_lastDecMs = 0;    /* 上帧解码耗时（心跳里打出来） */
static volatile long long g_lastDrawMs = 0;   /* 上帧转 CVPixelBuffer + 缩放耗时 */
static volatile int     g_force_key = 0;       /* ★ 新连接 → 强制下一帧 IDR（照 mirror_stream v46：
                                                  PC 解码器必须从 IDR 起步，否则永远黑屏） */
static volatile int     g_sentFrames = 0;
static volatile int     g_lastErr = 0;
static NSString         *g_lastErrMsg = nil;
static volatile int     g_preambleSent = 0;
static char             g_udid[128] = {0};   /* ★ 真 UDID：PC 端靠它把 27184 的流
                                                  关联到 usbmux 里的真设备（b54） */

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
        ssize_t n = send(fd, p + off, len - off, MSG_NOSIGNAL);
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

    /* UDID：★ 必须发真 UDID（PC 端把 27184 的流关联到 usbmux 里的真机）。
       普通 App 拿不到，由 PC 端经 10010 的 {"cmd":"udid"} 传进来；
       没传过才退回 identifierForVendor（此时 PC 端会出现一台重复设备）。 */
    NSString *udid = (g_udid[0] ? @(g_udid)
                    : [[[UIDevice currentDevice] identifierForVendor] UUIDString] ?: @"axtouch");
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
    /* ★ VT 回调跑在自己的线程，没有 autorelease pool：每帧创建的 NSMutableData/
       NSDictionary 会一直堆着不释放（120 帧后闪退的原因之一） */
    @autoreleasepool {

    /* ★ 照 mirror_stream.m 的逻辑：把 SPS/PPS（type 7/8）拆出来存 cfg，其余 NAL 拼 au；
       关键帧时先发 CONFIG 再发 au —— PC 端把 CONFIG 缓存并拼到每帧前。
       新连接后 g_force_key 强制 IDR + 立即发 CONFIG，PC 无需等待周期关键帧。 */
    NSMutableData *cfg = [NSMutableData data];
    NSMutableData *au = [NSMutableData data];
    BOOL isKey = NO;
    BOOL haveParams = NO;

    {
        CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sbuf);
        size_t cnt = 0;
        if (fmt && CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, 0, NULL, NULL, &cnt, NULL) == noErr && cnt > 0) {
            haveParams = YES;
            for (size_t i = 0; i < cnt; i++) {
                const uint8_t *ps = NULL;
                size_t psLen = 0;
                if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, i, &ps, &psLen, NULL, NULL) == noErr && ps && psLen) {
                    uint8_t sc[4] = {0, 0, 0, 1};
                    [cfg appendBytes:sc length:4];
                    [cfg appendBytes:ps length:psLen];
                }
            }
        }
    }

    /* 取 NAL（VT 输出已是 Annex-B，带起始码） */
    CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sbuf);
    if (!bb) return;
    size_t len = CMBlockBufferGetDataLength(bb);
    if (len == 0) return;

    NSMutableData *raw = [NSMutableData dataWithLength:len];
    if (CMBlockBufferCopyDataBytes(bb, 0, len, raw.mutableBytes) != kCMBlockBufferNoErr) return;

    /* ★ VT 输出的是 AVCC（每 NAL 前 4B 长度前缀），PC 端要 Annex-B（00 00 00 01）。
       不转的话 PC 的 hasAnnexBStartCode 一检查就丢帧 → 黑屏。 */
    NSMutableData *nal = [NSMutableData dataWithCapacity:len + 32];
    {
        const uint8_t *p = (const uint8_t *)raw.bytes;
        size_t total = raw.length, off = 0;
        while (off + 4 <= total) {
            uint32_t n = ((uint32_t)p[off] << 24) | ((uint32_t)p[off + 1] << 16)
                       | ((uint32_t)p[off + 2] << 8) | (uint32_t)p[off + 3];
            off += 4;
            if (n == 0 || off + n > total) break;
            uint8_t sc[4] = {0, 0, 0, 1};
            [au appendBytes:sc length:4];
            [au appendBytes:p + off length:n];
            uint8_t nt = (uint8_t)(p[off] & 0x1F);
            if (nt == 7 || nt == 8) {            /* SPS / PPS */
                [cfg appendBytes:sc length:4];
                [cfg appendBytes:p + off length:n];
            }
            if (nt == 5) isKey = YES;            /* IDR */
            off += n;
        }
    }
    if (au.length == 0) return;
    if (g_needConfig && haveParams) {
        [au replaceBytesInRange:NSMakeRange(0, 0) withBytes:cfg.bytes length:cfg.length];  /* 头部插入 */
        g_needConfig = NO;
    }

    /* 关键帧判断：NAL 里有 IDR 就算（跟 ios-daemon 一致，不依赖 NotSync 附件） */
    CFArrayRef atts = CMSampleBufferGetSampleAttachmentsArray(sbuf, false);
    if (atts && CFArrayGetCount(atts) > 0) {
        NSDictionary *d = (__bridge NSDictionary *)CFArrayGetValueAtIndex(atts, 0);
        if (d && [d objectForKey:(__bridge id)kCMSampleAttachmentKey_NotSync]
            && [(NSNumber *)[d objectForKey:(__bridge id)kCMSampleAttachmentKey_NotSync] boolValue])
            isKey = isKey;                       /* NotSync=1 时以 NAL 扫描结果为准 */
    }

    uint64_t ptsUs = (uint64_t)(AXNextPts() * 1000);              /* ★ 微秒（与安卓一致） */
    uint64_t flags = isKey ? ((uint64_t)1 << 61) : 0;
    if (isKey && cfg.length > 0) {
        AXSendPacket((uint64_t)1 << 62, cfg.bytes, cfg.length);   /* ★ 关键帧前先发 CONFIG */
        ALogShim(@"📺 关键帧，已发 CONFIG %lu 字节", (unsigned long)cfg.length);
    }
    uint64_t ptsAndFlags = (ptsUs & ~((uint64_t)1 << 63 | (uint64_t)1 << 62 | (uint64_t)1 << 61)) | flags;
    AXSendPacket(ptsAndFlags, au.bytes, au.length);
    g_sentFrames++;
    }   /* @autoreleasepool */
}

static OSType g_vtFmt = 0;      /* 当前 VT 会话的源像素格式 */
static long long g_vtDropAt = 0; /* 上次丢弃会话的时间（诊断用） */

/* 丢弃当前会话：下次 AXVTEnsureWithFormat 会重建。
   ★ 必须同时清 preamble 标记：新会话的 SPS/PPS 变了，客户端要重新收一遍。 */
static void AXVTDrop(const char *why) {
    if (g_vt) {
        VTCompressionSessionCompleteFrames(g_vt, kCMTimeInvalid);
        VTCompressionSessionInvalidate(g_vt);
        CFRelease(g_vt);
        g_vt = NULL;
    }
    g_vtFmt = 0;
    /* ★★ 2026-10-31 崩溃根因（PC 端闪退）：
       以前这里把 g_preambleSent 清零 → 下一帧会对**已连接的客户端再发一遍 preamble**。
       PC 的包解析器按 12B 包头读，preamble 的字节被当成包头 → 解出荒谬宽高
       （实测 0x201fb3c2 × 0x40000000）→ image.NewRGBA 分配 1GB → makeslice panic 闪退。
       preamble 是**连接级**的（只在 accept 时发一次），重建编码会话只需要重发 SPS/PPS：
       g_needConfig=YES 会让下一个关键帧前自动补 CONFIG，这就够了。
       g_encW/g_encH 也保留：新客户端连进来时 accept 那侧还要用它发 preamble。 */
    g_needConfig = YES;
    ALogShim(@"♻️ 编码会话已丢弃（%s），下一帧重建（不重发 preamble，只补 SPS/PPS）", why ? why : "?");
}

/* 按指定源像素格式建会话：XCUITest 路径喂 BGRA，ReplayKit 路径喂它自己给的 420f/420v。
   格式不匹配 VT 会直接拒绝编码，所以必须跟着首帧格式走。 */
static BOOL AXVTEnsureWithFormat(int w, int h, OSType fmt) {
    if (fmt == 0) fmt = kCVPixelFormatType_32BGRA;
    if (g_vt && g_encW == w && g_encH == h && g_vtFmt == fmt) return YES;
    if (g_vt) {
        VTCompressionSessionCompleteFrames(g_vt, kCMTimeInvalid);
        VTCompressionSessionInvalidate(g_vt);
        CFRelease(g_vt);
        g_vt = NULL;
    }
    NSDictionary *srcAttrs = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(fmt),
        (NSString *)kCVPixelBufferWidthKey: @(w),
        (NSString *)kCVPixelBufferHeightKey: @(h),
    };
    OSStatus st = VTCompressionSessionCreate(NULL, (int32_t)w, (int32_t)h,
                                             kCMVideoCodecType_H264, NULL,
                                             (__bridge CFDictionaryRef)srcAttrs,
                                             NULL, AXVTCompressionCallback, NULL, &g_vt);
    if (st != noErr || !g_vt) {
        AXSetErr((int)st, [NSString stringWithFormat:@"VTCompressionSessionCreate 失败 st=%d", (int)st]);
        ALogShim(@"❌ VT 创建失败 st=%d w=%d h=%d fmt=%u", (int)st, w, h, (unsigned)fmt);
        return NO;
    }
    VTSessionSetProperty(g_vt, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(g_vt, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel);
    VTSessionSetProperty(g_vt, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    VTSessionSetProperty(g_vt, kVTCompressionPropertyKey_MaxKeyFrameInterval, (__bridge CFNumberRef)@(g_fps * 10));
    VTSessionSetProperty(g_vt, kVTCompressionPropertyKey_ExpectedFrameRate, (__bridge CFNumberRef)@(g_fps));
    VTSessionSetProperty(g_vt, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFNumberRef)@(g_bitrate));
    VTCompressionSessionPrepareToEncodeFrames(g_vt);

    g_encW = w; g_encH = h; g_vtFmt = fmt;
    g_needConfig = YES;
    g_ptsMs = 0;
    ALogShim(@"✅ VT 会话建立 %dx%d fmt=%u vt=%p", w, h, (unsigned)fmt, (void *)g_vt);
    ALogShim(@"✅ VT 编码器就绪 %dx%d fmt=%u  %d kbps  %d fps", w, h, (unsigned)fmt,
             g_bitrate / 1000, g_fps);
    return YES;
}

static BOOL AXVTEnsure(int w, int h) {
    return AXVTEnsureWithFormat(w, h, kCVPixelFormatType_32BGRA);
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

    /* 编码参数：优先自己造 XCTImageEncoding 指定「UTI + 压缩质量」——
       这样能明确要 JPEG（XCTAutomationSupport 里就有 public.jpeg），
       而不是靠 XCTImageQuality 猜 daemon 会给什么格式。
       JPEG 支持 DCT 缩放解码（边解边缩），PNG 必须先解满再缩。 */
    id q = nil;
    Class encCls = NSClassFromString(@"XCTImageEncoding");
    SEL encInit = NSSelectorFromString(@"initWithUniformTypeIdentifier:compressionQuality:");
    if (encCls && [encCls instancesRespondToSelector:encInit]) {
        NSString *uti = @(g_imgUTI);
        if (uti.length == 0) uti = @"public.jpeg";
        double qq = g_imgQuality;
        if (qq <= 0) qq = 0.7;
        if (qq > 1.0) qq = 1.0;
        q = ((id (*)(id, SEL, id, double))objc_msgSend)([encCls alloc], encInit, uti, qq);
        ALogShim(@"🖼 用 XCTImageEncoding：%@  q=%.2f", uti, qq);
    }
    if (!q && qCls) {
        id qa = ((id (*)(id, SEL))objc_msgSend)(qCls, NSSelectorFromString(@"alloc"));
        SEL qi = NSSelectorFromString(@"initWithImageQuality:");
        if ([qa respondsToSelector:qi]) q = ((id (*)(id, SEL, double))objc_msgSend)(qa, qi, g_imgQuality);
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

    /* ★ 一次性确认 IPC 给的是什么编码（决定解码路径能不能优化）：
       JPEG 支持 DCT 缩放解码（可以"边解边缩"），PNG 必须先解满再缩。
       同时把大小打出来 —— 真视频内容下 PNG 会膨胀几倍，IPC 耗时会直接翻倍。 */
    {
        static int fmtLogged = 0;
        if (!fmtLogged && result.length > 8) {
            fmtLogged = 1;
            const uint8_t *p = (const uint8_t *)result.bytes;
            const char *fmt = "unknown";
            if (p[0] == 0xFF && p[1] == 0xD8) fmt = "JPEG";
            else if (p[0] == 0x89 && p[1] == 0x50) fmt = "PNG";
            else if (p[0] == 0x42 && p[1] == 0x4D) fmt = "BMP";
            ALogShim(@"🔍 IPC 截图格式=%s  %lu 字节  head=%02X%02X%02X%02X  imgQuality=%.2f",
                     fmt, (unsigned long)result.length, p[0], p[1], p[2], p[3], g_imgQuality);
        }
    }

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
    long long nextTick = AXNowMs();   /* 下一帧的调度时刻 */
    int  staticStreak = 0;            /* 连续多少帧画面完全没变（用于降帧降温） */
    NSData *lastEnc = nil;

    while (g_running) {
        @autoreleasepool {
            if (g_scheme == 1) {
                /* ReplayKit 模式：帧在采集回调里直接编码发送，这里不抓图、不占 CPU */
                usleep(100 * 1000);
                continue;
            }
            if (g_clientCount <= 0) {
                /* 没人看就不抓，省电省 CPU */
                usleep(50 * 1000);
                continue;
            }
            if (g_clientCount > 0 && g_force_key == 0 && g_sentFrames == 0) {
                /* 首帧也强制 IDR */
                g_force_key = 1;
            }

            long long t0 = AXNowMs();
            CGSize px = CGSizeZero;
            NSData *enc = AXGrabEncodedData(&px);
            if (enc) g_lastImgBytes = (long long)enc.length;
            if (!enc) {
                /* 采集失败：把 AXSetErr 记的原因打出来（每 20 次打一条，别刷爆日志） */
                static int miss = 0;
                miss++;
                if (miss % 20 == 1) {
                    ALogShim(@"⚠️ 采集失败第%d次: %@  state=%ld",
                             miss, AXAgentLastError() ?: @"?", (long)[UIApplication sharedApplication].applicationState);
                }
                if ((AXNowMs() - statT0) >= 5000) {
                    ALogShim(@"❤️ 心跳 state=%ld clients=%d sent=%d 采集失败=%d vt=%p %dx%d",
                             (long)[UIApplication sharedApplication].applicationState,
                             g_clientCount, g_sentFrames, miss, (void *)g_vt, g_encW, g_encH);
                    statT0 = AXNowMs();
                }
                usleep(30 * 1000);
                continue;
            }

            /* 目标编码尺寸：长边 = maxSide，保持比例、对齐到偶数 */
            int tw = g_encW, th = g_encH;
            if (tw == 0 || th == 0) {
                /* ★ 按「短边」缩放：竖屏手机的短边就是宽度，这样 720 表示"宽 720"，
                   1290x2796 → 720x1560（之前按长边算成了 332x720，preamble 却报 720x1560，
                   PC 端按错误的宽高解码 → 花屏/黑屏） */
                CGFloat shortSide = MIN(px.width, px.height);
                CGFloat k = shortSide > 0 ? (CGFloat)g_maxSide / shortSide : 1.0;
                if (k > 1.0) k = 1.0;
                tw = (int)(round(px.width * k)); th = (int)(round(px.height * k));
                tw &= ~1; th &= ~1;   /* 偶数（H.264 要求） */
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

            /* ★ 静止画面检测（省电降温的关键）：
               IPC 截出来的 JPEG 若与上一帧逐字节相同 ⇒ 屏幕真的一个像素都没变。
               这时还按目标帧率全屏截图 + 缩放 + 编码，纯粹在烧电发热；
               连续 4 帧不变就把帧率压到 2fps，一旦有变化（手指一动/画面一动）立刻恢复。
               下限保 2fps：PC 侧 15 秒收不到帧会判死重连，不能真的停。 */
            if (lastEnc && enc.length == lastEnc.length &&
                memcmp(enc.bytes, lastEnc.bytes, enc.length) == 0) {
                if (staticStreak < 1000) staticStreak++;
            } else {
                staticStreak = 0;
                lastEnc = enc;
            }

            /* 解码（2026-10-31 改）：以前是「按原尺寸解满 3.6MP → 再重采样到 720×1560」，
               多解了 3 倍像素，而且全部是 CPU 在跑（发热主因之一）。
               现在用 CGImageSourceCreateThumbnailAtIndex 让 ImageIO 在解码阶段就按目标
               长边缩放（JPEG 走 DCT scaling，1/2、1/4 直接出），解码和缩放合并成一步。
               失败（格式不支持缩略图路径）再退回原来的全解 + 重采样。 */
            long long tDec0 = AXNowMs();
            CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)enc, NULL);
            CGImageRef img = NULL;
            if (src) {
                if (g_decodeThumb) {
                    NSDictionary *thumbOpts = @{
                        (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
                        (id)kCGImageSourceCreateThumbnailWithTransform:   @NO,
                        (id)kCGImageSourceThumbnailMaxPixelSize:          @(MAX(tw, th)),
                    };
                    img = CGImageSourceCreateThumbnailAtIndex(src, 0,
                                                              (__bridge CFDictionaryRef)thumbOpts);
                }
                if (!img) img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
                CFRelease(src);
            }
            if (!img) { usleep(20 * 1000); continue; }
            long long tDec1 = AXNowMs();

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
            g_lastDecMs  = tDec1 - tDec0;      /* 解码（含 DCT 缩放） */
            g_lastDrawMs = AXNowMs() - tDec1;  /* 转 CVPixelBuffer + 重采样 */

            /* 不再每帧强制 IDR；新连接时 g_force_key 置位一次（照 mirror_stream v46） */
            CFDictionaryRef fp = NULL;
            if (g_force_key) {
                fp = (__bridge CFDictionaryRef)@{ (NSString *)kVTEncodeFrameOptionKey_ForceKeyFrame: @YES };
                g_force_key = 0;
                ALogShim(@"🎬 新连接，本帧强制 IDR");
            }
            CMTime pcm = CMTimeMake(AXNextPts(), 1000);
            VTEncodeInfoFlags flags = 0;
            OSStatus es = VTCompressionSessionEncodeFrame(g_vt, pb, pcm, kCMTimeInvalid,
                                                          fp, NULL, &flags);
            CVPixelBufferRelease(pb);
            if (es != noErr) {
                AXSetErr((int)es, [NSString stringWithFormat:@"EncodeFrame 失败 st=%d", (int)es]);
                /* ★ -12903 = kVTInvalidSessionErr：会话被系统作废（后台收回硬编/重建失败等）。
                   以前这里只记错误不重建，会话一废整条流就永远停住（sent 卡死）→ 现在重建。 */
                long long nowMs = AXNowMs();
                if (es == kVTInvalidSessionErr || es == kVTParameterErr) {
                    ALogShim(@"❌ EncodeFrame st=%d vt=%p %dx%d 距上次丢弃 %lldms",
                             (int)es, (void *)g_vt, g_encW, g_encH,
                             g_vtDropAt ? (nowMs - g_vtDropAt) : -1LL);
                    g_vtDropAt = nowMs;
                    AXVTDrop("EncodeFrame 返回无效会话");
                }
                usleep(50 * 1000);
                continue;
            }

            frameCount++;
            statFrames++;
            if ((AXNowMs() - statT0) >= 5000) {
                ALogShim(@"❤️ 心跳 state=%ld clients=%d sent=%d fps=%d 图%luKB 解%lldms 绘%lldms 静止%d vt=%p %dx%d",
                         (long)[UIApplication sharedApplication].applicationState,
                         g_clientCount, g_sentFrames,
                         (int)(statFrames * 1000 / MAX(1, (AXNowMs() - statT0))),
                         (unsigned long)(g_lastImgBytes / 1024),
                         g_lastDecMs, g_lastDrawMs, staticStreak,
                         (void *)g_vt, g_encW, g_encH);
                statT0 = AXNowMs(); statFrames = 0;
            }

            /* 节奏控制（2026-10-31 改）：按「下一帧的绝对时刻」排程。
               旧写法 sleep(预算 - 本帧耗时) 会把抖动一点点累积，实测帧率比目标低 10~20%；
               而且一旦某帧超预算就完全不等，等于放开跑、把带宽打满。 */
            /* ★ 输入唤醒：只要收到触控（g_inputKick），立刻抓一帧并解除静止降帧。
               不做这个的话，静止时是 2fps，手指点下去要等最多 0.5 秒画面才动，
               用户感受就是"点了半天才反应"。 */
            if (g_inputKick) {
                g_inputKick = 0;
                staticStreak = 0;
                nextTick = AXNowMs();
            }

            int fpsNow = (g_fps > 0 ? g_fps : 20);
            if (fpsNow > 60) fpsNow = 60;
            if (fpsNow < 1)  fpsNow = 1;
            /* 画面静止超过 4 帧 → 2fps（只发心跳帧维持会话）；有变化立刻回到目标帧率 */
            if (g_staticDrop && staticStreak >= 4 && fpsNow > 2) fpsNow = 2;
            long long intervalMs = 1000 / fpsNow;
            nextTick += intervalMs;
            long long nowPace = AXNowMs();
            if (nextTick > nowPace) {
                /* 分段睡：中间一旦有触控就提前醒来，别死等满一整帧间隔 */
                long long remain = nextTick - nowPace;
                while (remain > 0 && g_running) {
                    if (g_inputKick) {
                        g_inputKick = 0;
                        staticStreak = 0;
                        nextTick = AXNowMs();
                        break;
                    }
                    long long stepMs = remain > 8 ? 8 : remain;
                    usleep((useconds_t)(stepMs * 1000));
                    remain -= stepMs;
                }
            } else if (nowPace - nextTick > intervalMs * 3) {
                nextTick = nowPace;      /* 落后超过 3 帧就不追，免得补帧连发 */
            }
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
        /* 发送超时 200ms：PC 端读得慢时宁可丢这个客户端，也不能把编码线程卡死 */
        struct timeval sndTo;
        sndTo.tv_sec = 0;
        sndTo.tv_usec = 200 * 1000;
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sndTo, sizeof(sndTo));
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

        /* 已有编码尺寸就直接发 preamble；没有就等编码循环第一帧算出来再发
           （★ 之前这里用 maxSide 硬凑 720x1560，和真实编码尺寸 332x720 不符 → 黑屏） */
        if (g_encW > 0 && g_encH > 0) {
            AXSendPreamble(fd, g_encW, g_encH, g_maxSide);
            AXSendSessionHeader(g_encW, g_encH);
            g_needConfig = YES;   /* 新客户端要重新收一份 SPS/PPS */
            g_force_key = 1;      /* ★ 新连接强制下一帧 IDR（照 mirror_stream v46） */
            g_preambleSent = 1;
        }
    }
    ALogShim(@"📡 accept 循环退出");
    return NULL;
}

/* ---------------- 对外接口 ---------------- */

static void AXLoadStoredUDIDIfNeeded(void);

/* ---------------- 后台常驻 ----------------
   现象：App 一退到后台，27184 的 H.264 流就断。
   原因：iOS 把 App 挂起（suspend），socket/线程全部冻结，不是我们代码断了。
   做法（行业通用）：声明 UIBackgroundModes=audio + 播一段静音循环，系统就认为
   "还在播音频"而保持进程活着；另外再挂一个 beginBackgroundTask 兜底（给非音频阶段争取时间）。
   代价：后台常驻会多耗一点电。 */
static AVAudioPlayer *g_keepAlivePlayer = nil;
static UIBackgroundTaskIdentifier g_bgTask = UIBackgroundTaskInvalid;
static volatile int g_keepAliveOn = 0;

/* 1 秒 44.1k/16bit/单声道静音 WAV */
static NSData *AXSilentWav(void) {
    const int rate = 44100, secs = 1, ch = 1, bits = 16;
    const int dataLen = rate * secs * ch * bits / 8;
    NSMutableData *d = [NSMutableData data];
    uint8_t hdr[44];
    memcpy(hdr, "RIFF", 4);
    uint32_t v = 36 + dataLen; memcpy(hdr + 4, &v, 4);
    memcpy(hdr + 8, "WAVEfmt ", 8);
    v = 16; memcpy(hdr + 16, &v, 4);
    uint16_t s16 = 1; memcpy(hdr + 20, &s16, 2);       /* PCM */
    s16 = ch;         memcpy(hdr + 22, &s16, 2);
    v = rate;         memcpy(hdr + 24, &v, 4);
    v = rate * ch * bits / 8; memcpy(hdr + 28, &v, 4);
    s16 = ch * bits / 8; memcpy(hdr + 32, &s16, 2);
    s16 = bits;       memcpy(hdr + 34, &s16, 2);
    memcpy(hdr + 36, "data", 4);
    v = dataLen;      memcpy(hdr + 40, &v, 4);
    [d appendBytes:hdr length:44];
    [d appendBytes:calloc(1, dataLen) length:dataLen];
    return d;
}

/* AS 方案：后台模式多路并联，哪条通了都活着。
   - audio：静音循环（最省电，不弹权限）
   - location：CLLocationManager 持续定位（最稳，需「始终允许」）
   - bluetooth-central：CBCentralManager 周期扫描（无状态栏提示，需蓝牙权限） */
@interface AXBGKeeper : NSObject <CLLocationManagerDelegate, CBCentralManagerDelegate>
@end

@implementation AXBGKeeper
- (void)locationManager:(CLLocationManager *)m didUpdateLocations:(NSArray<CLLocation *> *)locs { }
- (void)locationManager:(CLLocationManager *)m didFailWithError:(NSError *)e { }
- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)m {
    ALogShim(@"📍 定位授权状态=%d", (int)m.authorizationStatus);
}
- (void)centralManagerDidUpdateState:(CBCentralManager *)c {
    ALogShim(@"📶 蓝牙状态=%ld", (long)c.state);
    if (c.state == CBManagerStatePoweredOn) {
        [c scanForPeripheralsWithServices:@[[CBUUID UUIDWithString:@"FFF0"]] options:nil];
    }
}
@end

static AXBGKeeper *g_bgKeeper = nil;
static CLLocationManager *g_locMgr = nil;
static CBCentralManager *g_btMgr = nil;

/* 应用前后台切换打点：用来判断"流断"到底是 App 被挂起，还是编码/采集出错 */
static void AXInstallLifecycleLog(void) {
    static int done = 0;
    if (done) return;
    done = 1;
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    void (^logState)(NSString *) = ^(NSString *tag) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ALogShim(@"📱 生命周期: %@  state=%ld  clients=%d  frames=%d  vt=%p",
                     tag, (long)[UIApplication sharedApplication].applicationState,
                     g_clientCount, g_sentFrames, (void *)g_vt);
        });
    };
    [nc addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:nil
                 usingBlock:^(NSNotification *n) { logState(@"willResignActive"); }];
    [nc addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:nil
                 usingBlock:^(NSNotification *n) { logState(@"didEnterBackground"); }];
    [nc addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:nil
                 usingBlock:^(NSNotification *n) { logState(@"willEnterForeground"); }];
    [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil
                 usingBlock:^(NSNotification *n) { logState(@"didBecomeActive"); }];
}

static void AXStartKeepAlive(void) {
    if (g_keepAliveOn) return;
    g_keepAliveOn = 1;
    dispatch_async(dispatch_get_main_queue(), ^{
        /* 兜底：先要一个后台任务（音频起来前争取 ~30s） */
        if (g_bgTask == UIBackgroundTaskInvalid) {
            g_bgTask = [[UIApplication sharedApplication]
                        beginBackgroundTaskWithName:@"AXStreamKeepAlive"
                        expirationHandler:^{
                ALogShim(@"⌛ 后台任务到期（音频没生效？）");
            }];
        }
        NSError *e1 = nil, *e2 = nil;
        AVAudioSession *s = [AVAudioSession sharedInstance];
        [s setCategory:AVAudioSessionCategoryPlayback
           withOptions:AVAudioSessionCategoryOptionMixWithOthers
                 error:&e1];
        [s setActive:YES error:&e2];
        if (!g_keepAlivePlayer) {
            NSError *e3 = nil;
            g_keepAlivePlayer = [[AVAudioPlayer alloc] initWithData:AXSilentWav() error:&e3];
            g_keepAlivePlayer.numberOfLoops = -1;
            g_keepAlivePlayer.volume = 0.0;
            if (e3) ALogShim(@"⚠️ 静音音频初始化失败: %@", e3.localizedDescription);
        }
        BOOL ok = [g_keepAlivePlayer play];
        ALogShim(@"🔋 后台常驻已开启（音频 ok=%d cat/act err=%@/%@）", ok,
                 e1.localizedDescription ?: @"ok", e2.localizedDescription ?: @"ok");

        /* ② 定位保活（最稳；需要「始终允许」权限，状态栏会有定位箭头） */
        if (!g_bgKeeper) g_bgKeeper = [AXBGKeeper new];
        if (!g_locMgr) {
            g_locMgr = [CLLocationManager new];
            g_locMgr.delegate = g_bgKeeper;
            g_locMgr.desiredAccuracy = kCLLocationAccuracyThreeKilometers;
            g_locMgr.distanceFilter = 1000;
            g_locMgr.pausesLocationUpdatesAutomatically = NO;
            @try { g_locMgr.allowsBackgroundLocationUpdates = YES; } @catch (NSException *e) {
                ALogShim(@"⚠️ allowsBackgroundLocationUpdates 设置失败: %@", e.reason);
            }
            [g_locMgr requestAlwaysAuthorization];
        }
        [g_locMgr startUpdatingLocation];
        ALogShim(@"📍 定位保活已启动（授权=%d）", (int)g_locMgr.authorizationStatus);

        /* ③ 蓝牙中心保活（无状态栏提示，需蓝牙权限） */
        if (!g_btMgr) {
            g_btMgr = [[CBCentralManager alloc] initWithDelegate:g_bgKeeper
                                                           queue:dispatch_get_main_queue()
                                                         options:@{CBCentralManagerOptionShowPowerAlertKey: @NO}];
        }
        if (g_btMgr.state == CBManagerStatePoweredOn) {
            [g_btMgr scanForPeripheralsWithServices:@[[CBUUID UUIDWithString:@"FFF0"]] options:nil];
        }
        ALogShim(@"📶 蓝牙保活已启动（状态=%ld）", (long)g_btMgr.state);
    });
}

static void AXStopKeepAlive(void) {
    if (!g_keepAliveOn) return;
    g_keepAliveOn = 0;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_keepAlivePlayer) { [g_keepAlivePlayer stop]; }
        if (g_locMgr) [g_locMgr stopUpdatingLocation];
        if (g_btMgr) [g_btMgr stopScan];
        if (g_bgTask != UIBackgroundTaskInvalid) {
            [[UIApplication sharedApplication] endBackgroundTask:g_bgTask];
            g_bgTask = UIBackgroundTaskInvalid;
        }
        ALogShim(@"🔋 后台常驻已关闭");
    });
}

/* ---------------- 采集方案 B：ReplayKit ----------------
   RPScreenRecorder 直接给 CMSampleBuffer（像素已在内存里，不用解码），喂给 VT 即可，
   比 XCUITest 少一次"编码数据→解码→转 BGRA"。
   代价：状态栏出现录屏标识；个别内容（DRM 视频）拿不到 → 由看门狗回退 XCUITest。 */
/* ---------- 测试档位表（临时脚手架：测完删掉这一段 + UI 里的动态菜单即可） ----------
   每个档位 = 采集方式 + 截图编码格式 + 压缩质量。
   用途：一次装机把「JPEG/PNG/TIFF/录屏」四种拿流方式全测一遍，看 图·解·绘·fps 四组数字。 */
typedef struct {
    const char *name;
    int         capture;   /* 0=系统截图(XCUITest IPC)  1=系统录屏(ReplayKit) */
    const char *uti;       /* 截图编码格式 */
    double      quality;   /* 压缩质量 */
} AXTestProfile;

static const AXTestProfile kAXProfiles[] = {
    { "系统截图 · JPEG 0.70（默认）", 0, "public.jpeg", 0.70 },
    { "系统截图 · JPEG 0.40（极速）", 0, "public.jpeg", 0.40 },
    { "系统截图 · TIFF 未压缩",       0, "public.tiff", 1.00 },
    { "系统截图 · PNG 无损",          0, "public.png",  1.00 },
    { "系统录屏",                     1, "public.jpeg", 0.70 },
};

int AXStreamProfileCount(void) {
    return (int)(sizeof(kAXProfiles) / sizeof(kAXProfiles[0]));
}

const char *AXStreamProfileName(int idx) {
    if (idx < 0 || idx >= AXStreamProfileCount()) return "";
    return kAXProfiles[idx].name;
}

int AXStreamProfileCapture(int idx) {
    if (idx < 0 || idx >= AXStreamProfileCount()) return 0;
    return kAXProfiles[idx].capture;
}

const char *AXStreamProfileDesc(int idx) {
    if (idx < 0 || idx >= AXStreamProfileCount()) return "";
    static char buf[160];
    const AXTestProfile *p = &kAXProfiles[idx];
    snprintf(buf, sizeof(buf), "采集=%s 格式=%s q=%.2f",
             p->capture ? "录屏" : "截图", p->uti, p->quality);
    return buf;
}

/* 应用档位：编码参数（格式/质量）每帧读取 → 立即生效；
   采集方式（截图↔录屏）需要重启投屏服务才切换。 */
void AXStreamApplyProfile(int idx) {
    if (idx < 0 || idx >= AXStreamProfileCount()) return;
    const AXTestProfile *p = &kAXProfiles[idx];
    /* ★ 只记"想要哪种采集"，不直接改 g_scheme：否则选「录屏」的瞬间编码循环就停了截图，
       而 ReplayKit 只在 Start 里启动 → 中间画面会冻住。真正切换发生在 AXStreamStart。 */
    g_profileCapture = (p->capture == 1) ? 1 : 0;
    g_rkFallback = 0;
    memset(g_imgUTI, 0, sizeof(g_imgUTI));
    size_t n = strlen(p->uti);
    if (n >= sizeof(g_imgUTI)) n = sizeof(g_imgUTI) - 1;
    memcpy(g_imgUTI, p->uti, n);
    g_imgQuality = p->quality;
    ALogShim(@"🎛 档位[%d] %s（%s）", idx, p->name, AXStreamProfileDesc(idx));
}

void AXStreamSetScheme(int s) { g_scheme = (s == 1) ? 1 : 0; g_rkFallback = 0; }
int  AXStreamGetScheme(void) { return g_scheme; }
/* 供界面显示：0=XCUITest 1=ReplayKit 2=ReplayKit 失败已回退 */
int  AXStreamActiveScheme(void) { return g_rkFallback ? 2 : g_scheme; }

static void AXReplayKitStopInternal(void) {
    RPScreenRecorder *r = [RPScreenRecorder sharedRecorder];
    if (r.isRecording) {
        [r stopCaptureWithHandler:^(NSError *e) {
            ALogShim(@"🛑 ReplayKit 已停止（%@）", e ? e.localizedDescription : @"ok");
        }];
    }
}

static void AXReplayKitHandler(CMSampleBufferRef sbuf, RPSampleBufferType type, NSError *err) {
    if (type != RPSampleBufferTypeVideo) return;
    if (err) { ALogShim(@"❌ ReplayKit 帧错误: %@", err.localizedDescription); return; }
    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sbuf);
    if (!pb) return;
    int w = (int)CVPixelBufferGetWidth(pb);
    int h = (int)CVPixelBufferGetHeight(pb);
    if (w <= 0 || h <= 0) return;
    if (!AXVTEnsureWithFormat(w, h, CVPixelBufferGetPixelFormatType(pb))) return;

    if (!g_preambleSent) {
        pthread_mutex_lock(&g_clientMu);
        for (int i = 0; i < 4; i++) {
            if (g_clients[i] >= 0) AXSendPreamble(g_clients[i], w, h, g_maxSide);
        }
        pthread_mutex_unlock(&g_clientMu);
        AXSendSessionHeader(w, h);
        g_preambleSent = 1;
        ALogShim(@"📺 [RK] preamble 已发 %dx%d", w, h);
    }
    OSStatus es = VTCompressionSessionEncodeFrame(g_vt, pb,
                                    CMSampleBufferGetPresentationTimeStamp(sbuf),
                                    kCMTimeInvalid, NULL, NULL, NULL);
    if (es != noErr) {
        ALogShim(@"❌ [RK] EncodeFrame 失败 st=%d → 丢弃会话重建", (int)es);
        AXVTDrop("ReplayKit 编码失败");
        return;
    }
    g_rkFrames++;
}

/* 看门狗：3 秒没出帧就认定"这一路拿不到画面"，自动回退到 XCUITest 截图。
   覆盖：权限没给、isAvailable=NO、DRM 内容、系统限制等。 */
static void *AXReplayKitWatchdog(void *arg) {
    (void)arg;
    for (int i = 0; i < 50; i++) {          /* ★ 用户要求放宽到 5 秒 */
        usleep(100 * 1000);
        if (!g_running || g_scheme != 1) return NULL;
        if (g_rkFrames > 0) return NULL;
    }
    ALogShim(@"⚠️ ReplayKit 5 秒内没有出帧 → 自动回退 XCUITest 截图方案");
    AXReplayKitStopInternal();
    g_scheme = 0;
    g_rkFallback = 1;
    return NULL;
}

static BOOL AXReplayKitStart(void) {
    RPScreenRecorder *r = [RPScreenRecorder sharedRecorder];
    if (!r.isAvailable) {
        ALogShim(@"❌ ReplayKit 不可用（isAvailable=NO）→ 回退 XCUITest");
        g_rkFallback = 1;
        g_scheme = 0;
        return NO;
    }
    r.microphoneEnabled = NO;
    g_rkFrames = 0;
    [r startCaptureWithHandler:^(CMSampleBufferRef sbuf, RPSampleBufferType t, NSError *e) {
        @autoreleasepool { AXReplayKitHandler(sbuf, t, e); }
    } completionHandler:^(NSError *e) {
        if (e) {
            ALogShim(@"❌ ReplayKit 启动失败: %@ → 回退 XCUITest", e.localizedDescription);
            g_rkFallback = 1;
            g_scheme = 0;
        } else {
            ALogShim(@"✅ ReplayKit 采集已启动（等首帧）");
        }
    }];
    pthread_t tid;
    pthread_create(&tid, NULL, AXReplayKitWatchdog, NULL);
    pthread_detach(tid);
    return YES;
}

/* 运行期应用画质参数（PC 的 0x40 走这里，10010 的 fps 命令也走这里）。
   - fps：立刻影响编码循环的排程
   - bitrate：直接改现有 VT 会话的 ABR 目标，不重建
   - maxSide：分辨率变了必须重建编码会话（下一帧自动建），并强制一个关键帧
   ★ 不重发 preamble：PC 侧解码器是从 SPS 里读新尺寸的（rebuild 由 dec.FrameSize() 触发），
     往已建的流里再发一遍 preamble 会把 PC 的包解析打乱（就是 10-31 那次闪退）。 */
static void AXApplyVideoParams(uint32_t fps, uint32_t bitrateBps, uint32_t maxSide) {
    if (fps > 0) {
        g_fps = (int)fps;
        if (g_vt) {
            VTSessionSetProperty(g_vt, kVTCompressionPropertyKey_ExpectedFrameRate,
                                 (__bridge CFNumberRef)@(g_fps));
        }
    }
    if (bitrateBps > 0) {
        g_bitrate = (int)bitrateBps;
        if (g_vt) {
            VTSessionSetProperty(g_vt, kVTCompressionPropertyKey_AverageBitRate,
                                 (__bridge CFNumberRef)@(g_bitrate));
        }
    }
    if (maxSide > 0 && (int)maxSide != g_maxSide) {
        g_maxSide = (int)maxSide;
        g_force_key = 1;
        AXVTDrop("分辨率变更");
    }
    ALogShim(@"🎚 画质参数 fps=%d  %dkbps  maxSide=%d", g_fps, g_bitrate / 1000, g_maxSide);
}

#pragma mark - 7. 控制通道 27185（scrcpy 二进制消息 + AES-256-CTR）

/* 与 PC 端 internal/iosscreen 的约定（v46.17 起）：
   - 视频 27184 明文；控制 27185 建连后 PC 先发 16B 明文 nonce，
     之后双向 AES-256-CTR：IV=nonce，末字节 bit0=0 → PC→设备，=1 → 设备→PC。
   - 消息：0x00 按键(14B) / 0x01 文本(5+n) / 0x02 触控(32B) / 0x03 滚动(21B)
           / 0x04 返回(2B) / 0x09 剪贴板(14+n)
   - 触控 x/y 是「画面像素」坐标，w/h 同一坐标系 → 这里换算回屏幕点数（XCUITest 用点）。 */
static const uint8_t kAXCtrlKey[32] = {
    0x7c, 0x1e, 0x93, 0xa5, 0xd4, 0x48, 0xf0, 0xb2, 0x6a, 0xc9, 0x51, 0xe7,
    0x33, 0x8d, 0x02, 0xf5, 0xb8, 0x64, 0x1d, 0x9a, 0xc0, 0x27, 0xfe, 0x73,
    0x59, 0xe1, 0x8b, 0x46, 0xd3, 0xaa, 0x90, 0x6c,
};

static int      g_ctrlListen = -1;
static volatile int g_ctrlRun = 0;
static CCCryptorRef g_ccDec = NULL;   /* PC → 设备 */
static CCCryptorRef g_ccEnc = NULL;   /* 设备 → PC */

static inline uint32_t AXBE32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}
static inline uint16_t AXBE16(const uint8_t *p) {
    return (uint16_t)(((uint16_t)p[0] << 8) | p[1]);
}

static BOOL AXCryptoInit(const uint8_t *nonce16) {
    if (g_ccDec) { CCCryptorRelease(g_ccDec); g_ccDec = NULL; }
    if (g_ccEnc) { CCCryptorRelease(g_ccEnc); g_ccEnc = NULL; }
    uint8_t iv0[16], iv1[16];
    memcpy(iv0, nonce16, 16); iv0[15] &= (uint8_t)~1;
    memcpy(iv1, nonce16, 16); iv1[15] |= 1;
    /* AES-CTR 两向都是「异或同一密钥流」，所以两个方向都用 kCCEncrypt 建上下文 */
    CCCryptorStatus s1 = CCCryptorCreateWithMode(kCCEncrypt, kCCModeCTR,
        kCCAlgorithmAES, ccNoPadding, iv0, kAXCtrlKey, 32,
        NULL, 0, 0, kCCModeOptionCTR_BE, &g_ccDec);
    CCCryptorStatus s2 = CCCryptorCreateWithMode(kCCEncrypt, kCCModeCTR,
        kCCAlgorithmAES, ccNoPadding, iv1, kAXCtrlKey, 32,
        NULL, 0, 0, kCCModeOptionCTR_BE, &g_ccEnc);
    if (s1 != kCCSuccess || s2 != kCCSuccess) {
        ALog(@"❌ 控制通道 AES 初始化失败 %d/%d", (int)s1, (int)s2);
        return NO;
    }
    return YES;
}

static void AXCryptInPlace(CCCryptorRef cc, void *buf, size_t len) {
    if (!cc || len == 0) return;
    uint8_t *tmp = (uint8_t *)malloc(len);
    if (!tmp) return;
    size_t moved = 0;
    if (CCCryptorUpdate(cc, buf, len, tmp, len, &moved) == kCCSuccess && moved == len) {
        memcpy(buf, tmp, len);
    }
    free(tmp);
}

static BOOL AXReadExactRaw(int fd, void *buf, size_t want) {
    size_t got = 0;
    while (got < want) {
        if (!g_ctrlRun) return NO;
        ssize_t n = read(fd, (uint8_t *)buf + got, want - got);
        if (n > 0) { got += (size_t)n; continue; }
        /* ★ 控制通道大部分时间是空闲的：SO_RCVTIMEO 到点返回 EAGAIN 属正常，
           绝不能被当成"断开"（否则 PC 手一停，控制口就自己掉了） */
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) continue;
        return NO;
    }
    return YES;
}

/* 读 want 字节并解密 */
static BOOL AXReadDec(int fd, void *buf, size_t want) {
    if (want == 0) return YES;
    if (!AXReadExactRaw(fd, buf, want)) return NO;
    AXCryptInPlace(g_ccDec, buf, want);
    return YES;
}

/* 读掉 n 字节（仍要解密，否则密钥流位置会错） */
static BOOL AXSkipBytes(int fd, uint32_t n) {
    uint8_t tmp[256];
    while (n > 0) {
        size_t c = (n > sizeof(tmp)) ? sizeof(tmp) : n;
        if (!AXReadDec(fd, tmp, c)) return NO;
        n -= (uint32_t)c;
    }
    return YES;
}

/* ---------- 触摸聚合：PC 发的是 down/move/up 流，XCTest 要的是「一条完整轨迹」 ---------- */
#define AX_TP_MAX 160
typedef struct { double x, y, t; } AXTouchPt;

static AXTouchPt g_tpts[2][AX_TP_MAX];
static int       g_tpn[2];
static int64_t   g_tpId[2];
static BOOL      g_tpUsed[2];
static BOOL      g_tpDone[2];   /* 这根手指是否已抬起（两根都抬起才提交） */
static double    g_tpT0;

static void AXTouchReset(void) {
    g_tpn[0] = g_tpn[1] = 0;
    g_tpUsed[0] = g_tpUsed[1] = NO;
    g_tpDone[0] = g_tpDone[1] = NO;
    g_tpId[0] = g_tpId[1] = 0;
    g_tpT0 = 0;
}

static double AXNowSec(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (double)tv.tv_sec + tv.tv_usec / 1000000.0;
}

/* 把攒下的轨迹一次性合成提交：1 指=点/滑动，2 指=任意双指手势 */
static void AXTouchCommit(void) {
    int nUsed = (g_tpUsed[0] ? 1 : 0) + (g_tpUsed[1] ? 1 : 0);
    if (nUsed <= 0) { AXTouchReset(); return; }

    if (nUsed == 1) {
        int s = g_tpUsed[0] ? 0 : 1;
        int k = g_tpn[s];
        if (k <= 0) { AXTouchReset(); return; }
        if (k <= 2) {
            AXTapCore(g_tpts[s][0].x, g_tpts[s][0].y);
        } else {
            double xy[AX_TP_MAX * 2];
            double tt[AX_TP_MAX];
            for (int i = 0; i < k; i++) {
                xy[i * 2]     = g_tpts[s][i].x;
                xy[i * 2 + 1] = g_tpts[s][i].y;
                tt[i]         = g_tpts[s][i].t;
            }
            AXGestureCore(xy, tt, k);
        }
        AXTouchReset();
        return;
    }

    /* 双指：同一个 record 里挂两条 path */
    @try {
        Class pathCls = NSClassFromString(@"XCPointerEventPath");
        Class recCls  = NSClassFromString(@"XCSynthesizedEventRecord");
        if (!pathCls || !recCls) { AXTouchReset(); return; }
        SEL initRec = NSSelectorFromString(@"initWithName:interfaceOrientation:");
        id rec = ((id (*)(id, SEL, id, long))objc_msgSend)([recCls alloc], initRec,
                                                           @"AXAgent", AXInterfaceOrientation());
        if (!rec) { AXTouchReset(); return; }

        SEL initPath = NSSelectorFromString(@"initForTouchAtPoint:offset:");
        SEL mv       = NSSelectorFromString(@"moveToPoint:atOffset:");
        SEL up       = NSSelectorFromString(@"liftUpAtOffset:");
        SEL addPath  = NSSelectorFromString(@"addPointerEventPath:");

        for (int s = 0; s < 2; s++) {
            if (!g_tpUsed[s] || g_tpn[s] <= 0) continue;
            id path = ((id (*)(id, SEL, CGPoint, double))objc_msgSend)(
                          [pathCls alloc], initPath,
                          CGPointMake(g_tpts[s][0].x, g_tpts[s][0].y), 0.0);
            if (!path) continue;
            for (int i = 1; i < g_tpn[s]; i++) {
                ((void (*)(id, SEL, CGPoint, double))objc_msgSend)(
                    path, mv, CGPointMake(g_tpts[s][i].x, g_tpts[s][i].y), g_tpts[s][i].t);
            }
            ((void (*)(id, SEL, double))objc_msgSend)(path, up, g_tpts[s][g_tpn[s] - 1].t);
            ((void (*)(id, SEL, id))objc_msgSend)(rec, addPath, path);
        }

        if (!AXSubmitEventRecord(rec, 0.05)) ALog(@"❌ 双指事件提交失败");
    } @catch (NSException *e) {
        ALog(@"❌ 双指事件异常: %@", e.reason);
    }
    AXTouchReset();
}

static void AXTouchHandle(const uint8_t *b) {
    /* ★ 延迟诊断：相邻两条触控消息的到达间隔。若这里就 >500ms，说明慢在 PC 侧发送，
       不怪我们；若间隔很小但动作不生效，那问题在我们合成/系统处理。 */
    {
        static long long lastMs = 0;
        long long now = AXSeqMs();
        if (lastMs > 0) {
            long long dt = now - lastMs;
            if (dt > 300) ALog(@"⏱ 触控到达间隔 %lldms（action=%d）", dt, b[0]);
        }
        lastMs = now;
    }
    g_inputKick = 1;      /* 手指一动就让编码循环马上抓一帧（静止降帧时否则要等 0.5s 才有反馈） */
    int     action = b[0];
    int64_t pid    = 0;
    for (int i = 0; i < 8; i++) pid = (pid << 8) | b[1 + i];
    double  x = AXBE32(b + 9), y = AXBE32(b + 13);
    int     w = AXBE16(b + 17), h = AXBE16(b + 19);

    CGSize pts = [UIScreen mainScreen].bounds.size;
    double sx = (w > 0) ? pts.width / (double)w : 1.0;
    double sy = (h > 0) ? pts.height / (double)h : 1.0;
    double px = x * sx, py = y * sy;

    if (action == 3) { AXTouchReset(); return; }   /* cancel */

    int slot = -1;
    for (int i = 0; i < 2; i++) {
        if (g_tpUsed[i] && g_tpId[i] == pid) { slot = i; break; }
    }
    if (slot < 0) {
        for (int i = 0; i < 2; i++) {
            if (!g_tpUsed[i]) {
                slot = i; g_tpUsed[i] = YES; g_tpDone[i] = NO; g_tpId[i] = pid; g_tpn[i] = 0;
                break;
            }
        }
    }
    if (slot < 0) return;                          /* 只支持 2 指 */

    if (g_tpT0 == 0) g_tpT0 = AXNowSec();
    double t = AXNowSec() - g_tpT0;
    if (t > 5.0) t = 5.0;

    if (action == 0 || action == 2) {
        if (g_tpn[slot] < AX_TP_MAX) {
            g_tpts[slot][g_tpn[slot]].x = px;
            g_tpts[slot][g_tpn[slot]].y = py;
            g_tpts[slot][g_tpn[slot]].t = t;
            g_tpn[slot]++;
        }
        if (action == 0) g_tpUsed[slot] = YES;
    } else if (action == 1) {                      /* up：补齐末点并结束这一指 */
        if (g_tpn[slot] < AX_TP_MAX) {
            g_tpts[slot][g_tpn[slot]].x = px;
            g_tpts[slot][g_tpn[slot]].y = py;
            g_tpts[slot][g_tpn[slot]].t = t;
            g_tpn[slot]++;
        }
        g_tpDone[slot] = YES;
        /* 所有在按的手指都抬起了才提交；还有一根按着就继续等它 */
        BOOL anyActive = NO;
        for (int i = 0; i < 2; i++) {
            if (g_tpUsed[i] && !g_tpDone[i]) anyActive = YES;
        }
        if (!anyActive) AXTouchCommit();
    }
}

static void AXCtrlKeycode(uint32_t kc) {
    switch (kc) {
        case 3:   AXAgentPressHome();           break;   /* Home */
        case 4:   AXAgentPressHome();           break;   /* Back → iOS 无返回键，等价 Home */
        case 66:  AXAgentKey(@"\r", 0);         break;   /* Enter */
        case 67:  AXAgentKey(@"\b", 0);         break;   /* Del/退格 */
        default:  ALog(@"  ⌨️ 未映射的 keycode=%u（忽略）", kc); break;
    }
}

static void AXCtrlHandleClient(int fd) {
    uint8_t nonce[16];
    if (!AXReadExactRaw(fd, nonce, 16)) { close(fd); return; }
    if (!AXCryptoInit(nonce)) { close(fd); return; }
    ALog(@"🎛 控制通道已连接（AES-CTR 已就绪）");

    BOOL alive = YES;
    while (g_ctrlRun && alive) {
        uint8_t t = 0;
        if (!AXReadDec(fd, &t, 1)) { alive = NO; break; }

        if (t == 0x00) {                       /* 按键 14B */
            uint8_t b[13];
            if (!AXReadDec(fd, b, 13)) { alive = NO; break; }
            if (b[0] == 0) AXCtrlKeycode(AXBE32(b + 1));   /* 只处理按下，避免重复 */
        } else if (t == 0x01) {                /* 文本 5+n */
            uint8_t lb[4];
            if (!AXReadDec(fd, lb, 4)) { alive = NO; break; }
            uint32_t n = AXBE32(lb);
            if (n == 0 || n > 8192) { alive = NO; break; }
            uint8_t *tb = (uint8_t *)malloc(n);
            if (!tb) { alive = NO; break; }
            if (!AXReadDec(fd, tb, n)) { free(tb); alive = NO; break; }
            NSString *str = [[NSString alloc] initWithBytes:tb length:n encoding:NSUTF8StringEncoding];
            free(tb);
            if (str.length) AXAgentTypeText(str);
        } else if (t == 0x02) {                /* 触控 32B */
            uint8_t b[31];
            if (!AXReadDec(fd, b, 31)) { alive = NO; break; }
            AXTouchHandle(b);
        } else if (t == 0x03) {                /* 滚动 21B → 映射成滑动 */
            uint8_t b[20];
            if (!AXReadDec(fd, b, 20)) { alive = NO; break; }
            double x = AXBE32(b + 0), y = AXBE32(b + 4);
            int    w = AXBE16(b + 8), h = AXBE16(b + 10);
            int16_t hs = (int16_t)AXBE16(b + 12);
            int16_t vs = (int16_t)AXBE16(b + 14);
            CGSize pts = [UIScreen mainScreen].bounds.size;
            double px = (w > 0) ? x * pts.width / (double)w : pts.width / 2;
            double py = (h > 0) ? y * pts.height / (double)h : pts.height / 2;
            if (vs != 0) {
                double d = (vs > 0 ? -1.0 : 1.0) * 220.0;   /* 向下滚 → 内容上移 */
                AXAgentSwipe(px, py, px, py + d, 0.25);
            } else if (hs != 0) {
                double d = (hs > 0 ? -1.0 : 1.0) * 220.0;
                AXAgentSwipe(px, py, px + d, py, 0.25);
            }
        } else if (t == 0x04) {                /* backOrScreenOn 2B */
            uint8_t b[1];
            if (!AXReadDec(fd, b, 1)) { alive = NO; break; }
            AXAgentPressHome();
        } else if (t == 0x09) {                /* 剪贴板 14+n */
            uint8_t b[13];
            if (!AXReadDec(fd, b, 13)) { alive = NO; break; }
            BOOL paste = (b[8] != 0);
            uint32_t n = AXBE32(b + 9);
            if (n > (16u << 20)) { alive = NO; break; }
            uint8_t *tb = (uint8_t *)malloc(n ? n : 1);
            if (!tb) { alive = NO; break; }
            if (n && !AXReadDec(fd, tb, n)) { free(tb); alive = NO; break; }
            NSString *str = n ? [[NSString alloc] initWithBytes:tb length:n encoding:NSUTF8StringEncoding] : @"";
            free(tb);
            if (paste) AXAgentPaste(str ?: @"");
            else if (str) AXAgentPasteboardSet(str);
        } else if (t == 0x11) {                /* 重置视频：无 payload（scrcpy 原义） */
            g_force_key = 1;
            ALog(@"🎚 PC 要求重置视频 → 下一帧强制 IDR");
        } else if (t == 0x40) {                /* 13B：fps(4) bitrate(4) maxSide(4)，0=保持 */
            uint8_t b[12];
            if (!AXReadDec(fd, b, 12)) { alive = NO; break; }
            AXApplyVideoParams(AXBE32(b), AXBE32(b + 4), AXBE32(b + 8));
        } else if (t == 0x49) {                /* 上传：4B BE 长度前缀 + payload */
            uint8_t lb[4];
            if (!AXReadDec(fd, lb, 4)) { alive = NO; break; }
            uint32_t n = AXBE32(lb);
            if (n > (8u << 20)) { ALog(@"⚠️ 上传包过大 %u，断开", n); alive = NO; break; }
            if (n && !AXSkipBytes(fd, n)) { alive = NO; break; }
            ALog(@"📁 收到上传包 %u 字节（AXTouch 暂不支持写文件，已跳过）", n);
        } else if (t == 0x10 || t == 0x42 || t == 0x43 || t == 0x44 ||
                   t == 0x45 || t == 0x46 || t == 0x47 || t == 0x48) {
            /* 这一族都是 [type][1B L][L 字节 payload]。必须按 L 吃掉，否则后面全错位
               （PC 连上就会发 0x44 登录，错位会让控制通道立刻失效）。 */
            uint8_t lb[1];
            if (!AXReadDec(fd, lb, 1)) { alive = NO; break; }
            uint32_t n = lb[0];
            if (n && !AXSkipBytes(fd, n)) { alive = NO; break; }
            ALog(@"📨 控制消息 0x%02X（L=%u）AXTouch 未实现，已跳过", t, n);
        } else {
            ALog(@"⚠️ 未知控制消息 0x%02X → 断开（后续字节已无法对齐）", t);
            alive = NO;
        }
    }

    ALog(@"🎛 控制通道断开");
    close(fd);
}

static volatile int g_ctrlClientFd = -1;   /* 当前在服务的控制连接 */

static void *AXCtrlConnThread(void *arg) {
    int fd = (int)(intptr_t)arg;
    AXCtrlHandleClient(fd);                 /* 内部负责 close(fd) */
    if (g_ctrlClientFd == fd) g_ctrlClientFd = -1;
    return NULL;
}

static void *AXCtrlAcceptLoop(void *arg) {
    (void)arg;
    while (g_ctrlRun) {
        struct sockaddr_in ca;
        socklen_t cl = sizeof(ca);
        int fd = accept(g_ctrlListen, (struct sockaddr *)&ca, &cl);
        if (fd < 0) {
            if (!g_ctrlRun) break;
            usleep(50 * 1000);
            continue;
        }
        int one = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        struct timeval tv = {0, 300 * 1000};
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

        /* ★ 新连接顶掉旧连接：PC 每次重连视频（重启服务/切档位/断线）都会新开控制连接。
           以前这里是同步处理，旧连接只要还开着，新连接就永远卡在 TCP backlog 里进不来 ——
           表现就是"PC 上显示已连接、点了完全没反应"。 */
        int oldFd = g_ctrlClientFd;
        if (oldFd >= 0 && oldFd != fd) {
            ALog(@"🎛 新连接顶掉旧连接 fd=%d → %d", oldFd, fd);
            shutdown(oldFd, SHUT_RDWR);
        }
        g_ctrlClientFd = fd;
        pthread_t tid;
        pthread_create(&tid, NULL, AXCtrlConnThread, (void *)(intptr_t)fd);
        pthread_detach(tid);
    }
    return NULL;
}

static BOOL AXCtrlStart(uint16_t port) {
    if (g_ctrlRun) return YES;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { ALog(@"❌ 控制端口 socket 失败"); return NO; }
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_port = htons(port);
    a.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(fd, (struct sockaddr *)&a, sizeof(a)) != 0) {
        ALog(@"❌ 控制端口 %u bind 失败 errno=%d", port, errno);
        close(fd);
        return NO;
    }
    if (listen(fd, 4) != 0) {
        ALog(@"❌ 控制端口 listen 失败 errno=%d", errno);
        close(fd);
        return NO;
    }
    g_ctrlListen = fd;
    g_ctrlRun = 1;
    pthread_t tid;
    pthread_create(&tid, NULL, AXCtrlAcceptLoop, NULL);
    pthread_detach(tid);
    ALog(@"✅ 控制通道已在 0.0.0.0:%u 监听", port);
    return YES;
}

static void AXCtrlStop(void) {
    if (!g_ctrlRun) return;
    g_ctrlRun = 0;
    if (g_ctrlListen >= 0) { close(g_ctrlListen); g_ctrlListen = -1; }
    ALog(@"🛑 控制通道已停止");
}

BOOL AXStreamStart(uint16_t port) {
    if (g_running) return YES;
    AXLoadStoredUDIDIfNeeded();   /* ★ 用上次保存的真 UDID，别再用假 ID */

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

    /* ★ 关键：PC 端断开后继续 send() 会触发 SIGPIPE，iOS 默认直接杀进程。
       「电脑一打开手机就闪退」的根因就是它 —— 忽略掉，send 返回 EPIPE 走正常断开分支 */
    signal(SIGPIPE, SIG_IGN);

    g_running = YES;
    g_ptsMs = 0;
    g_preambleSent = 0;
    g_sentFrames = 0;
    g_encW = g_encH = 0;

    AXInstallLifecycleLog();
    AXStartKeepAlive();   /* 后台保活（音频/定位/蓝牙） */
    AXCtrlStart(27185);   /* 控制通道：PC 的点击/滑动/缩放/键盘/粘贴走这里 */
    g_scheme = g_profileCapture;        /* 采集方式由档位决定，起流时生效 */
    g_rkFallback = 0;
    pthread_create(&g_acceptTid, NULL, AXAcceptLoop, NULL);
    if (g_scheme == 1) {
        ALogShim(@"🎥 采集方案：ReplayKit");
        AXReplayKitStart();      /* 失败会自动把 g_scheme 置 0（回退 XCUITest） */
    } else {
        ALogShim(@"🎥 采集方案：XCUITest 截图");
    }
    pthread_create(&g_encTid, NULL, AXEncodeLoop, NULL);
    ALogShim(@"✅ 推流服务已在 0.0.0.0:%d 监听", port);
    return YES;
}

void AXStreamStop(void) {
    if (!g_running) return;
    g_running = NO;
    AXCtrlStop();
    AXReplayKitStopInternal();   /* 采集中就停掉，避免红条常驻 */
    AXStopKeepAlive();

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

/* ★ 设置真 UDID：普通 App 拿不到，由 PC 端经 10010 传进来。
   preamble 里必须发真 UDID，否则 PC 端把流当成一台独立的"新设备"，
   既关联不到 usbmux 里的真机，还会多出一台重复设备。 */
/* ===== 设备 UDID 持久化（用户手填 / PC 下发都走这里）=====
   为什么存 Keychain：普通 App 拿不到真 UDID（lockdown 在沙盒里 EPERM、MobileGestalt 全 NULL、
   XCTest 的 uniqueIdentifier 是会话级的每次启动都变），所以只能由人来提供一次。
   Keychain 在卸载重装后仍然存在，Sideloadly 7 天重签也不用重新输入。 */
static NSString *const kAXUDIDKey = @"axtouch.device.udid";
static volatile int g_udidUserSet = 0;   /* 置位后人手填的值优先，不再被 devinfo 覆盖 */

static NSString *AXStoredUDID(void) {
    NSString *v = nil;
    NSDictionary *q = @{ (__bridge id)kSecClass:       (__bridge id)kSecClassGenericPassword,
                         (__bridge id)kSecAttrService: @"axtouch",
                         (__bridge id)kSecAttrAccount: kAXUDIDKey,
                         (__bridge id)kSecReturnData:  @YES,
                         (__bridge id)kSecMatchLimit:  (__bridge id)kSecMatchLimitOne };
    CFTypeRef out = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)q, &out) == errSecSuccess && out) {
        NSData *d = (__bridge_transfer NSData *)out;
        if (d.length) v = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    }
    if (v.length == 0) v = [[NSUserDefaults standardUserDefaults] stringForKey:kAXUDIDKey];
    return v.length ? v : nil;
}

static void AXStoreUDID(NSString *v) {
    NSDictionary *base = @{ (__bridge id)kSecClass:       (__bridge id)kSecClassGenericPassword,
                            (__bridge id)kSecAttrService: @"axtouch",
                            (__bridge id)kSecAttrAccount: kAXUDIDKey };
    SecItemDelete((__bridge CFDictionaryRef)base);
    NSMutableDictionary *add = [base mutableCopy];
    add[(__bridge id)kSecValueData]      = [v dataUsingEncoding:NSUTF8StringEncoding];
    add[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlock;
    OSStatus st = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
    [[NSUserDefaults standardUserDefaults] setObject:v forKey:kAXUDIDKey];
    ALogShim(@"💾 UDID 已存储 (keychain=%d)", (int)st);
}

/* 内部：真正写进 g_udid */
static void AXApplyUDID(NSString *udid) {
    if (udid.length == 0 || udid.length >= sizeof(g_udid)) return;
    memset(g_udid, 0, sizeof(g_udid));
    memcpy(g_udid, udid.UTF8String, udid.length);
}

/* 给 devinfo / 10010 用：人手填过就不覆盖（人手填的才是权威） */
void AXStreamSetUDID(NSString *udid) {
    if (g_udidUserSet) {
        ALogShim(@"📺 UDID 已由用户指定，忽略自动探测值 %@", udid);
        return;
    }
    AXApplyUDID(udid);
    ALogShim(@"📺 已设置设备 UDID = %s（自动来源）", g_udid);
}

/* 用户手填 / PC 下发：写入并持久化，此后一律用它 */
void AXStreamSetUDIDPersist(NSString *udid) {
    NSString *t = [udid stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (t.length == 0) return;
    AXApplyUDID(t);
    AXStoreUDID(t);
    g_udidUserSet = 1;
    ALogShim(@"📺 已设置设备 UDID = %s（用户指定，已持久化）", g_udid);
}

/* 当前生效的 UDID（界面显示用）*/
NSString *AXStreamCurrentUDID(void) {
    return g_udid[0] ? @(g_udid) : @"";
}

/* 启动时载入上次存的（没有就用 identifierForVendor 兜底）*/
static void AXLoadStoredUDIDIfNeeded(void) {
    if (g_udid[0]) return;
    NSString *v = AXStoredUDID();
    if (v.length) {
        AXApplyUDID(v);
        g_udidUserSet = 1;
        ALogShim(@"📺 已载入上次保存的设备 UDID = %s", g_udid);
    }
}

void AXStreamSetStaticDrop(int on) {
    g_staticDrop = (on == 1) ? 1 : 0;
    ALogShim(@"❄️ 静止自动降帧 = %@", g_staticDrop ? @"开" : @"关");
}

void AXStreamSetDecodeMode(int thumb) {
    g_decodeThumb = (thumb == 1) ? 1 : 0;
    ALogShim(@"🧩 解码路径 = %@", g_decodeThumb ? @"ImageIO thumbnail" : @"全解+CGContext");
}

void AXStreamSetImgFormat(NSString *uti) {
    if (uti.length == 0 || uti.length >= sizeof(g_imgUTI)) return;
    memset(g_imgUTI, 0, sizeof(g_imgUTI));
    memcpy(g_imgUTI, uti.UTF8String, uti.length);
    ALogShim(@"🖼 截图格式改为 %s（下次采集生效）", g_imgUTI);
}

void AXStreamSetImgQuality(double q) {
    if (q <= 0) q = 1.0;
    if (q > 1.0) q = 1.0;
    g_imgQuality = q;
    ALogShim(@"🖼 截图质量参数 imgQuality=%.2f（下次采集生效）", q);
}

void AXStreamSetParams(int bitrateBps, int fps, int maxSide) {
    /* 统一走 AXApplyVideoParams：码率/帧率能直接在现有会话上生效，
       只有分辨率变化才需要重建编码会话（不再什么都不问就丢会话）。 */
    AXApplyVideoParams((uint32_t)(fps > 0 ? fps : 0),
                       (uint32_t)(bitrateBps > 0 ? bitrateBps : 0),
                       (uint32_t)(maxSide > 0 ? maxSide : 0));
}

NSDictionary *AXStreamStats(void) {
    return @{
        @"running": @(g_running),
        @"clients": @(g_clientCount),
        @"sent": @(g_sentFrames),
        @"fps": @(g_fps),
        @"kbps": @(g_bitrate / 1000),
        @"maxSide": @(g_maxSide),
        @"w": @(g_encW),
        @"h": @(g_encH),
        @"bitrate": @(g_bitrate),
        @"err": @(g_lastErr),
        @"errMsg": g_lastErrMsg ?: @"",
    };
}
