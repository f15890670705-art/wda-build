//
//  AXStream.h
//  H.264 屏幕推流（按 go-screen 现有 27184 协议输出，PC 端零改动）
//
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 启动推流服务（监听 port，默认 27184）
BOOL AXStreamStart(uint16_t port);

/// 停止推流并释放编码器
void AXStreamStop(void);

/// 是否在推流
BOOL AXStreamIsRunning(void);

/// 统计：fps / 码率 / 客户端数 / 编码尺寸 / 最近错误
NSDictionary *AXStreamStats(void);

/// 设置编码参数（码率 bps、目标帧率、最长边像素）
void AXStreamSetParams(int bitrateBps, int fps, int maxSide);

NS_ASSUME_NONNULL_END
