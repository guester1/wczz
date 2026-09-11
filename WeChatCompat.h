#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

@interface MainFrameLogicController : NSObject
- (unsigned long long)getFilteredSessionCount;
- (id)getFilteredSessionInfo:(unsigned int)index;
- (id)getSessionBaseInfoAtIndexPath:(id)indexPath;
- (id)getSessionInfoAtIndexPath:(id)indexPath;
- (unsigned int)getVisibleSessionCount;
- (long long)getSessionCountForSection:(long long)section;
- (unsigned int)getSessionCount;
- (id)getCellDataByUsrName:(id)username;
- (long long)getFakeCellCount;
- (id)getFakeCellData:(unsigned int)index;
- (void)onDidSelectCellAt:(id)indexPath;
- (void)onSessionRebuildEnd;
@end

@interface NewMainFrameViewController : UIViewController
- (void)reloadSessions;
- (void)onLogicOpenSession:(id)session;
- (void)logicUpdateSession:(id)session;
- (id)logicGetSessionAtIndexPath:(id)indexPath;
@end

@interface WCRedEnvelopesRedEnvelopesDetailViewController : UIViewController
- (void)refreshViewWithData:(id)data;
@end
