#import <UIKit/UIKit.h>
#import "WeChatCompat.h"

// =============================================================================
// 全局常量与状态管理
// =============================================================================

static NSString *const kWCZZGroupHelperID = @"wczz_group_helper_session";
static NSMutableArray *g_foldedSessionsList = nil;

// 判断是否为需要折叠的群聊 Session
static BOOL WCZZIsTargetGroupSession(MMSessionInfo *session) {
    if (!session) return NO;
    if ([session respondsToSelector:@selector(m_nsUserName)]) {
        NSString *usrName = session.m_nsUserName;
        if (usrName && [usrName hasSuffix:@"@chatroom"]) {
            return YES;
        }
    }
    return NO;
}

// 动态计算/生成群助手虚拟 Session
static MMSessionInfo *WCZZGetOrCreateHelperSession(void) {
    static MMSessionInfo *helperSession = nil;
    if (!helperSession) {
        helperSession = [[%c(MMSessionInfo) alloc] init];
        if ([helperSession respondsToSelector:@selector(setM_nsUserName:)]) {
            helperSession.m_nsUserName = kWCZZGroupHelperID;
        }
    }
    
    unsigned int totalUnread = 0;
    unsigned int maxTime = 0;
    
    if (g_foldedSessionsList) {
        @synchronized (g_foldedSessionsList) {
            for (MMSessionInfo *info in g_foldedSessionsList) {
                if ([info respondsToSelector:@selector(m_uUnReadCount)]) {
                    totalUnread += info.m_uUnReadCount;
                }
                if ([info respondsToSelector:@selector(m_uLastMsgTime)]) {
                    if (info.m_uLastMsgTime > maxTime) {
                        maxTime = info.m_uLastMsgTime;
                    }
                }
            }
        }
    }
    
    if ([helperSession respondsToSelector:@selector(setM_uUnReadCount:)]) {
        helperSession.m_uUnReadCount = totalUnread;
    }
    if ([helperSession respondsToSelector:@selector(setM_uLastMsgTime:)]) {
        helperSession.m_uLastMsgTime = maxTime;
    }
    
    return helperSession;
}

// =============================================================================
// Hook 核心逻辑适配
// =============================================================================

%hook MMBaseSessionLogicController

// 拦截会话列表数据源，重构展示逻辑
- (NSMutableArray *)getSessionInfoList {
    NSMutableArray *origList = %orig;
    if (!origList || origList.count == 0) return origList;

    if (!g_foldedSessionsList) {
        g_foldedSessionsList = [[NSMutableArray alloc] init];
    }

    NSMutableArray *filteredList = [NSMutableArray array];
    @synchronized (g_foldedSessionsList) {
        [g_foldedSessionsList removeAllObjects];

        for (MMSessionInfo *info in origList) {
            if (WCZZIsTargetGroupSession(info)) {
                [g_foldedSessionsList addObject:info];
            } else {
                [filteredList addObject:info];
            }
        }

        // 如果存在需要折叠的群聊，将群助手插入到首位
        if (g_foldedSessionsList.count > 0) {
            MMSessionInfo *helperSession = WCZZGetOrCreateHelperSession();
            [filteredList insertObject:helperSession atIndex:0];
        }
    }

    return filteredList;
}

%end

// =============================================================================
// 界面 UI 渲染 Hook
// =============================================================================

%hook NewMainFrameViewController

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = %orig(tableView, indexPath);
    
    // 获取当前 Row 对应的 Session 数据
    if ([self respondsToSelector:@selector(m_mainFrameLogicController)]) {
        id logicController = [self valueForKey:@"m_mainFrameLogicController"];
        if (logicController && [logicController respondsToSelector:@selector(getSessionInfoForIndex:)]) {
            MMSessionInfo *session = [logicController getSessionInfoForIndex:(unsigned int)indexPath.row];
            
            // 自定义“群聊助手”Cell 样式
            if (session && [session.m_nsUserName isEqualToString:kWCZZGroupHelperID]) {
                cell.textLabel.text = @"群聊助手";
                
                if (session.m_uUnReadCount > 0) {
                    cell.detailTextLabel.text = [NSString stringWithFormat:@"[%u条未读消息]", session.m_uUnReadCount];
                    cell.detailTextLabel.textColor = [UIColor systemRedColor];
                } else {
                    NSUInteger count = g_foldedSessionsList ? g_foldedSessionsList.count : 0;
                    cell.detailTextLabel.text = [NSString stringWithFormat:@"已折叠 %lu 个群聊", (unsigned long)count];
                    cell.detailTextLabel.textColor = [UIColor systemGrayColor];
                }
            }
        }
    }
    
    return cell;
}

%end
