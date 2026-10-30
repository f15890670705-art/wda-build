//
//  AXLogViewerViewController.m
//  第一级：Documents 下的日志文件列表
//  第二级：文件内容（分页 1MB，可「加载更多」看完整个文件）
//
//  ★ 与 ios-daemon 的差异：那边日志在引擎侧、走内部 socket 拉 /loglist + /cat；
//    AXTouch 的日志就在自己沙盒里，直接读文件，不依赖任何服务在跑。
//
#import "AXLogViewerViewController.h"
#import "UITheme.h"
#import "ATTopBar.h"

/* 前置声明：实现放在文件后段，先用后定义 */
static NSString *AXDecodeUTF8Lossy(NSData *data, NSUInteger *consumedOut);

static NSString *AXDocsDir(void) {
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

#pragma mark - 内容页

@interface AXLogContentViewController : UIViewController
@property (nonatomic, copy) NSString *filePath;
@property (nonatomic, copy) NSString *baseURL;    // 占位，与 ios-daemon 接口保持一致
@end

@implementation AXLogContentViewController {
    UITextView *_tv;
    UILabel *_statusLabel;
    UIButton *_moreBtn;
    long long _loadedBytes;
    BOOL _eof;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = ATBg();
    self.title = [self.filePath lastPathComponent];
    [self at_setupTopBarWithTitle:[self.filePath lastPathComponent] refreshAction:@selector(reload)];

    _tv = [UITextView new];
    _tv.translatesAutoresizingMaskIntoConstraints = NO;
    _tv.editable = NO;
    _tv.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    _tv.textColor = ATText();
    _tv.backgroundColor = ATCard();
    _tv.layer.cornerRadius = 12;
    _tv.textContainerInset = UIEdgeInsetsMake(12, 12, 12, 12);
    [self.view addSubview:_tv];

    _statusLabel = [UILabel new];
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _statusLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    _statusLabel.textColor = ATSubText();
    _statusLabel.numberOfLines = 0;
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:_statusLabel];

    _moreBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _moreBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [_moreBtn setTitle:@"加载更多 ▼" forState:UIControlStateNormal];
    [_moreBtn setTitleColor:ATBlue() forState:UIControlStateNormal];
    _moreBtn.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    _moreBtn.backgroundColor = ATCard();
    _moreBtn.layer.cornerRadius = 12;
    _moreBtn.layer.borderWidth = 0.5;
    _moreBtn.layer.borderColor = ATDivider().CGColor;
    [_moreBtn addTarget:self action:@selector(loadMore) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_moreBtn];

    UIRefreshControl *rc = [UIRefreshControl new];
    [rc addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    _tv.refreshControl = rc;

    UIView *bar = [self at_topBar];
    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_statusLabel.topAnchor      constraintEqualToAnchor:bar.bottomAnchor constant:8],
        [_statusLabel.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor constant:AT_PAD],
        [_statusLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-AT_PAD],
        [_tv.topAnchor               constraintEqualToAnchor:_statusLabel.bottomAnchor constant:8],
        [_tv.bottomAnchor            constraintEqualToAnchor:_moreBtn.topAnchor constant:-8],
        [_tv.leadingAnchor           constraintEqualToAnchor:self.view.leadingAnchor constant:AT_PAD],
        [_tv.trailingAnchor          constraintEqualToAnchor:self.view.trailingAnchor constant:-AT_PAD],
        [_moreBtn.bottomAnchor       constraintEqualToAnchor:g.bottomAnchor constant:-8],
        [_moreBtn.leadingAnchor      constraintEqualToAnchor:self.view.leadingAnchor constant:AT_PAD],
        [_moreBtn.trailingAnchor     constraintEqualToAnchor:self.view.trailingAnchor constant:-AT_PAD],
        [_moreBtn.heightAnchor       constraintEqualToConstant:44],
    ]];

    [self reload];
}

- (void)reload {
    [_tv.refreshControl endRefreshing];
    _loadedBytes = 0;
    _eof = NO;
    [self readAtOffset:0 append:NO];
}

- (void)loadMore {
    [_moreBtn setTitle:@"加载中…" forState:UIControlStateNormal];
    _moreBtn.enabled = NO;
    [self readAtOffset:_loadedBytes append:YES];
}

/* 直接读文件：从 offset 起读最多 1MB。按字节读后按 UTF-8 解码（可能切到多字节字符中间，
   这里容错处理，丢掉尾部不完整字符，偏移按实际消耗的字节数前进） */
- (void)readAtOffset:(long long)offset append:(BOOL)append {
    NSString *path = self.filePath;
    __weak typeof(self) ws = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        const long long chunk = 1024 * 1024;
        NSData *data = nil;
        NSError *err = nil;
        NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
        if (!fh) {
            err = [NSError errorWithDomain:@"AXLog" code:2
                                     userInfo:@{NSLocalizedDescriptionKey: @"打开失败（文件不存在？）"}];
        } else {
            @try {
                [fh seekToFileOffset:(unsigned long long)offset];
                data = [fh readDataUpToLength:(NSUInteger)chunk error:&err];
            } @catch (NSException *e) {
                err = [NSError errorWithDomain:@"AXLog" code:1
                                         userInfo:@{NSLocalizedDescriptionKey: e.reason ?: @"读取异常"}];
            }
            [fh closeFile];
        }

        NSString *text = @"";
        long long consumed = 0;
        BOOL eof = YES;
        if (data.length) {
            NSUInteger used = 0;
            text = AXDecodeUTF8Lossy(data, &used);
            consumed = (long long)used;
            eof = (data.length < chunk);
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(ws) ss = ws;
            if (!ss) return;
            ss->_moreBtn.enabled = YES;
            [ss->_moreBtn setTitle:@"加载更多 ▼" forState:UIControlStateNormal];
            if (err) {
                ss->_statusLabel.text = [NSString stringWithFormat:@"读取失败\n%@", err.localizedDescription];
                return;
            }
            if (append) {
                ss->_tv.text = [ss->_tv.text stringByAppendingString:text];
            } else {
                ss->_tv.text = text.length ? text : @"(空文件)";
            }
            ss->_loadedBytes = offset + consumed;
            ss->_eof = eof;
            ss->_moreBtn.hidden = eof;

            NSInteger lines = [[ss->_tv.text componentsSeparatedByString:@"\n"] count];
            ss->_statusLabel.text = [NSString stringWithFormat:@"%@   %ld 行   %lld KB",
                                     [ss.filePath lastPathComponent], (long)lines,
                                     ss->_loadedBytes / 1024];
            if (ss->_tv.text.length > 0) {
                NSRange r = NSMakeRange(ss->_tv.text.length - 1, 1);
                [ss->_tv scrollRangeToVisible:r];
            }
        });
    });
}

@end

#pragma mark - 文件列表页

/* ★ 2026-10-31 修「日志满屏乱码」：
   旧逻辑=「整块 UTF-8 解码，失败就丢尾部几字节再试，还不行就整体 Latin1」。
   两个问题：① 从文件中间读时**开头**就切在多字节字符上，丢尾部永远救不回来；
            ② Latin1 兜底会把**整页**中文变成乱码（Latin1 解 UTF-8 中文必花）。
   现在：先丢开头最多 3 字节重试（并按行首对齐），再不行逐序列扫描、坏字节换 '?'，
   其余照常解码 —— 一处坏字节只坏一个字，不会污染全篇。 */
static NSString *AXDecodeUTF8Lossy(NSData *data, NSUInteger *consumedOut) {
    if (consumedOut) *consumedOut = 0;
    if (data.length == 0) return @"";
    const NSUInteger n = data.length;

    /* 起点对齐到行首：从中间读时第一行必然是半截，跳过它更整齐 */
    NSUInteger start = 0;
    {
        const uint8_t *p = (const uint8_t *)data.bytes;
        NSUInteger nl = NSNotFound;
        for (NSUInteger i = 0; i < MIN(n, (NSUInteger)4096); i++) {
            if (p[i] == '\n') { nl = i; break; }
        }
        if (nl != NSNotFound) start = nl + 1;
    }

    for (NSUInteger skip = start; skip <= start + 3 && skip < n; skip++) {
        NSData *sub = [data subdataWithRange:NSMakeRange(skip, n - skip)];
        NSString *r = [[NSString alloc] initWithData:sub encoding:NSUTF8StringEncoding];
        if (r) { if (consumedOut) *consumedOut = n; return r; }
        /* 尾部可能也切在多字节字符上：最多退 3 字节 */
        for (NSUInteger tail = 1; tail <= 3 && sub.length > tail; tail++) {
            NSData *sub2 = [sub subdataWithRange:NSMakeRange(0, sub.length - tail)];
            NSString *r2 = [[NSString alloc] initWithData:sub2 encoding:NSUTF8StringEncoding];
            if (r2) { if (consumedOut) *consumedOut = n - tail; return r2; }
        }
    }

    /* 中途有非法字节：逐序列扫描，坏字节替换成 '?'，好的照常保留 */
    const uint8_t *p = (const uint8_t *)data.bytes;
    NSMutableData *clean = [NSMutableData dataWithCapacity:n];
    NSUInteger i = 0;
    while (i < n) {
        uint8_t c = p[i];
        NSUInteger len = 0;
        if (c < 0x80) len = 1;
        else if ((c & 0xE0) == 0xC0) len = 2;
        else if ((c & 0xF0) == 0xE0) len = 3;
        else if ((c & 0xF8) == 0xF0) len = 4;
        BOOL ok = (len > 0 && i + len <= n);
        if (ok) {
            for (NSUInteger k = 1; k < len; k++) {
                if ((p[i + k] & 0xC0) != 0x80) { ok = NO; break; }
            }
        }
        if (ok) {
            [clean appendBytes:p + i length:len];
            i += len;
        } else {
            [clean appendBytes:"?" length:1];
            i += 1;
        }
    }
    if (consumedOut) *consumedOut = n;
    return [[NSString alloc] initWithData:clean encoding:NSUTF8StringEncoding] ?: @"";
}

@interface AXLogViewerViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) NSArray<NSDictionary *> *logs;
@end

@implementation AXLogViewerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = ATBg();
    self.title = @"运行日志";
    [self at_setupTopBarWithTitle:@"运行日志" refreshAction:@selector(reload)];

    self.statusLabel = [UILabel new];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    self.statusLabel.textColor = ATSubText();
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.statusLabel];

    self.table = [UITableView new];
    self.table.translatesAutoresizingMaskIntoConstraints = NO;
    self.table.delegate = self;
    self.table.dataSource = self;
    self.table.backgroundColor = ATBg();
    [self.view addSubview:self.table];

    UIRefreshControl *rc = [UIRefreshControl new];
    [rc addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    self.table.refreshControl = rc;

    UIView *bar = [self at_topBar];
    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.statusLabel.topAnchor      constraintEqualToAnchor:bar.bottomAnchor constant:8],
        [self.statusLabel.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor constant:AT_PAD],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-AT_PAD],
        [self.table.topAnchor            constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:8],
        [self.table.bottomAnchor         constraintEqualToAnchor:g.bottomAnchor constant:-8],
        [self.table.leadingAnchor        constraintEqualToAnchor:self.view.leadingAnchor constant:AT_PAD],
        [self.table.trailingAnchor       constraintEqualToAnchor:self.view.trailingAnchor constant:-AT_PAD],
    ]];

    self.logs = @[];
    [self reload];
}

- (void)reload {
    [self.table.refreshControl endRefreshing];

    NSString *dir = AXDocsDir();
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *names = [fm contentsOfDirectoryAtPath:dir error:nil] ?: @[];
    NSMutableArray *out = [NSMutableArray array];

    /* agent.log（引擎侧）排最前，其余按修改时间倒序 */
    NSMutableArray *filtered = [NSMutableArray array];
    for (NSString *n in names) {
        if (![n.pathExtension.lowercaseString isEqualToString:@"log"]) continue;
        [filtered addObject:n];
    }
    [filtered sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        if ([a isEqualToString:@"agent.log"]) return NSOrderedAscending;
        if ([b isEqualToString:@"agent.log"]) return NSOrderedDescending;
        NSDictionary *aa = [fm attributesOfItemAtPath:[dir stringByAppendingPathComponent:a] error:nil];
        NSDictionary *bb = [fm attributesOfItemAtPath:[dir stringByAppendingPathComponent:b] error:nil];
        return [[bb fileModificationDate] compare:[aa fileModificationDate]];
    }];

    for (NSString *n in filtered) {
        NSString *p = [dir stringByAppendingPathComponent:n];
        NSDictionary *attr = [fm attributesOfItemAtPath:p error:nil];
        unsigned long long sz = [attr fileSize];
        NSDate *mt = [attr fileModificationDate];
        NSDateFormatter *df = [NSDateFormatter new];
        df.dateFormat = @"MM-dd HH:mm:ss";
        [out addObject:@{@"name": n, @"path": p,
                         @"size": @(sz),
                         @"mtime": mt ? [df stringFromDate:mt] : @"-"}];
    }

    self.logs = out;
    self.statusLabel.text = out.count
        ? [NSString stringWithFormat:@"共 %lu 个日志文件，点文件名查看\n%@",
           (unsigned long)out.count, dir]
        : [NSString stringWithFormat:@"没有 .log 文件\n%@", dir];
    [self.table reloadData];
}

#pragma mark UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.logs.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"axlogcell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
        cell.textLabel.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
        cell.textLabel.textColor = ATText();
        cell.detailTextLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
        cell.detailTextLabel.textColor = ATSubText();
        cell.backgroundColor = ATCard();
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    NSDictionary *item = self.logs[indexPath.row];
    cell.textLabel.text = item[@"name"] ?: @"?";
    unsigned long long sz = [item[@"size"] unsignedLongLongValue];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%.1f KB   %@", sz / 1024.0, item[@"mtime"]];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *path = self.logs[indexPath.row][@"path"];
    if (!path.length) return;
    AXLogContentViewController *vc = [AXLogContentViewController new];
    vc.filePath = path;
    [self.navigationController pushViewController:vc animated:YES];
}

@end
