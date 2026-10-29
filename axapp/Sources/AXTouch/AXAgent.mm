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
