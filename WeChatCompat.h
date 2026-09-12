#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

@interface NewMainFrameViewController : UIViewController
- (long long)logicGetCountForSection:(long long)section;
- (id)logicGetSessionAtIndexPath:(id)indexPath;
- (long long)tableView:(id)tableView numberOfRowsInSection:(long long)section;
- (id)tableView:(id)tableView cellForRowAtIndexPath:(id)indexPath;
- (double)tableView:(id)tableView heightForRowAtIndexPath:(id)indexPath;
- (void)tableView:(id)tableView didSelectRowAtIndexPath:(id)indexPath;
- (void)onSessionRebuildEnd;
- (void)reloadSessions;
@end

@interface WCRedEnvelopesRedEnvelopesDetailViewController : UIViewController
- (void)refreshViewWithData:(id)data;
- (void)viewDidAppear:(BOOL)animated;
@end
