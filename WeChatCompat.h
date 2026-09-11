#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

@interface MainFrameLogicController : NSObject
- (id)getCellDataByUsrName:(id)username;
- (void)onSessionRebuildEnd;
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
- (void)logicUpdateSession:(id)session;
- (void)onLogicOpenSession:(id)session;
- (void)reloadSessions;
- (void)tableView:(id)tableView didSelectRowAtIndexPath:(id)indexPath;
@end

@interface WCRedEnvelopesRedEnvelopesDetailViewController : UIViewController
- (void)refreshViewWithData:(id)data;
@end
