//
//  AXMainViewController.m
//  AXTouch 主界面
//  ★ 布局/配色/组件照 ios-daemon 的 ServiceManagerViewController（卡片式 UI），
//    内容换成 AXTouch 自己的：会话状态 / 设备信息 / 画面测试 / 控制 / 诊断。
//
#import "AXMainViewController.h"
#import "AXLogViewerViewController.h"
#import "AXStream.h"
#import "UITheme.h"
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <net/if.h>
#import <string.h>

/* AXAgent.mm 的 C 接口（与 Bridging-Header.h 保持一致；ObjC 文件不共享桥接头） */
extern BOOL AXAgentIsReady(void);
extern NSString *AXAgentLastError(void);
extern NSString *AXAgentLogPath(void);
extern void AXAgentStartSticky(void);
extern BOOL AXAgentIsBootstrapping(void);
extern NSString *AXAgentShot(double maxSide, double quality);
extern NSString *AXAgentProbeRecording(void);
extern NSString *AXAgentDumpTree(int maxNodes);
extern void AXLoadXCTestThread(void);
extern void AXStartWDAServerThread(NSString **outLog);
extern NSString *AXProbeDaemonSession(void);
extern NSString *AXTestLocalSocket(void);
extern NSString *AXTestLockdownTCP(void);
extern NSString *AXScanLoopbackPorts(void);
extern NSString *AXBootstrapProbe(void);

#pragma mark - 本机信息小工具

/* 版本 tag：与 Info.plist 的 CFBundleShortVersionString / CFBundleVersion 一致 */
static NSString *AXBuildTag(void) {
    static NSString *v = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *b = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"?";
        NSString *s = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
        v = [NSString stringWithFormat:@"v%@-b%@", s, b];
    });
    return v;
}

static NSString *const kAXSchemeKey = @"axtouch.stream.scheme";   /* 0=XCUITest 1=ReplayKit */

static NSString *AXLanIP(void) {
    struct ifaddrs *addrs = NULL;
    NSString *result = @"未知";
    if (getifaddrs(&addrs) == 0) {
        for (struct ifaddrs *a = addrs; a; a = a->ifa_next) {
            if (!a->ifa_addr || a->ifa_addr->sa_family != AF_INET) continue;
            if (strcmp(a->ifa_name, "en0") != 0) continue;
            char buf[INET_ADDRSTRLEN] = {0};
            struct sockaddr_in *sin = (struct sockaddr_in *)a->ifa_addr;
            if (inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof(buf))) {
                result = [NSString stringWithUTF8String:buf];
            }
        }
        freeifaddrs(addrs);
    }
    return result;
}

#pragma mark - 小工具类

@interface AXChipBadge : UILabel
+ (instancetype)badgeWithText:(NSString *)t fg:(UIColor *)fg bg:(UIColor *)bg;
@end
@implementation AXChipBadge
+ (instancetype)badgeWithText:(NSString *)t fg:(UIColor *)fg bg:(UIColor *)bg {
    UILabel *l = [UILabel new];
    l.text = t;
    l.textColor = fg;
    l.backgroundColor = bg;
    l.textAlignment = NSTextAlignmentCenter;
    l.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    l.layer.cornerRadius = 6;
    l.layer.masksToBounds = YES;
    l.translatesAutoresizingMaskIntoConstraints = NO;
    return l;
}
@end

@interface AXCardView : UIView
+ (instancetype)card;
@end
@implementation AXCardView
+ (instancetype)card {
    UIView *v = [UIView new];
    v.backgroundColor = ATCard();
    v.layer.cornerRadius = AT_CARD_RADIUS;
    /* ★ b43：去掉了 shadowRadius=8 的实时阴影。
       实测 XCUIScreen 截图在带阴影的卡片界面上要 203ms，在无阴影的旧界面上只要 105ms
       —— 阴影每次抓图都要重新做离屏合成。改用 1px 细线描边，视觉几乎一样，合成便宜。 */
    v.layer.borderWidth = 1.0 / [UIScreen mainScreen].scale;
    v.layer.borderColor = ATDivider().CGColor;
    v.translatesAutoresizingMaskIntoConstraints = NO;
    return v;
}
@end

@interface AXInfoRow : UIView
@property (nonatomic, strong) UILabel *keyLabel;
@property (nonatomic, strong) UILabel *valueLabel;
- (instancetype)initWithKey:(NSString *)key;
@end
@implementation AXInfoRow
- (instancetype)initWithKey:(NSString *)key {
    if ((self = [super initWithFrame:CGRectZero])) {
        self.translatesAutoresizingMaskIntoConstraints = NO;

        _keyLabel = [UILabel new];
        _keyLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _keyLabel.text = key;
        _keyLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
        _keyLabel.textColor = ATSubText();
        [self addSubview:_keyLabel];

        _valueLabel = [UILabel new];
        _valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _valueLabel.text = @"-";
        _valueLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        _valueLabel.textColor = ATText();
        _valueLabel.adjustsFontSizeToFitWidth = YES;
        _valueLabel.minimumScaleFactor = 0.7;
        [self addSubview:_valueLabel];

        [NSLayoutConstraint activateConstraints:@[
            [_keyLabel.topAnchor      constraintEqualToAnchor:self.topAnchor],
            [_keyLabel.leadingAnchor  constraintEqualToAnchor:self.leadingAnchor],
            [_keyLabel.bottomAnchor   constraintEqualToAnchor:self.bottomAnchor],
            [_keyLabel.widthAnchor    constraintEqualToConstant:84],

            [_valueLabel.topAnchor    constraintEqualToAnchor:self.topAnchor],
            [_valueLabel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [_valueLabel.leadingAnchor  constraintEqualToAnchor:_keyLabel.trailingAnchor constant:8],
            [_valueLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        ]];
    }
    return self;
}
@end

#pragma mark - AXMainViewController

@interface AXMainViewController ()
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UIView *content;
@property (nonatomic, strong) UILabel *titleLabel;

@property (nonatomic, strong) AXCardView *cardStatus;
@property (nonatomic, strong) AXCardView *cardDevice;
@property (nonatomic, strong) AXCardView *cardFrame;
@property (nonatomic, strong) AXCardView *cardControl;
@property (nonatomic, strong) AXCardView *cardDiag;

@property (nonatomic, strong) UIView   *statusDot;
@property (nonatomic, strong) UILabel  *statusText;
@property (nonatomic, strong) UILabel  *versionText;
@property (nonatomic, strong) UILabel  *errorText;
@property (nonatomic, strong) UILabel  *ipText;
@property (nonatomic, strong) UIButton *refreshBtn;

@property (nonatomic, strong) AXInfoRow *devName;
@property (nonatomic, strong) AXInfoRow *devOS;
@property (nonatomic, strong) AXInfoRow *devScreen;
@property (nonatomic, strong) AXInfoRow *devUDID;

@property (nonatomic, strong) UIImageView *preview;
@property (nonatomic, strong) UILabel     *frameStat;
@property (nonatomic, strong) UIButton    *shotBtn;
@property (nonatomic, strong) UIButton    *burstBtn;

@property (nonatomic, strong) UIButton *schemeBtn;
/* ★ 2026-11-01 发烫定位：分段跑下拉框（0 正常 / 1 只截图 / 2 截图+缩放 / 3 只编码 / 4 空转） */
@property (nonatomic, strong) UIButton *benchBtn;
@property (nonatomic, assign) NSInteger benchSel;
@property (nonatomic, strong) UIButton *rebuildBtn;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, assign) BOOL burstRunning;

/* 构建与回调（同 @implementation 内的私有方法，先声明避免 "may not respond" 警告） */
- (void)buildUI;
- (void)buildCardStatus;
- (void)buildCardDevice;
- (void)buildCardFrame;
- (void)buildCardControl;
- (void)buildCardDiag;
- (UIStackView *)stackWith:(NSArray<UIView *> *)views;
- (UIButton *)buildBigButton:(NSString *)title bg:(UIColor *)bg fg:(UIColor *)fg;
- (UIButton *)buildDiagButton:(NSString *)title index:(NSInteger)idx;
- (void)refreshAll;
- (void)didTapRefresh;
- (void)didTapRebuild;
- (void)didTapRestartStream;
- (void)didTapLogs;
- (void)didTapTree;
- (void)didTapServer;
- (void)refreshSchemeButton;
- (void)selectScheme:(NSInteger)i;
- (void)refreshBenchButton;
- (void)selectBench:(NSInteger)m;
- (void)autoStartStreamIfNeeded;
- (void)didTapEditUDID;
- (void)didTapShot;
- (void)didTapBurst;
- (void)didTapDiag:(UIButton *)sender;
@end

@implementation AXMainViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = ATBg();
    [self buildUI];
    [self refreshAll];

    self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                  target:self
                                                selector:@selector(refreshAll)
                                                userInfo:nil
                                                 repeats:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.timer invalidate];
    self.timer = nil;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (!self.timer) {
        self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                      target:self
                                                    selector:@selector(refreshAll)
                                                    userInfo:nil
                                                     repeats:YES];
    }
    [self refreshAll];
}

#pragma mark - 构建 UI

- (void)buildUI {
    self.scroll = [UIScrollView new];
    self.scroll.translatesAutoresizingMaskIntoConstraints = NO;
    self.scroll.showsVerticalScrollIndicator = NO;
    self.scroll.alwaysBounceVertical = YES;
    [self.view addSubview:self.scroll];

    self.content = [UIView new];
    self.content.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scroll addSubview:self.content];

    self.titleLabel = [UILabel new];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.text = @"AXTouch";
    self.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    self.titleLabel.textColor = ATText();
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    [self.content addSubview:self.titleLabel];

    self.cardStatus  = [AXCardView card];
    self.cardDevice  = [AXCardView card];
    self.cardControl = [AXCardView card];
    [self.content addSubview:self.cardStatus];
    [self.content addSubview:self.cardDevice];
    [self.content addSubview:self.cardControl];

    [self buildCardStatus];
    [self buildCardDevice];
    [self buildCardControl];
    /* 2026-10-30 用户要求下架：画面测试卡（抓帧/连拍）与诊断卡不再显示。
       实现代码保留在 buildCardFrame / buildCardDiag 里，需要时把上面几行加回来即可。 */

    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.scroll.topAnchor      constraintEqualToAnchor:g.topAnchor],
        [self.scroll.bottomAnchor   constraintEqualToAnchor:g.bottomAnchor],
        [self.scroll.leadingAnchor  constraintEqualToAnchor:g.leadingAnchor],
        [self.scroll.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],

        [self.content.topAnchor      constraintEqualToAnchor:self.scroll.topAnchor],
        [self.content.bottomAnchor   constraintEqualToAnchor:self.scroll.bottomAnchor],
        [self.content.leadingAnchor  constraintEqualToAnchor:self.scroll.leadingAnchor],
        [self.content.trailingAnchor constraintEqualToAnchor:self.scroll.trailingAnchor],
        [self.content.widthAnchor    constraintEqualToAnchor:self.scroll.widthAnchor],

        [self.titleLabel.topAnchor      constraintEqualToAnchor:self.content.topAnchor constant:12],
        [self.titleLabel.leadingAnchor  constraintEqualToAnchor:self.content.leadingAnchor],
        [self.titleLabel.trailingAnchor constraintEqualToAnchor:self.content.trailingAnchor],

        [self.cardStatus.topAnchor      constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:12],
        [self.cardStatus.leadingAnchor  constraintEqualToAnchor:self.content.leadingAnchor constant:AT_PAD],
        [self.cardStatus.trailingAnchor constraintEqualToAnchor:self.content.trailingAnchor constant:-AT_PAD],

        [self.cardDevice.topAnchor      constraintEqualToAnchor:self.cardStatus.bottomAnchor constant:12],
        [self.cardDevice.leadingAnchor  constraintEqualToAnchor:self.content.leadingAnchor constant:AT_PAD],
        [self.cardDevice.trailingAnchor constraintEqualToAnchor:self.content.trailingAnchor constant:-AT_PAD],

        [self.cardControl.topAnchor      constraintEqualToAnchor:self.cardDevice.bottomAnchor constant:12],
        [self.cardControl.leadingAnchor  constraintEqualToAnchor:self.content.leadingAnchor constant:AT_PAD],
        [self.cardControl.trailingAnchor constraintEqualToAnchor:self.content.trailingAnchor constant:-AT_PAD],
        [self.cardControl.bottomAnchor   constraintEqualToAnchor:self.content.bottomAnchor constant:-24],
    ]];
}

- (void)buildCardStatus {
    AXChipBadge *badge = [AXChipBadge badgeWithText:@"  会话状态  " fg:ATPurple() bg:ATPurpleBg()];
    [self.cardStatus addSubview:badge];

    self.statusDot = [UIView new];
    self.statusDot.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusDot.backgroundColor = ATGreen();
    self.statusDot.layer.cornerRadius = 5;
    [self.cardStatus addSubview:self.statusDot];

    self.statusText = [UILabel new];
    self.statusText.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusText.text = @"AGENT READY";
    self.statusText.textColor = ATGreen();
    self.statusText.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    [self.cardStatus addSubview:self.statusText];

    self.versionText = [UILabel new];
    self.versionText.translatesAutoresizingMaskIntoConstraints = NO;
    self.versionText.textColor = ATSubText();
    self.versionText.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    [self.cardStatus addSubview:self.versionText];

    self.errorText = [UILabel new];
    self.errorText.translatesAutoresizingMaskIntoConstraints = NO;
    self.errorText.textColor = ATRed();
    self.errorText.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    self.errorText.numberOfLines = 0;
    self.errorText.hidden = YES;
    [self.cardStatus addSubview:self.errorText];

    UIView *line = [UIView new];
    line.translatesAutoresizingMaskIntoConstraints = NO;
    line.backgroundColor = ATDivider();
    [self.cardStatus addSubview:line];

    UILabel *ipLabel = [UILabel new];
    ipLabel.translatesAutoresizingMaskIntoConstraints = NO;
    ipLabel.text = @"本机 IP";
    ipLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
    ipLabel.textColor = ATSubText();
    [self.cardStatus addSubview:ipLabel];

    self.ipText = [UILabel new];
    self.ipText.translatesAutoresizingMaskIntoConstraints = NO;
    self.ipText.text = @"-";
    self.ipText.textColor = ATText();
    self.ipText.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [self.cardStatus addSubview:self.ipText];

    self.refreshBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.refreshBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [self.refreshBtn setTitle:@"刷新" forState:UIControlStateNormal];
    [self.refreshBtn setTitleColor:ATBlue() forState:UIControlStateNormal];
    self.refreshBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    self.refreshBtn.backgroundColor = [UIColor whiteColor];
    self.refreshBtn.contentEdgeInsets = UIEdgeInsetsMake(6, 14, 6, 14);
    self.refreshBtn.layer.cornerRadius = 16;
    self.refreshBtn.layer.borderColor = ATBlue().CGColor;
    self.refreshBtn.layer.borderWidth = 1.2;
    self.refreshBtn.layer.masksToBounds = YES;
    [self.refreshBtn addTarget:self action:@selector(didTapRefresh) forControlEvents:UIControlEventTouchUpInside];
    [self.cardStatus addSubview:self.refreshBtn];

    [NSLayoutConstraint activateConstraints:@[
        [badge.topAnchor     constraintEqualToAnchor:self.cardStatus.topAnchor constant:16],
        [badge.leadingAnchor constraintEqualToAnchor:self.cardStatus.leadingAnchor constant:16],
        [badge.heightAnchor  constraintEqualToConstant:26],

        [self.statusDot.widthAnchor  constraintEqualToConstant:10],
        [self.statusDot.heightAnchor constraintEqualToConstant:10],
        [self.statusDot.topAnchor    constraintEqualToAnchor:badge.bottomAnchor constant:14],
        [self.statusDot.leadingAnchor constraintEqualToAnchor:self.cardStatus.leadingAnchor constant:18],

        [self.statusText.leadingAnchor constraintEqualToAnchor:self.statusDot.trailingAnchor constant:8],
        [self.statusText.centerYAnchor constraintEqualToAnchor:self.statusDot.centerYAnchor],

        [self.versionText.topAnchor     constraintEqualToAnchor:self.statusDot.bottomAnchor constant:6],
        [self.versionText.leadingAnchor constraintEqualToAnchor:self.statusDot.leadingAnchor],

        [self.errorText.topAnchor     constraintEqualToAnchor:self.versionText.bottomAnchor constant:6],
        [self.errorText.leadingAnchor constraintEqualToAnchor:self.statusDot.leadingAnchor],
        [self.errorText.trailingAnchor constraintEqualToAnchor:self.cardStatus.trailingAnchor constant:-16],

        [line.topAnchor      constraintEqualToAnchor:self.errorText.bottomAnchor constant:14],
        [line.leadingAnchor  constraintEqualToAnchor:self.cardStatus.leadingAnchor constant:16],
        [line.trailingAnchor constraintEqualToAnchor:self.cardStatus.trailingAnchor constant:-16],
        [line.heightAnchor   constraintEqualToConstant:1],

        [ipLabel.topAnchor     constraintEqualToAnchor:line.bottomAnchor constant:14],
        [ipLabel.leadingAnchor constraintEqualToAnchor:self.cardStatus.leadingAnchor constant:16],
        [ipLabel.widthAnchor   constraintEqualToConstant:84],

        [self.ipText.centerYAnchor constraintEqualToAnchor:ipLabel.centerYAnchor],
        [self.ipText.leadingAnchor constraintEqualToAnchor:ipLabel.trailingAnchor constant:8],
        [self.ipText.trailingAnchor constraintLessThanOrEqualToAnchor:self.refreshBtn.leadingAnchor constant:-8],

        [self.refreshBtn.centerYAnchor constraintEqualToAnchor:ipLabel.centerYAnchor],
        [self.refreshBtn.trailingAnchor constraintEqualToAnchor:self.cardStatus.trailingAnchor constant:-16],
        [self.refreshBtn.bottomAnchor constraintEqualToAnchor:self.cardStatus.bottomAnchor constant:-16],
    ]];
}

- (void)buildCardDevice {
    AXChipBadge *badge = [AXChipBadge badgeWithText:@"  设备信息  " fg:ATGreen() bg:ATGreenBg()];
    [self.cardDevice addSubview:badge];

    self.devName   = [[AXInfoRow alloc] initWithKey:@"设备名称"];
    self.devOS     = [[AXInfoRow alloc] initWithKey:@"系统版本"];
    self.devScreen = [[AXInfoRow alloc] initWithKey:@"屏幕像素"];
    // ★ 设备 ID：普通 App 拿不到真 UDID，由人填一次（存 Keychain，重装仍在）。
    //   preamble 里带着它，PC 才能把 USB 与无线认成同一台。
    self.devUDID   = [[AXInfoRow alloc] initWithKey:@"设备 ID"];
    self.devUDID.valueLabel.text = @"点此输入";
    self.devUDID.userInteractionEnabled = YES;
    [self.devUDID addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(didTapEditUDID)]];
    [self.cardDevice addSubview:self.devName];
    [self.cardDevice addSubview:self.devOS];
    [self.cardDevice addSubview:self.devScreen];
    [self.cardDevice addSubview:self.devUDID];

    [NSLayoutConstraint activateConstraints:@[
        [badge.topAnchor     constraintEqualToAnchor:self.cardDevice.topAnchor constant:16],
        [badge.leadingAnchor constraintEqualToAnchor:self.cardDevice.leadingAnchor constant:16],
        [badge.heightAnchor  constraintEqualToConstant:26],

        [self.devName.topAnchor       constraintEqualToAnchor:badge.bottomAnchor constant:14],
        [self.devName.leadingAnchor   constraintEqualToAnchor:self.cardDevice.leadingAnchor constant:16],
        [self.devName.trailingAnchor  constraintEqualToAnchor:self.cardDevice.trailingAnchor constant:-16],
        [self.devName.heightAnchor    constraintEqualToConstant:24],

        [self.devOS.topAnchor         constraintEqualToAnchor:self.devName.bottomAnchor constant:10],
        [self.devOS.leadingAnchor     constraintEqualToAnchor:self.cardDevice.leadingAnchor constant:16],
        [self.devOS.trailingAnchor    constraintEqualToAnchor:self.cardDevice.trailingAnchor constant:-16],
        [self.devOS.heightAnchor      constraintEqualToConstant:24],

        [self.devScreen.topAnchor     constraintEqualToAnchor:self.devOS.bottomAnchor constant:10],
        [self.devScreen.leadingAnchor constraintEqualToAnchor:self.cardDevice.leadingAnchor constant:16],
        [self.devScreen.trailingAnchor constraintEqualToAnchor:self.cardDevice.trailingAnchor constant:-16],
        [self.devScreen.heightAnchor  constraintEqualToConstant:24],

        [self.devUDID.topAnchor       constraintEqualToAnchor:self.devScreen.bottomAnchor constant:10],
        [self.devUDID.leadingAnchor   constraintEqualToAnchor:self.cardDevice.leadingAnchor constant:16],
        [self.devUDID.trailingAnchor  constraintEqualToAnchor:self.cardDevice.trailingAnchor constant:-16],
        [self.devUDID.heightAnchor    constraintEqualToConstant:24],
        [self.devUDID.bottomAnchor    constraintEqualToAnchor:self.cardDevice.bottomAnchor constant:-16],
    ]];
}

- (void)buildCardFrame {
    AXChipBadge *badge = [AXChipBadge badgeWithText:@"  画面测试  " fg:ATBlue() bg:ATBlueBg()];
    [self.cardFrame addSubview:badge];

    self.preview = [UIImageView new];
    self.preview.translatesAutoresizingMaskIntoConstraints = NO;
    self.preview.backgroundColor = [UIColor colorWithWhite:0.10 alpha:1.0];
    self.preview.contentMode = UIViewContentModeScaleAspectFit;
    self.preview.layer.cornerRadius = 10;
    self.preview.layer.masksToBounds = YES;
    [self.cardFrame addSubview:self.preview];

    self.frameStat = [UILabel new];
    self.frameStat.translatesAutoresizingMaskIntoConstraints = NO;
    self.frameStat.text = @"尚未抓帧";
    self.frameStat.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.frameStat.textColor = ATSubText();
    self.frameStat.numberOfLines = 2;
    [self.cardFrame addSubview:self.frameStat];

    self.shotBtn = [self buildBigButton:@"抓一帧" bg:ATBlue() fg:[UIColor whiteColor]];
    [self.shotBtn addTarget:self action:@selector(didTapShot) forControlEvents:UIControlEventTouchUpInside];

    self.burstBtn = [self buildBigButton:@"连拍 30 帧" bg:ATBlueBg() fg:ATBlue()];
    [self.burstBtn addTarget:self action:@selector(didTapBurst) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *row = [UIStackView new];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.axis = UILayoutConstraintAxisHorizontal;
    row.distribution = UIStackViewDistributionFillEqually;
    row.alignment = UIStackViewAlignmentFill;
    row.spacing = 12;
    [row addArrangedSubview:self.shotBtn];
    [row addArrangedSubview:self.burstBtn];
    [self.cardFrame addSubview:row];

    [NSLayoutConstraint activateConstraints:@[
        [badge.topAnchor     constraintEqualToAnchor:self.cardFrame.topAnchor constant:16],
        [badge.leadingAnchor constraintEqualToAnchor:self.cardFrame.leadingAnchor constant:16],
        [badge.heightAnchor  constraintEqualToConstant:26],

        [self.preview.topAnchor      constraintEqualToAnchor:badge.bottomAnchor constant:14],
        [self.preview.leadingAnchor  constraintEqualToAnchor:self.cardFrame.leadingAnchor constant:16],
        [self.preview.trailingAnchor constraintEqualToAnchor:self.cardFrame.trailingAnchor constant:-16],
        [self.preview.heightAnchor   constraintEqualToConstant:200],

        [self.frameStat.topAnchor     constraintEqualToAnchor:self.preview.bottomAnchor constant:10],
        [self.frameStat.leadingAnchor constraintEqualToAnchor:self.cardFrame.leadingAnchor constant:16],
        [self.frameStat.trailingAnchor constraintEqualToAnchor:self.cardFrame.trailingAnchor constant:-16],

        [row.topAnchor      constraintEqualToAnchor:self.frameStat.bottomAnchor constant:12],
        [row.leadingAnchor  constraintEqualToAnchor:self.cardFrame.leadingAnchor constant:16],
        [row.trailingAnchor constraintEqualToAnchor:self.cardFrame.trailingAnchor constant:-16],
        [row.heightAnchor   constraintEqualToConstant:44],
        [row.bottomAnchor   constraintEqualToAnchor:self.cardFrame.bottomAnchor constant:-16],
    ]];
}

- (void)buildCardControl {
    AXChipBadge *badge = [AXChipBadge badgeWithText:@"  控制  " fg:ATPurple() bg:ATPurpleBg()];
    [self.cardControl addSubview:badge];

    /* 2026-10-30 用户要求：会话是启动时自动建的，「重建会话」没意义 →
       改成「重启服务」＝把投屏服务（27184 监听 + 编码器）停掉再起来。 */
    self.rebuildBtn = [self buildBigButton:@"重启服务" bg:ATPurple() fg:[UIColor whiteColor]];
    [self.rebuildBtn addTarget:self action:@selector(didTapRestartStream) forControlEvents:UIControlEventTouchUpInside];

    UIButton *logs = [self buildBigButton:@"📄  运行日志" bg:ATGreen() fg:[UIColor whiteColor]];
    [logs addTarget:self action:@selector(didTapLogs) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *row1 = [self stackWith:@[self.rebuildBtn, logs]];
    [self.cardControl addSubview:row1];

    /* 投屏方案：默认 XCUITest（当前方案），可切 ReplayKit。
       选择存 NSUserDefaults，下次启动沿用；切换时立刻停掉旧方案再起新的。 */
    UILabel *schemeLabel = [UILabel new];
    schemeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    schemeLabel.text = @"投屏方案";
    schemeLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    schemeLabel.textColor = ATSubText();
    [self.cardControl addSubview:schemeLabel];

    /* 下拉框（不是分段控件）：点开弹出菜单选方案。切换只存选择，
       要生效点「重启服务」——避免误触把正在投的画面断掉。 */
    self.schemeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.schemeBtn.translatesAutoresizingMaskIntoConstraints = NO;
    self.schemeBtn.backgroundColor = ATCard();
    self.schemeBtn.layer.cornerRadius = 10;
    self.schemeBtn.layer.borderWidth = 0.5;
    self.schemeBtn.layer.borderColor = ATDivider().CGColor;
    self.schemeBtn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    self.schemeBtn.contentEdgeInsets = UIEdgeInsetsMake(0, 12, 0, 12);
    self.schemeBtn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    [self.schemeBtn setTitleColor:ATText() forState:UIControlStateNormal];
    self.schemeBtn.showsMenuAsPrimaryAction = YES;
    [self.cardControl addSubview:self.schemeBtn];
    [self refreshSchemeButton];

    /* ★ 2026-11-01 发烫定位：分段跑下拉框。
       四个测试档 + 正常，用户自己切着跑，每档跑够时间再对比日志里的 热=/cpu=，
       定位热源在截图 / 像素处理 / 编码发送 哪一步。 */
    UILabel *benchLabel = [UILabel new];
    benchLabel.translatesAutoresizingMaskIntoConstraints = NO;
    benchLabel.text = @"发烫定位（分段跑）";
    benchLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    benchLabel.textColor = ATSubText();
    [self.cardControl addSubview:benchLabel];

    self.benchBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.benchBtn.translatesAutoresizingMaskIntoConstraints = NO;
    self.benchBtn.backgroundColor = ATCard();
    self.benchBtn.layer.cornerRadius = 10;
    self.benchBtn.layer.borderWidth = 0.5;
    self.benchBtn.layer.borderColor = ATDivider().CGColor;
    self.benchBtn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    self.benchBtn.contentEdgeInsets = UIEdgeInsetsMake(0, 12, 0, 12);
    self.benchBtn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    [self.benchBtn setTitleColor:ATText() forState:UIControlStateNormal];
    self.benchBtn.showsMenuAsPrimaryAction = YES;
    [self.cardControl addSubview:self.benchBtn];
    [self refreshBenchButton];

    [NSLayoutConstraint activateConstraints:@[
        [badge.topAnchor     constraintEqualToAnchor:self.cardControl.topAnchor constant:16],
        [badge.leadingAnchor constraintEqualToAnchor:self.cardControl.leadingAnchor constant:16],
        [badge.heightAnchor  constraintEqualToConstant:26],

        [row1.topAnchor      constraintEqualToAnchor:badge.bottomAnchor constant:14],
        [row1.leadingAnchor  constraintEqualToAnchor:self.cardControl.leadingAnchor constant:16],
        [row1.trailingAnchor constraintEqualToAnchor:self.cardControl.trailingAnchor constant:-16],
        [row1.heightAnchor   constraintEqualToConstant:48],

        [schemeLabel.topAnchor      constraintEqualToAnchor:row1.bottomAnchor constant:14],
        [schemeLabel.leadingAnchor  constraintEqualToAnchor:self.cardControl.leadingAnchor constant:16],
        [schemeLabel.trailingAnchor constraintEqualToAnchor:self.cardControl.trailingAnchor constant:-16],
        [schemeLabel.heightAnchor   constraintEqualToConstant:18],

        [self.schemeBtn.topAnchor      constraintEqualToAnchor:schemeLabel.bottomAnchor constant:6],
        [self.schemeBtn.leadingAnchor  constraintEqualToAnchor:self.cardControl.leadingAnchor constant:16],
        [self.schemeBtn.trailingAnchor constraintEqualToAnchor:self.cardControl.trailingAnchor constant:-16],
        [self.schemeBtn.heightAnchor   constraintEqualToConstant:36],

        [benchLabel.topAnchor      constraintEqualToAnchor:self.schemeBtn.bottomAnchor constant:14],
        [benchLabel.leadingAnchor  constraintEqualToAnchor:self.cardControl.leadingAnchor constant:16],
        [benchLabel.trailingAnchor constraintEqualToAnchor:self.cardControl.trailingAnchor constant:-16],
        [benchLabel.heightAnchor   constraintEqualToConstant:18],

        [self.benchBtn.topAnchor      constraintEqualToAnchor:benchLabel.bottomAnchor constant:6],
        [self.benchBtn.leadingAnchor  constraintEqualToAnchor:self.cardControl.leadingAnchor constant:16],
        [self.benchBtn.trailingAnchor constraintEqualToAnchor:self.cardControl.trailingAnchor constant:-16],
        [self.benchBtn.heightAnchor   constraintEqualToConstant:36],
        [self.benchBtn.bottomAnchor   constraintEqualToAnchor:self.cardControl.bottomAnchor constant:-16],
    ]];
}

- (void)buildCardDiag {
    AXChipBadge *badge = [AXChipBadge badgeWithText:@"  诊断  " fg:ATSubText() bg:ATDivider()];
    [self.cardDiag addSubview:badge];

    NSArray *titles = @[@"1 AX运行时", @"2 XCTest框架", @"3 会话探测", @"4 拉起服务",
                        @"5 本地socket", @"6 lockdown", @"7 bootstrap", @"7 端口扫描"];

    UIStackView *last = nil;
    NSMutableArray *rows = [NSMutableArray array];
    for (int r = 0; r < 4; r++) {
        UIButton *a = [self buildDiagButton:titles[r * 2]     index:r * 2];
        UIButton *b = [self buildDiagButton:titles[r * 2 + 1] index:r * 2 + 1];
        UIStackView *row = [self stackWith:@[a, b]];
        [self.cardDiag addSubview:row];
        [rows addObject:row];
        last = row;
    }

    NSMutableArray *cs = [NSMutableArray array];
    [cs addObject:[badge.topAnchor     constraintEqualToAnchor:self.cardDiag.topAnchor constant:16]];
    [cs addObject:[badge.leadingAnchor constraintEqualToAnchor:self.cardDiag.leadingAnchor constant:16]];
    [cs addObject:[badge.heightAnchor  constraintEqualToConstant:26]];

    for (int r = 0; r < rows.count; r++) {
        UIStackView *row = rows[r];
        [cs addObject:[row.leadingAnchor  constraintEqualToAnchor:self.cardDiag.leadingAnchor constant:16]];
        [cs addObject:[row.trailingAnchor constraintEqualToAnchor:self.cardDiag.trailingAnchor constant:-16]];
        [cs addObject:[row.heightAnchor   constraintEqualToConstant:40]];
        if (r == 0) {
            [cs addObject:[row.topAnchor constraintEqualToAnchor:badge.bottomAnchor constant:14]];
        } else {
            UIStackView *prev = rows[r - 1];
            [cs addObject:[row.topAnchor constraintEqualToAnchor:prev.bottomAnchor constant:10]];
        }
    }
    if (last) [cs addObject:[last.bottomAnchor constraintEqualToAnchor:self.cardDiag.bottomAnchor constant:-16]];
    [NSLayoutConstraint activateConstraints:cs];
}

- (UIStackView *)stackWith:(NSArray<UIView *> *)views {
    UIStackView *s = [UIStackView new];
    s.translatesAutoresizingMaskIntoConstraints = NO;
    s.axis = UILayoutConstraintAxisHorizontal;
    s.distribution = UIStackViewDistributionFillEqually;
    s.alignment = UIStackViewAlignmentFill;
    s.spacing = 12;
    for (UIView *v in views) [s addArrangedSubview:v];
    return s;
}

- (UIButton *)buildBigButton:(NSString *)title bg:(UIColor *)bg fg:(UIColor *)fg {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:fg forState:UIControlStateNormal];
    [b setTitleColor:[fg colorWithAlphaComponent:0.5] forState:UIControlStateHighlighted];
    b.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    b.backgroundColor = bg;
    b.layer.cornerRadius = AT_BUTTON_RADIUS;
    b.layer.masksToBounds = YES;
    return b;
}

- (UIButton *)buildDiagButton:(NSString *)title index:(NSInteger)idx {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:ATText() forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    b.backgroundColor = ATBg();
    b.layer.cornerRadius = 10;
    b.layer.borderWidth = 1;
    b.layer.borderColor = ATDivider().CGColor;
    b.layer.masksToBounds = YES;
    b.tag = idx;
    [b addTarget:self action:@selector(didTapDiag:) forControlEvents:UIControlEventTouchUpInside];
    return b;
}

#pragma mark - 刷新

- (void)didTapEditUDID {
    NSString *cur = AXStreamCurrentUDID() ?: @"";
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"设备 ID（UDID）"
                                                               message:@"填这台 iPhone 的真实 UDID，例如 00008120-000E29E20A80201E。\n保存后推流会用它，PC 才能把 USB 与无线认成同一台。"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = cur;
        tf.placeholder = @"00008120-000E29E20A80201E";
        tf.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) ws = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *v = ac.textFields.firstObject.text ?: @"";
        AXStreamSetUDIDPersist(v);
        __strong typeof(ws) ss = ws;
        [ss refreshAll];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)refreshAll {
    BOOL ready = AXAgentIsReady();
    self.statusText.text = ready ? @"AGENT READY" : @"会话未就绪";
    self.statusText.textColor = ready ? ATGreen() : ATRed();
    self.statusDot.backgroundColor = ready ? ATGreen() : ATRed();

    NSString *err = AXAgentLastError();
    if (err.length && !ready) {
        self.errorText.text = err;
        self.errorText.hidden = NO;
    } else {
        self.errorText.hidden = YES;
    }

    self.titleLabel.text = [NSString stringWithFormat:@"AXTouch  %@", AXBuildTag()];
    self.versionText.text = [NSString stringWithFormat:@"tag: %@", AXBuildTag()];
    self.ipText.text = AXLanIP();   /* 只显示 IP，端口不用露出来 */

    self.devName.valueLabel.text   = [UIDevice currentDevice].name ?: @"-";
    self.devOS.valueLabel.text     = [NSString stringWithFormat:@"%@ %@",
                                      [UIDevice currentDevice].systemName,
                                      [UIDevice currentDevice].systemVersion];
    CGSize px = [UIScreen mainScreen].bounds.size;
    CGFloat sc = [UIScreen mainScreen].scale;
    /* 点位 × 缩放倍数，读数更直观（例：430×932(@3x)） */
    self.devScreen.valueLabel.text = [NSString stringWithFormat:@"%.0f×%.0f(@%.0fx)",
                                      px.width, px.height, sc];
    {
        NSString *u = AXStreamCurrentUDID() ?: @"";
        self.devUDID.valueLabel.text = u.length ? u : @"点此输入";
        self.devUDID.valueLabel.textColor = u.length ? ATText() : ATSubText();
    }
}

/* 版本 tag：从 AXAgent.mm 里没法反向取，这里用编译期常量；改版本时同步 AXTouchApp.swift */

#pragma mark - 按钮回调

- (void)didTapRefresh { [self refreshAll]; }

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    static BOOL once = NO;
    if (once) return;
    once = YES;
    [self autoStartStreamIfNeeded];   /* 不点按钮，进来就投 */
}

- (void)didTapRestartStream {
    BOOL was = AXStreamIsRunning();
    self.rebuildBtn.enabled = NO;      /* 防连点：重启期间禁用 */
    AXStreamStop();
    self.statusText.text = @"投屏服务重启中…";
    self.statusText.textColor = ATSubText();
    NSLog(@"[stream] 重启服务：wasRunning=%d", was);
    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(ws) ss = ws;
        if (!ss) return;
        NSInteger i = [[NSUserDefaults standardUserDefaults] integerForKey:kAXSchemeKey];
        AXStreamApplyProfile((int)i);                 /* 档位＝采集+编码，一起上 */
        BOOL ok = AXStreamStart(27184);
        ss.rebuildBtn.enabled = YES;
        ss.statusText.text = ok ? @"投屏服务已重启" : @"重启失败";
        /* ReplayKit 若 3 秒内拿不到帧，AXAgent 会自动回退 XCUITest，这里 3.5 秒后如实显示 */
        if (AXStreamProfileCapture((int)i) == 1) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                int act = AXStreamActiveScheme();
                if (act == 2) {
                    ss.statusText.text = @"录屏拿不到画面，已自动切回截图";
                    ss.statusText.textColor = ATBrown();
                } else if (act == 1) {
                    ss.statusText.text = @"系统录屏投屏中";
                    ss.statusText.textColor = ATGreen();
                }
                [ss refreshAll];
            });
        }
        ss.statusText.textColor = ok ? ATGreen() : ATRed();
        NSLog(@"[stream] 重启服务结果 ok=%d", ok);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [ss refreshAll]; });
    });
}

- (void)didTapRebuild {
    /* ★ 幂等：连点不再叠加常驻线程 / 覆盖会话 */
    if (AXAgentIsBootstrapping()) {
        self.statusText.text = @"正在建立会话，请稍候…";
        return;
    }
    if (AXAgentIsReady()) {
        self.statusText.text = @"会话已就绪，无需重建";
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self refreshAll]; });
        return;
    }
    AXAgentStartSticky();
    self.statusText.text = @"重建中…";
    self.rebuildBtn.enabled = NO;
    self.rebuildBtn.alpha = 0.5;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        self.rebuildBtn.enabled = YES;
        self.rebuildBtn.alpha = 1.0;
        [self refreshAll];
    });
}

- (void)didTapLogs {
    AXLogViewerViewController *vc = [AXLogViewerViewController new];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)didTapTree {
    self.frameStat.text = @"读节点中…（结果看运行日志）";
    __weak typeof(self) ws = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *r = AXAgentDumpTree(120) ?: @"nil";
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(ws) ss = ws;
            if (ss) ss.frameStat.text = [NSString stringWithFormat:@"节点树: %@", r];
        });
    });
}

/* 下拉框内容：按 AXAgent 里的档位表动态生成（测试期一次性把几种拿流方式都列出来） */
- (void)refreshSchemeButton {
    NSInteger cur = [[NSUserDefaults standardUserDefaults] integerForKey:kAXSchemeKey];
    int cnt = AXStreamProfileCount();
    if (cur < 0 || cur >= cnt) cur = 0;

    NSString *t = [NSString stringWithUTF8String:AXStreamProfileName((int)cur)];
    [self.schemeBtn setTitle:[NSString stringWithFormat:@"%@    ▾", t] forState:UIControlStateNormal];

    __weak typeof(self) ws = self;
    NSMutableArray *items = [NSMutableArray array];
    for (int i = 0; i < cnt; i++) {
        NSString *nm = [NSString stringWithUTF8String:AXStreamProfileName(i)];
        UIAction *a = [UIAction actionWithTitle:nm
                                         image:nil
                                    identifier:nil
                                     handler:^(UIAction *act) {
            __strong typeof(ws) ss = ws;
            if (ss) [ss selectScheme:(NSInteger)i];
        }];
        a.state = (i == (int)cur) ? UIMenuElementStateOn : UIMenuElementStateOff;
        [items addObject:a];
    }
    self.schemeBtn.menu = [UIMenu menuWithTitle:@"投屏档位（测试）" children:items];
}

/* 选档位：编码参数（格式/质量）每帧读取 → 立刻生效；
   采集方式变了（截图 ↔ 录屏）才需要点「重启服务」。 */
- (void)selectScheme:(NSInteger)i {
    int capBefore = AXStreamGetScheme();
    [[NSUserDefaults standardUserDefaults] setInteger:i forKey:kAXSchemeKey];
    AXStreamApplyProfile((int)i);
    [self refreshSchemeButton];

    NSString *nm = [NSString stringWithUTF8String:AXStreamProfileName((int)i)];
    BOOL needRestart = (capBefore != AXStreamProfileCapture((int)i));
    if (needRestart) {
        self.statusText.text = [NSString stringWithFormat:@"已选「%@」，点「重启服务」生效", nm];
        self.statusText.textColor = ATBrown();
    } else {
        self.statusText.text = [NSString stringWithFormat:@"已切到「%@」（立即生效）", nm];
        self.statusText.textColor = ATSubText();
    }
    NSLog(@"[scheme] 档位 %ld = %@  needRestart=%d  %s", (long)i, nm, needRestart,
          AXStreamProfileDesc((int)i));
}

#pragma mark - 发烫定位（分段跑）下拉框

/* 四个测试档 + 正常。语义对应 AXAgent.mm 的 g_benchMode：
   1 只截图（不解码/不缩放/不编码/不发送）    2 截图+解码+缩放（不编码不发送）
   3 只编码发送（完全不截图）                  4 空转（只心跳，温度/CPU 底线基准） */
- (void)refreshBenchButton {
    NSString *names[] = { @"正常全链路", @"1 只截图（不处理）", @"2 截图+缩放",
                          @"3 只编码发送", @"4 空转（基线）" };
    NSInteger m = self.benchSel;
    if (m < 0 || m > 4) m = 0;
    [self.benchBtn setTitle:[NSString stringWithFormat:@"%@    ▾", names[m]]
                   forState:UIControlStateNormal];

    __weak typeof(self) ws = self;
    NSMutableArray *items = [NSMutableArray array];
    for (NSInteger i = 0; i <= 4; i++) {
        NSInteger mm = i;
        UIAction *a = [UIAction actionWithTitle:names[i]
                                        image:nil
                                   identifier:nil
                                    handler:^(UIAction *act) {
            __strong typeof(ws) ss = ws;
            if (ss) [ss selectBench:mm];
        }];
        a.state = (i == m) ? UIMenuElementStateOn : UIMenuElementStateOff;
        [items addObject:a];
    }
    self.benchBtn.menu = [UIMenu menuWithTitle:@"发烫定位（分段跑）" children:items];
}

- (void)selectBench:(NSInteger)m {
    NSString *names[] = { @"正常全链路", @"1 只截图（不处理）", @"2 截图+缩放",
                          @"3 只编码发送", @"4 空转（基线）" };
    if (m < 0 || m > 4) m = 0;
    self.benchSel = m;
    AXStreamSetBenchMode((int)m);   /* 立刻生效，不用重启服务 */
    [self refreshBenchButton];

    if (m == 0) {
        self.statusText.text = @"已恢复正常全链路";
    } else {
        self.statusText.text = [NSString stringWithFormat:
            @"已切到「%@」，跑够时间后看运行日志的 热=/cpu=", names[m]];
    }
    self.statusText.textColor = ATSubText();
    NSLog(@"[bench] 模式 %ld = %@", (long)m, names[m]);
}

/* 进界面即开投屏：按保存的方案启动 */
- (void)autoStartStreamIfNeeded {
    NSInteger i = [[NSUserDefaults standardUserDefaults] integerForKey:kAXSchemeKey];
    AXStreamApplyProfile((int)i);
    if (!AXStreamIsRunning()) {
        BOOL ok = AXStreamStart(27184);
        NSLog(@"[stream] 自动启动投屏 scheme=%ld ok=%d", (long)i, ok);
    }
}

- (void)didTapServer {
    self.frameStat.text = @"WDA 服务拉起中…";
    AXStartWDAServerThread(NULL);
}

- (void)didTapShot {
    self.frameStat.text = @"抓帧中…";
    __weak typeof(self) ws = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        CFTimeInterval t0 = CACurrentMediaTime();
        NSString *b64 = AXAgentShot(720, 0.6);
        CFTimeInterval dt = (CACurrentMediaTime() - t0) * 1000.0;
        UIImage *img = nil;
        NSUInteger bytes = 0;
        if (b64.length) {
            NSData *d = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
            bytes = d.length;
            img = [UIImage imageWithData:d];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(ws) ss = ws;
            if (!ss) return;
            if (img) {
                ss.preview.image = img;
                ss.frameStat.text = [NSString stringWithFormat:
                    @"%.0f x %.0f   %.1f KB   全链路 %.0f ms",
                    img.size.width, img.size.height, bytes / 1024.0, dt];
            } else {
                ss.frameStat.text = @"抓帧失败，看运行日志";
            }
        });
    });
}

- (void)didTapBurst {
    if (self.burstRunning) return;
    self.burstRunning = YES;
    self.burstBtn.enabled = NO;
    self.frameStat.text = @"连拍中…";
    __weak typeof(self) ws = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        const int N = 30;
        double sum = 0, mn = 1e9, mx = 0;
        NSUInteger bytes = 0;
        UIImage *lastImg = nil;
        CFTimeInterval wall0 = CACurrentMediaTime();
        for (int i = 0; i < N; i++) {
            CFTimeInterval t0 = CACurrentMediaTime();
            NSString *b64 = AXAgentShot(720, 0.6);
            double dt = (CACurrentMediaTime() - t0) * 1000.0;
            if (!b64.length) continue;
            NSData *d = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
            bytes += d.length;
            sum += dt;
            if (dt < mn) mn = dt;
            if (dt > mx) mx = dt;
            if (i == N - 1) lastImg = [UIImage imageWithData:d];
        }
        double wall = (CACurrentMediaTime() - wall0) * 1000.0;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(ws) ss = ws;
            if (!ss) return;
            ss.burstRunning = NO;
            ss.burstBtn.enabled = YES;
            if (lastImg) ss.preview.image = lastImg;
            double avg = sum / N;
            ss.frameStat.text = [NSString stringWithFormat:
                @"%d 帧  平均 %.0fms  最快 %.0f  最慢 %.0f\n实际 %.1f fps  单帧 %.1f KB",
                N, avg, mn, mx, 1000.0 / (wall / N), bytes / (double)N / 1024.0];
        });
    });
}

- (void)didTapDiag:(UIButton *)sender {
    NSString *r = nil;
    switch (sender.tag) {
        case 0: [self refreshAll]; r = [NSString stringWithFormat:@"会话: %@",
                                        AXAgentIsReady() ? @"READY" : @"未就绪"]; break;
        case 1: AXLoadXCTestThread(); r = @"2 已转常驻线程加载"; break;
        case 2: r = AXProbeDaemonSession() ?: @"nil"; break;
        case 3: AXStartWDAServerThread(NULL); r = @"4 服务已在常驻线程启动"; break;
        case 4: r = AXTestLocalSocket() ?: @"nil"; break;
        case 5: r = AXTestLockdownTCP() ?: @"nil"; break;
        case 6: r = AXBootstrapProbe() ?: @"nil"; break;
        case 7: r = AXScanLoopbackPorts() ?: @"nil"; break;
        default: break;
    }
    self.frameStat.text = [r description];
    [self refreshAll];
}

@end

#pragma mark - 根控制器

UIViewController *AXMakeRootController(void) {
    AXMainViewController *main = [AXMainViewController new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:main];
    nav.navigationBar.hidden = YES;   /* 自绘顶部条（与 ios-daemon 一致） */
    return nav;
}
