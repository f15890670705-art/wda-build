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
#import "AXStream.h"
#import <sys/time.h>
#import <string.h>
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

static void ALog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[AXAgent] %@", s);

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [df stringFromDate:[NSDate date]], s];

    NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSString *path = AXLogPath();
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) {
        [d writeToFile:path atomically:YES];
        return;
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (fh) {
        @try { [fh seekToEndOfFile]; [fh writeData:d]; }
        @catch (NSException *e) { }
        [fh closeFile];
    }
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

extern "C" BOOL AXAgentTap(double x, double y) {
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
        fp4(gSession, syn, rec, completion);
        [NSThread sleepForTimeInterval:0.4];
        ALog(@"  ✅ tap(%.1f, %.1f) 已提交合成事件", x, y);
        return YES;
    } @catch (NSException *e) {
        ALog(@"❌ tap 异常: %@ / %@", e.name, e.reason);
        return NO;
    }
}

/// 在永不退出、且不 pop autorelease pool 的线程里跑 bootstrap：
/// XCTest 内部创建的 XPC 连接不会被释放，避免 _xpc_api_misuse 崩溃。
extern "C" void AXAgentStartSticky(void) {
    NSThread *t = [[NSThread alloc] initWithBlock:^{
        ALog(@"常驻线程启动，开始 bootstrap");
        AXAgentBootstrap();
        while (YES) { [NSThread sleepForTimeInterval:86400.0]; }
    }];
    t.name = @"AXAgent-Sticky";
    [t start];
}


#pragma mark - 5. 手势（swipe / longpress / 任意轨迹）

/// xy: [x0,y0, x1,y1, ...]  t: 每个点的时间偏移(秒)，最后一个点是 liftUp
extern "C" BOOL AXAgentGesture(const double *xy, const double *t, int n) {
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
        [NSThread sleepForTimeInterval:0.25];
        ALog(@"  ✅ gesture 已提交（%d 点，末点 %.2fs）", n, t[n-1]);
        return YES;
    } @catch (NSException *e) {
        ALog(@"❌ gesture 异常: %@ / %@", e.name, e.reason);
        return NO;
    }
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
