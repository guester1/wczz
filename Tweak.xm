#import <UIKit/UIKit.h>

// =============================================================================
// 1. 头文件与微信类接口声明
// =============================================================================

@interface MMSessionInfo : NSObject
@property(nonatomic, retain) NSString *m_nsUserName;
@property(nonatomic, assign) unsigned int m_uUnReadCount;
@property(nonatomic, assign) unsigned int m_uLastMsgTime;
@end

@interface MainFrameLogicController : NSObject
- (NSMutableArray *)cellDataVector;
@end

@interface NewMainFrameViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@end

// 红包详情控制器声明
@interface WCRedEnvelopesDetailViewController : UIViewController
@end

// 全局配置与状态缓存
static BOOL g_enableGroupHelper = YES;
static NSMutableArray<MMSessionInfo *> *g_foldedGroups = nil;

static BOOL WCZZIsGroupSession(MMSessionInfo *session) {
    if (!session || ![session isKindOfClass:[%c(MMSessionInfo) class]]) return NO;
    if (!session.m_nsUserName) return NO;
    return [session.m_nsUserName hasSuffix:@"@chatroom"];
}

// =============================================================================
// 2. 红包详情页面美化与统计增强 (WCRedEnvelopesDetailViewController)
// =============================================================================

%hook WCRedEnvelopesDetailViewController

- (void)viewDidLoad {
    %orig;
    
    // 在红包详情页顶部或合适位置可附加自定义统计提示或样式修改
    self.title = @"红包详情";
}

%end

// =============================================================================
// 3. 群助手二级列表页面 (WCZZGroupHelperViewController)
// =============================================================================

@interface WCZZGroupHelperViewController : UITableViewController
@end

@implementation WCZZGroupHelperViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"群聊助手";
    self.tableView.tableFooterView = [[UIView alloc] init];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return g_foldedGroups ? g_foldedGroups.count : 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"WCZZFoldedGroupCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellID];
    }
    
    if (g_foldedGroups && indexPath.row < g_foldedGroups.count) {
        MMSessionInfo *session = g_foldedGroups[indexPath.row];
        cell.textLabel.text = session.m_nsUserName;
        if (session.m_uUnReadCount > 0) {
            cell.detailTextLabel.text = [NSString stringWithFormat:@"[%u条未读消息]", session.m_uUnReadCount];
            cell.detailTextLabel.textColor = [UIColor systemRedColor];
        } else {
            cell.detailTextLabel.text = @"暂无未读消息";
            cell.detailTextLabel.textColor = [UIColor systemGrayColor];
        }
    }
    return cell;
}

@end

// =============================================================================
// 4. 微信首页主界面折叠 Hook (NewMainFrameViewController)
// =============================================================================

%hook NewMainFrameViewController

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSInteger origCount = %orig(tableView, section);
    if (section != 0 || !g_enableGroupHelper) return origCount;

    if (!g_foldedGroups) {
        g_foldedGroups = [[NSMutableArray alloc] init];
    }
    [g_foldedGroups removeAllObjects];

    MainFrameLogicController *logic = [self valueForKey:@"m_mainFrameLogicController"];
    if (!logic || ![logic respondsToSelector:@selector(cellDataVector)]) {
        return origCount;
    }

    NSMutableArray *realVector = [logic cellDataVector];
    if (!realVector) return origCount;

    for (MMSessionInfo *info in realVector) {
        if (WCZZIsGroupSession(info)) {
            [g_foldedGroups addObject:info];
        }
    }

    if (g_foldedGroups.count == 0) return origCount;

    return origCount - g_foldedGroups.count + 1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section != 0 || !g_enableGroupHelper || g_foldedGroups.count == 0) {
        return %orig(tableView, indexPath);
    }

    // 渲染顶部“群聊助手”入口
    if (indexPath.row == 0) {
        static NSString *helperCellID = @"WCZZGroupHelperCellIdentifier";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:helperCellID];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:helperCellID];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }

        unsigned int totalUnread = 0;
        for (MMSessionInfo *info in g_foldedGroups) {
            totalUnread += info.m_uUnReadCount;
        }

        cell.textLabel.text = @"群聊助手";
        cell.textLabel.font = [UIFont boldSystemFontOfSize:16.0];

        if (totalUnread > 0) {
            cell.detailTextLabel.text = [NSString stringWithFormat:@"[%u条未读消息]", totalUnread];
            cell.detailTextLabel.textColor = [UIColor systemRedColor];
        } else {
            cell.detailTextLabel.text = [NSString stringWithFormat:@"已折叠 %lu 个群聊", (unsigned long)g_foldedGroups.count];
            cell.detailTextLabel.textColor = [UIColor systemGrayColor];
        }
        return cell;
    }

    // 非第0行做正常的虚拟索引重映射
    MainFrameLogicController *logic = [self valueForKey:@"m_mainFrameLogicController"];
    NSMutableArray *realVector = [logic cellDataVector];
    
    NSInteger targetVirtualIndex = indexPath.row - 1;
    NSInteger currentVisibleCount = 0;
    NSInteger mappedRealIndex = -1;

    for (NSInteger i = 0; i < realVector.count; i++) {
        MMSessionInfo *info = realVector[i];
        if (!WCZZIsGroupSession(info)) {
            if (currentVisibleCount == targetVirtualIndex) {
                mappedRealIndex = i;
                break;
            }
            currentVisibleCount++;
        }
    }

    if (mappedRealIndex != -1) {
        NSIndexPath *mappedIndexPath = [NSIndexPath indexPathForRow:mappedRealIndex inSection:indexPath.section];
        return %orig(tableView, mappedIndexPath);
    }

    return %orig(tableView, indexPath);
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0 && g_enableGroupHelper && indexPath.row == 0 && g_foldedGroups.count > 0) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        
        WCZZGroupHelperViewController *helperVC = [[WCZZGroupHelperViewController alloc] init];
        [self.navigationController pushViewController:helperVC animated:YES];
        return;
    }

    MainFrameLogicController *logic = [self valueForKey:@"m_mainFrameLogicController"];
    NSMutableArray *realVector = [logic cellDataVector];
    
    NSInteger targetVirtualIndex = indexPath.row - 1;
    NSInteger currentVisibleCount = 0;
    NSInteger mappedRealIndex = -1;

    for (NSInteger i = 0; i < realVector.count; i++) {
        MMSessionInfo *info = realVector[i];
        if (!WCZZIsGroupSession(info)) {
            if (currentVisibleCount == targetVirtualIndex) {
                mappedRealIndex = i;
                break;
            }
            currentVisibleCount++;
        }
    }

    if (mappedRealIndex != -1) {
        NSIndexPath *mappedIndexPath = [NSIndexPath indexPathForRow:mappedRealIndex inSection:indexPath.section];
        %orig(tableView, mappedIndexPath);
        return;
    }

    %orig(tableView, indexPath);
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0 && g_enableGroupHelper && indexPath.row == 0 && g_foldedGroups.count > 0) {
        return 70.0;
    }
    return %orig(tableView, indexPath);
}

%end
