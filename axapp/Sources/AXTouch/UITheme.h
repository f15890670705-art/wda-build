//
// UITheme.h
// AilinTouch 卡片式 UI 配色 + 尺寸常量
//
#ifndef UITheme_h
#define UITheme_h

#import <UIKit/UIKit.h>

/* ========== 颜色 ========== */
static inline UIColor *ATBg(void)          { return [UIColor colorWithRed:0.965 green:0.965 blue:0.972 alpha:1.0]; } // #F5F5F7
static inline UIColor *ATCard(void)        { return [UIColor whiteColor]; }
static inline UIColor *ATText(void)        { return [UIColor colorWithRed:0.12  green:0.13  blue:0.18  alpha:1.0]; } // 主文字 #1F2937
static inline UIColor *ATSubText(void)     { return [UIColor colorWithRed:0.55  green:0.56  blue:0.62  alpha:1.0]; } // 副文字 #8C8E96
static inline UIColor *ATDivider(void)     { return [UIColor colorWithRed:0.92  green:0.93  blue:0.95  alpha:1.0]; } // 分割线 #EBEFF2
static inline UIColor *ATPurple(void)      { return [UIColor colorWithRed:0.486 green:0.361 blue:0.847 alpha:1.0]; } // #7C5CD8
static inline UIColor *ATPurpleBg(void)    { return [UIColor colorWithRed:0.929 green:0.894 blue:0.984 alpha:1.0]; } // #EDE4FB
static inline UIColor *ATGreen(void)       { return [UIColor colorWithRed:0.063 green:0.725 blue:0.506 alpha:1.0]; } // #10B981
static inline UIColor *ATGreenBg(void)     { return [UIColor colorWithRed:0.82  green:0.98  blue:0.95  alpha:1.0]; } // #D1FAE5
static inline UIColor *ATRed(void)         { return [UIColor colorWithRed:0.937 green:0.267 blue:0.267 alpha:1.0]; } // #EF4444
static inline UIColor *ATRedBg(void)       { return [UIColor colorWithRed:0.996 green:0.918 blue:0.918 alpha:1.0]; } // #FEEAEA
static inline UIColor *ATBlue(void)        { return [UIColor colorWithRed:0.231 green:0.510 blue:0.965 alpha:1.0]; } // #3B82F6
static inline UIColor *ATBlueBg(void)      { return [UIColor colorWithRed:0.875 green:0.918 blue:0.996 alpha:1.0]; } // #DFEBFF
static inline UIColor *ATBrown(void)       { return [UIColor colorWithRed:0.572 green:0.251 blue:0.055  alpha:1.0]; } // #92400E
static inline UIColor *ATBrownBg(void)     { return [UIColor colorWithRed:0.969 green:0.918 blue:0.835 alpha:1.0]; } // #F7EAD5

/* ========== 字体 ========== */
static inline UIFont *ATTitleFont(void)    { return [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold]; }
static inline UIFont *ATHeadFont(void)     { return [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold]; }
static inline UIFont *ATValueFont(void)    { return [UIFont systemFontOfSize:15 weight:UIFontWeightMedium]; }
static inline UIFont *ATValueBoldFont(void){ return [UIFont systemFontOfSize:18 weight:UIFontWeightBold]; }
static inline UIFont *ATSubFont(void)      { return [UIFont systemFontOfSize:12 weight:UIFontWeightRegular]; }

/* ========== 尺寸 ========== */
#define AT_SCREEN_W   ([UIScreen mainScreen].bounds.size.width)
#define AT_SCREEN_H   ([UIScreen mainScreen].bounds.size.height)
#define AT_PAD         16.0f
#define AT_CARD_RADIUS 16.0f
#define AT_BUTTON_RADIUS 24.0f
#define AT_TABBAR_H    64.0f

/* ========== 工厂工具 ========== */
static inline UILabel *ATLabel(UIFont *font, UIColor *color) {
    UILabel *l = [UILabel new];
    l.font = font;
    l.textColor = color;
    return l;
}

#endif /* UITheme_h */
