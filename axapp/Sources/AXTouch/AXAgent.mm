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
#import <dlfcn.h>
#import <unistd.h>
#import <stdarg.h>

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

#pragma mark - 动态调用小工具

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
                    void (^reply)(id) = ^(id err) {
                        ALog(@"  📥 requestAutomationSession reply: %@", err ?: @"(nil)");
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
                    void (^reply)(id) = ^(id a) { ALog(@"  📥 backgroundAssertion reply: %@", a ?: @"(nil)"); };
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

        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        __block NSString *replyDesc = @"(无 reply)";
        SEL syn = NSSelectorFromString(@"synthesizeEvent:completion:");
        if (![gSession respondsToSelector:syn]) {
            ALog(@"❌ tap：daemonSession 无 synthesizeEvent:completion:");
            return NO;
        }
        void (*fp4)(id, SEL, id, id) = (void (*)(id, SEL, id, id))objc_msgSend;
        fp4(gSession, syn, rec, ^(NSError *err) {
            replyDesc = err ? err.localizedDescription : @"(成功)";
            dispatch_semaphore_signal(sem);
        });
        long waited = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
        ALog(@"  tap(%.1f, %.1f) -> reply=%@ timeout=%@", x, y, replyDesc, waited ? @"YES" : @"NO");
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
