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
            consumed = (long long)data.length;
            /* 尝试完整 UTF-8 解码；失败则丢尾部最多 3 字节再试（避免切在多字节字符中间） */
            NSUInteger tryLen = data.length;
            for (int i = 0; i < 4 && tryLen > 0; i++) {
                NSData *sub = [data subdataWithRange:NSMakeRange(0, tryLen)];
                NSString *s = [[NSString alloc] initWithData:sub encoding:NSUTF8StringEncoding];
                if (s) { text = s; consumed = (long long)tryLen; break; }
                tryLen -= 1;
            }
            if (text.length == 0) {
                /* 兜底：容忍非法字节 */
                text = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding] ?: @"";
            }
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
