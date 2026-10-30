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
void AXAgentStartSticky(void);
BOOL AXAgentGesture(const double *xy, const double *t, int n);
BOOL AXAgentSwipe(double x1, double y1, double x2, double y2, double dur);
BOOL AXAgentLongPress(double x, double y, double dur);
NSString *AXAgentShot(double maxSide, double quality);
NSString *AXAgentProbeRecording(void);
NSString *AXAgentDumpTree(int maxNodes);
NSString *AXProbeDeviceInfo(void);
BOOL AXAgentSetAppStateTimeout(double v);
NSString *AXAgentShotLowLevel(int mode, double quality);
#import "AXStream.h"
