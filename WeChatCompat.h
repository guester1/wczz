#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

@interface MainFrameLogicController : NSObject
- (id)getSessionInfoAtIndexPath:(id)indexPath;
- (id)getCellDataAtIndexPath:(id)indexPath;
- (long long)getSessionCountForSection:(long long)section;
@end

@interface MMNewSessionMgr : NSObject
- (id)GetSessionInfoList;
- (id)GetSessionByUserName:(id)username;
- (void)ChangeSessionUnReadCount:(id)username to:(unsigned int)count;
@end

@interface NewMainFrameViewController : UIViewController
- (long long)logicGetCountForSection:(long long)section;
- (id)logicGetCellDataAtIndexPath:(id)indexPath;
- (id)logicGetSessionAtIndexPath:(id)indexPath;
- (void)onLogicOpenSession:(id)session;
- (void)reloadSessions;
- (void)tableView:(id)tableView didSelectRowAtIndexPath:(id)indexPath;
- (id)tableView:(id)tableView cellForRowAtIndexPath:(id)indexPath;
- (long long)tableView:(id)tableView numberOfRowsInSection:(long long)section;
@end

@interface WCRedEnvelopesRedEnvelopesDetailViewController : UIViewController
- (void)refreshViewWithData:(id)data;
- (void)viewDidAppear:(BOOL)animated;
@end
