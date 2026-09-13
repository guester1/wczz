#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

@interface NewMainFrameViewController : UIViewController
- (long long)logicGetCountForSection:(long long)section;
- (id)logicGetCellDataAtIndexPath:(id)indexPath;
- (id)logicGetSessionAtIndexPath:(id)indexPath;
- (void)handleSelectIndexPath:(id)indexPath tableView:(id)tableView;
- (void)onLogicOpenSession:(id)session;
- (void)onSessionRebuildEnd;
- (void)viewDidAppear:(BOOL)animated;
@end

@interface MainFrameLogicController : NSObject
- (void)onSessionRebuildEnd;
- (id)getSessionInfoAtIndexPath:(id)indexPath;
- (id)getSessionBaseInfoAtIndexPath:(id)indexPath;
- (unsigned int)getVisibleSessionCount;
- (long long)getSessionCountForSection:(long long)section;
- (id)getCellDataAtIndexPath:(id)indexPath;
- (id)getCellDataByUsrName:(id)username;
- (void)onDidSelectCellAt:(id)indexPath;
@end

@interface WCRedEnvelopesControlLogic : NSObject
- (id)initWithData:(id)data;
@end

@interface WCRedEnvelopesReceiveControlLogic : WCRedEnvelopesControlLogic
- (void)showDetailView;
@end

@interface WCRedEnvelopesRedEnvelopesDetailViewController : UIViewController
- (id)init;
- (void)refreshViewWithData:(id)data;
- (void)viewDidAppear:(BOOL)animated;
- (void)viewDidLoad;
@end
