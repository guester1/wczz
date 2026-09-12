#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

@interface MainFrameLogicController : NSObject
- (id)getSessionInfoAtIndexPath:(id)indexPath;
- (id)getCellDataAtIndexPath:(id)indexPath;
- (long long)getSessionCountForSection:(long long)section;
- (long long)getFakeCellCount;
- (id)getFakeCellData:(unsigned int)index;
- (void)onDidSelectCellAt:(id)indexPath;
- (void)onSessionRebuildEnd;
@end

@interface MMNewSessionMgr : NSObject
- (id)GetSessionInfoList;
- (id)GetSessionByUserName:(id)username;
- (void)ChangeSessionUnReadCount:(id)username to:(unsigned int)count;
@end

@interface NewMainFrameViewController : UIViewController
- (void)onLogicOpenSession:(id)session;
- (void)reloadSessions;
- (void)handleSelectIndexPath:(id)indexPath tableView:(id)tableView;
@end



@interface WCRedEnvelopesRedEnvelopesDetailViewController : UIViewController
- (void)refreshViewWithData:(id)data;
- (void)viewDidAppear:(BOOL)animated;
@end
