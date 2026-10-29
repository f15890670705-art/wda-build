#import <Foundation/Foundation.h>
NSString *AXSafeCall(void (^block)(void));
NSString *AXStartWDAServer(void);
NSString *AXProbeDaemonSession(void);
void AXStartWDAServerThread(NSString **outLog);
void AXLoadXCTestThread(void);
