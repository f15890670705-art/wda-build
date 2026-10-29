#import <Foundation/Foundation.h>
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
