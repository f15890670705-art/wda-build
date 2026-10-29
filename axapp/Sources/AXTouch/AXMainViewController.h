//
//  AXMainViewController.h
//  AXTouch 主界面（照 ios-daemon ServiceManagerViewController 卡片式布局）
//
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface AXMainViewController : UIViewController
@end

/// SwiftUI 包装用：返回带导航栈的根控制器（navigationBar 隐藏，顶部条自绘）
UIViewController *AXMakeRootController(void);

NS_ASSUME_NONNULL_END
