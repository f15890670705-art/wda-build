//
//  AXStream.h
//  H.264 屏幕推流（按 go-screen 现有 27184 协议输出，PC 端零改动）
//
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/* ★ 必须：本头会被 .mm（C++ 编译）和 .m / Swift 桥接（C 编译）同时包含。
   不加 extern "C" 两边符号名不同，链接期就是 undefined symbols。 */
#ifdef __cplusplus
extern "C" {
#endif

/// 启动推流服务（监听 port，默认 27184）
BOOL AXStreamStart(uint16_t port);

/// 停止推流并释放编码器
void AXStreamStop(void);

/// 是否在推流
BOOL AXStreamIsRunning(void);

/// 设置真 UDID（PC 端经 10010 传入；preamble 用它关联真机）
void AXStreamSetUDID(NSString *udid);

/// 统计：fps / 码率 / 客户端数 / 编码尺寸 / 最近错误
NSDictionary *AXStreamStats(void);

/// 设置编码参数（码率 bps、目标帧率、最长边像素）
void AXStreamSetParams(int bitrateBps, int fps, int maxSide);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
