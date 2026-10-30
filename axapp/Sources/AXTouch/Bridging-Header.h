#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "AXMainViewController.h"
NSString *AXSafeCall(void (^block)(void));
NSString *AXStartWDAServer(void);
NSString *AXProbeDaemonSession(void);
void AXStartWDAServerThread(NSString **outLog);
void AXLoadXCTestThread(void);
NSString *AXTestLocalSocket(void);
NSString *AXTestLockdownTCP(void);
NSString *AXScanLoopbackPorts(void);
NSString *AXBootstrapProbe(void);
NSString *AXRunRSDProbe(void);
BOOL AXAgentBootstrapNow(void);
BOOL AXAgentTap(double x, double y);
BOOL AXAgentIsReady(void);
NSString *AXAgentLastError(void);
NSString *AXAgentLogPath(void);
BOOL AXAgentLogClear(long long *outFreedBytes);
void AXAgentStartSticky(void);
BOOL AXAgentGesture(const double *xy, const double *t, int n);
BOOL AXAgentSwipe(double x1, double y1, double x2, double y2, double dur);
BOOL AXAgentLongPress(double x, double y, double dur);
NSString *AXAgentShot(double maxSide, double quality);
NSString *AXAgentProbeRecording(void);
NSString *AXAgentDumpTree(int maxNodes);
NSString *AXProbeDeviceInfo(void);
NSString *AXLockdownUDID(void);
NSString *AXLockdownUDIDStart(void);
NSString *AXLockdownUDIDResult(void);
BOOL AXAgentSetAppStateTimeout(double v);
BOOL AXAgentIsBootstrapping(void);
BOOL AXAgentPressHome(void);
BOOL AXAgentPinch(double cx, double cy, double startGap, double endGap, double dur);
BOOL AXAgentTypeText(NSString *text);
BOOL AXAgentKey(NSString *key, unsigned long mods);
BOOL AXAgentPaste(NSString *text);
BOOL AXAgentPasteboardSet(NSString *text);
NSString *AXAgentPasteboardGet(void);
NSString *AXAgentTouchSeq(int mode, double x1, double y1, double x2, double y2, int steps, int gapMs);
NSString *AXAgentShotLowLevel(int mode, double quality);
#import "AXStream.h"
