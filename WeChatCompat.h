#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

// Compile-time shims for private WeChat classes. These declarations do not
// replace or modify the runtime classes; Logos still hooks the real classes.
@interface MainFrameLogicController : NSObject
- (unsigned long long)getFilteredSessionCount;
- (id)getFilteredSessionInfo:(unsigned int)index;
- (long long)getFakeCellCount;
- (id)getFakeCellData:(unsigned int)index;
- (void)onDidSelectCellAt:(id)indexPath;
- (void)onSessionRebuildEnd;
@end

@interface NewMainFrameViewController : UIViewController
- (void)reloadSessions;
- (void)onLogicOpenSession:(id)session;
- (void)logicUpdateSession:(id)session;
@end

@interface NewSettingViewController : UIViewController
@end
