//
//  ATTopBar.h
//  自绘顶部条（左侧返回 + 标题 + 右侧刷新）
//  v1.10.378 引入：父级 nav.navigationBar.hidden=YES（自绘标题区），
//  子页面用 system rightBarButtonItem 显示不出来，所以加这个 category
//  在每个子页的 viewDidLoad 里调 at_setupTopBarWithTitle:refreshAction:。
//
#import <UIKit/UIKit.h>

@interface UIViewController (ATTopBar)

/* 在 self.view 顶部建一个 50pt 高的自绘条：[返回 | 标题 | 刷新]。
   返回键固定 pop navigation；刷新键调 refreshAction（通常 @selector(reload)）。
   bar 视图通过 at_topBar 拿到（关联对象），约束用 at_topBar.bottomAnchor。 */
- (void)at_setupTopBarWithTitle:(NSString *)title refreshAction:(SEL)refreshAction;

/* 取出顶部条引用（关联对象持有）。未调 at_setupTopBarWithTitle: 时返回 nil。 */
- (UIView *)at_topBar;

@end
