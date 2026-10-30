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

/// 用户手填 / PC 下发：写入并持久化（Keychain），此后 preamble 一律用它
void AXStreamSetUDIDPersist(NSString *udid);

/// 当前生效的 UDID（空串＝还没有）
NSString *AXStreamCurrentUDID(void);

/// 采集方案：0=XCUITest(截图) 1=ReplayKit。仅在 Start 之前设置有效。
void AXStreamSetScheme(int s);

/* 测试档位（临时）：采集方式 + 截图编码格式 + 质量 的组合 */
int         AXStreamProfileCount(void);
const char *AXStreamProfileName(int idx);
const char *AXStreamProfileDesc(int idx);
int         AXStreamProfileCapture(int idx);
void        AXStreamApplyProfile(int idx);
int  AXStreamGetScheme(void);
/// 实际生效的方案：0=XCUITest 1=ReplayKit 2=ReplayKit 拿不到帧已回退 XCUITest
int  AXStreamActiveScheme(void);

/// 截图质量参数（0~1，默认 1.0）。调低可能让 daemon 改用 JPEG 编码，IPC 更快
void AXStreamSetImgQuality(double q);

/// 截图编码格式（UTI）：public.jpeg（默认，支持 DCT 缩放解码）或 public.png
void AXStreamSetImgFormat(NSString *uti);

/// 解码路径：0=全解 + CGContext 重采样（默认）  1=ImageIO thumbnail 直解
void AXStreamSetDecodeMode(int thumb);

/// 静止画面自动降帧开关（默认开）
void AXStreamSetStaticDrop(int on);

/// 静止时的下限帧率（默认 8）。越小越省电、但静止画面下点一下要等更久才看到反应
void AXStreamSetStaticFps(int fps);

/// 发热定位：分段跑。0=正常 1=只截图 2=到缩放为止 3=只编码发送 4=空转
void AXStreamSetBenchMode(int m);

/// 提交手势后暂停抓图的时长（毫秒，默认 0=关闭）
void AXStreamSetPauseMs(int ms);

/// 统计：fps / 码率 / 客户端数 / 编码尺寸 / 最近错误
NSDictionary *AXStreamStats(void);

/// 设置编码参数（码率 bps、目标帧率、最长边像素）
void AXStreamSetParams(int bitrateBps, int fps, int maxSide);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
