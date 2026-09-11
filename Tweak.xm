#import <UIKit/UIKit.h>

// 声明微信类
@interface MMSessionInfo : NSObject
@property(nonatomic, retain) NSString *m_nsUserName;
@property(nonatomic, assign) unsigned int m_uUnReadCount;
@end

@interface NewMainFrameViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property(nonatomic, strong) UITableView *m_tableView;
@end

// 安全的单例，用于在内存中暂存群聊
static NSMutableArray<MMSessionInfo *> *g_foldedGroups = nil;

// 辅助函数：安全判定群聊
static BOOL WCZZIsGroupSession(MMSessionInfo *session) {
    if (!session || ![session isKindOfClass:%c(MMSessionInfo)]) return NO;
    if (!session.m_nsUserName) return NO;
    return [session.m_nsUserName hasSuffix:@"@chatroom"];
}

// -----------------------------------------------------------------------------
// 安全方案：仅拦截 UI Delegate 层，避免干扰数据库与后台逻辑
// -----------------------------------------------------------------------------

%hook NewMainFrameViewController

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSInteger origCount = %orig(tableView, section);
    if (section != 0) return origCount;

    // 清空缓存
    if (!g_foldedGroups) {
        g_foldedGroups = [[NSMutableArray alloc] init];
    }
    [g_foldedGroups removeAllObjects];

    // 获取 Logic 里的原始数组（仅做只读扫描，不修改真实向量）
    id logic = [self valueForKey:@"m_mainFrameLogicController"];
    if (!logic || ![logic respondsToSelector:@selector(cellDataVector)]) {
        return origCount;
    }

    NSMutableArray *realVector = [logic performSelector:@selector(cellDataVector)];
    if (!realVector || ![realVector isKindOfClass:[NSArray class]]) {
        return origCount;
    }

    NSInteger groupCount = 0;
    for (MMSessionInfo *info in realVector) {
        if (WCZZIsGroupSession(info)) {
            [g_foldedGroups addObject:info];
            groupCount++;
        }
    }

    // 没有群聊时走原生逻辑
    if (groupCount == 0) return origCount;

    // 行数 = 原总数 - 群聊数 + 1 (虚拟群助手)
    return origCount - groupCount + 1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0 && indexPath.row == 0 && g_foldedGroups.count > 0) {
        // 自定义群助手入口，不走原生 %orig，彻底避免微信原图与字段空指针崩塌
        static NSString *helperCellID = @"WCZZHelperCell";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:helperCellID];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:helperCellID];
        }

        // 计算未读消息
        unsigned int totalUnread = 0;
        for (MMSessionInfo *info in g_foldedGroups) {
            totalUnread += info.m_uUnReadCount;
        }

        cell.textLabel.text = @"群聊助手";
        cell.textLabel.font = [UIFont boldSystemFontOfSize:16.0];
        
        if (totalUnread > 0) {
            cell.detailTextLabel.text = [NSString stringWithFormat:@"[%u条新消息]", totalUnread];
            cell.detailTextLabel.textColor = [UIColor systemRedColor];
        } else {
            cell.detailTextLabel.text = [NSString stringWithFormat:@"已折叠 %lu 个群聊", (unsigned long)g_foldedGroups.count];
            cell.detailTextLabel.textColor = [UIColor systemGrayColor];
        }

        return cell;
    }

    return %orig(tableView, indexPath);
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0 && indexPath.row == 0 && g_foldedGroups.count > 0) {
        return 70.0; // 虚拟 Cell 高度
    }
    return %orig(tableView, indexPath);
}

%end
