//
//  ATTopBar.m
//
#import "ATTopBar.h"
#import "UITheme.h"
#import <objc/runtime.h>

static const void *kATTopBarKey = &kATTopBarKey;

@implementation UIViewController (ATTopBar)

- (UIView *)at_topBar {
    return objc_getAssociatedObject(self, kATTopBarKey);
}

- (void)at_setupTopBarWithTitle:(NSString *)title refreshAction:(SEL)refreshAction {
    UIView *bar = [UIView new];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    bar.backgroundColor = ATCard();
    [self.view addSubview:bar];
    objc_setAssociatedObject(self, kATTopBarKey, bar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIView *line = [UIView new];
    line.translatesAutoresizingMaskIntoConstraints = NO;
    line.backgroundColor = ATDivider();
    [bar addSubview:line];

    UIButton *back = [UIButton buttonWithType:UIButtonTypeSystem];
    back.translatesAutoresizingMaskIntoConstraints = NO;
    [back setImage:[UIImage systemImageNamed:@"chevron.backward"] forState:UIControlStateNormal];
    [back setTitle:@" 返回" forState:UIControlStateNormal];
    [back setTitleColor:ATBlue() forState:UIControlStateNormal];
    back.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    back.tintColor = ATBlue();
    back.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    [back addTarget:self action:@selector(at_topBarBack) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:back];

    UILabel *titleLabel = [UILabel new];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = title ?: @"";
    titleLabel.font = ATTitleFont();
    titleLabel.textColor = ATText();
    titleLabel.textAlignment = NSTextAlignmentCenter;
    [bar addSubview:titleLabel];

    UIButton *refresh = [UIButton buttonWithType:UIButtonTypeSystem];
    refresh.translatesAutoresizingMaskIntoConstraints = NO;
    [refresh setImage:[UIImage systemImageNamed:@"arrow.clockwise"] forState:UIControlStateNormal];
    refresh.tintColor = ATBlue();
    [refresh addTarget:self action:refreshAction forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:refresh];

    [NSLayoutConstraint activateConstraints:@[
        [bar.topAnchor      constraintEqualToAnchor:self.view.topAnchor],
        [bar.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor],
        [bar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        /* ★ 2026-10-03 修 17.2.1 返回键点不到：固定 50pt 在灵动岛机型整个埋进
           状态栏区 → 顶条延伸到 safeArea 顶 +50（非刘海机型 safeTop=0 不变） */
        [bar.bottomAnchor   constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:50],

        [line.bottomAnchor  constraintEqualToAnchor:bar.bottomAnchor],
        [line.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor],
        [line.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor],
        [line.heightAnchor  constraintEqualToConstant:0.5],

        [back.leadingAnchor  constraintEqualToAnchor:bar.leadingAnchor constant:12],
        [back.centerYAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:25],
        [back.heightAnchor   constraintEqualToConstant:44],
        [back.widthAnchor    constraintGreaterThanOrEqualToConstant:80],

        [refresh.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor constant:-12],
        [refresh.centerYAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:25],
        [refresh.heightAnchor   constraintEqualToConstant:44],
        [refresh.widthAnchor    constraintEqualToConstant:44],

        [titleLabel.centerXAnchor constraintEqualToAnchor:bar.centerXAnchor],
        [titleLabel.centerYAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:25],
        [titleLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:back.trailingAnchor constant:8],
        [titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:refresh.leadingAnchor constant:-8],
    ]];
}

- (void)at_topBarBack {
    if (self.navigationController.viewControllers.firstObject != self) {
        [self.navigationController popViewControllerAnimated:YES];
    } else {
        /* 根页（理论上不该走到这里——push 时才有返回） */
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

@end
