#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

@interface NewMainFrameViewController : UIViewController
- (void)onLogicOpenSession:(id)session;
- (void)onSessionRebuildEnd;
- (void)reloadSessions;
- (void)viewDidAppear:(BOOL)animated;
@end

@interface MMNewSessionMgr : NSObject
- (BOOL)shouldFoldSession:(id)session;
- (void)foldSessionByNames:(id)names;
@end

@interface MainFrameLogicController : NSObject
- (void)onSessionRebuildEnd;
- (id)getFakeCellData:(unsigned int)index;
- (void)foldSessionUsernames:(id)names animate:(BOOL)animated;
- (void)unfoldAllSessions;
@end

@interface WCRedEnvelopesRedEnvelopesDetailViewController : UIViewController
- (void)refreshViewWithData:(id)data;
- (void)viewDidAppear:(BOOL)animated;
@end
