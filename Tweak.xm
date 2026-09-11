#import <UIKit/UIKit.h>
#import "WeChatCompat.h"

// =============================================================================
// 1. 全局常量与状态缓存
// =============================================================================

static NSString *const kWCZZHelperUserName = @"wczz_group_helper_session";
static NSMutableArray<MMSessionInfo *> *g_foldedSessions = nil;

static BOOL WCZZIsFoldedGroupSession(MMSessionInfo *session) {
    if (!session || ![session respondsToSelector:@selector(m_nsUserName)]) return NO;
    if (session.m_nsUserName && [session.m_nsUserName hasSuffix:@"@chatroom"]) {
        return YES;
    }
    return NO;
}

// 安全创建/获取群助手虚拟 Session
static MMSessionInfo *WCZZGetOrCreateHelperSession(void) {
    static MMSessionInfo *helperSession = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class sessionClass = %c(MMSessionInfo);
        if (sessionClass) {
            helperSession = [[sessionClass alloc] init];
            if ([helperSession respondsToSelector:@selector(setM_nsUserName:)]) {
                helperSession.m_nsUserName = kWCZZHelperUserName;
            }
        }
    });
    
    unsigned int totalUnread = 0;
    unsigned int latestTime = 0;
    
    if (g_foldedSessions) {
        @synchronized (g_foldedSessions) {
            for (MMSessionInfo *info in g_foldedSessions) {
                if ([info respondsToSelector:@selector(m_uUnReadCount)]) {
                    totalUnread += info.m_uUnReadCount;
                }
                if ([info respondsToSelector:@selector(m_uLastMsgTime)]) {
                    if (info.m_uLastMsgTime > latestTime) {
                        latestTime = info.m_uLastMsgTime;
                    }
                }
            }
        }
    }
    
    if ([helperSession respondsToSelector:@selector(setM_uUnReadCount:)]) {
        helperSession.m_uUnReadCount = totalUnread;
    }
    if ([helperSession respondsToSelector:@selector(setM_uLastMsgTime:)]) {
        helperSession.m_uLastMsgTime = latestTime;
    }
    return helperSession;
}

// =============================================================================
// 2. 红包详情与界面增强 Hook
// =============================================================================

%hook WCRedEnvelopesDetailViewController

- (void)viewDidLoad {
    %orig;
    
    // 安全读取红包详情数据，展示统计信息
    Ivar dataIvar = class_getInstanceVariable([self class], "m_data");
    if (dataIvar) {
        id data = object_getIvar(self, dataIvar);
        if (data && [data respondsToSelector:@selector(m_structRedEnvelopesDetail)]) {
            id detail = [data valueForKey:@"m_structRedEnvelopesDetail"];
            if (detail) {
                // 自定义红包详情页标题或数据统计展示
                self.title = @"红包详情";
            }
        }
    }
}

%end

// =============================================================================
// 3. 底层会话控制器 Hook (MainFrameLogicController)
// =============================================================================

%hook MainFrameLogicController

- (unsigned int)getSessionCountForSection:(unsigned int)section {
    unsigned int origCount = %orig(section);
    if (section != 0) return origCount;

    if (![self respondsToSelector:@selector(cellDataVector)]) {
        return origCount;
    }

    NSMutableArray *realVector = [self cellDataVector];
    if (!realVector) return origCount;

    if (!g_foldedSessions) {
        g_foldedSessions = [[NSMutableArray alloc] init];
    }
    
    @synchronized (g_foldedSessions) {
        [g_foldedSessions removeAllObjects];
        unsigned int foldedCount = 0;
        
        for (MMSessionInfo *info in realVector) {
            if (WCZZIsFoldedGroupSession(info)) {
                [g_foldedSessions addObject:info];
                foldedCount++;
            }
        }
        
        if (foldedCount == 0) return origCount;
        return origCount - foldedCount + 1;
    }
}

- (id)getSessionInfoForIndex:(unsigned int)index {
    if (![self respondsToSelector:@selector(cellDataVector)]) {
        return %orig(index);
    }

    NSMutableArray *realVector = [self cellDataVector];
    if (!realVector) return %orig(index);

    NSMutableArray *visibleSessions = [NSMutableArray array];
    BOOL hasFoldedGroup = NO;
    
    for (MMSessionInfo *info in realVector) {
        if (WCZZIsFoldedGroupSession(info)) {
            hasFoldedGroup = YES;
        } else {
            [visibleSessions addObject:info];
        }
    }
    
    if (!hasFoldedGroup) {
        return %orig(index);
    }
    
    if (index == 0) {
        return WCZZGetOrCreateHelperSession();
    }
    
    unsigned int mappedIndex = index - 1;
    if (mappedIndex < visibleSessions.count) {
        return visibleSessions[mappedIndex];
    }
    
    return nil;
}

- (void)removeSessionAtIndex:(unsigned int)index {
    id session = [self getSessionInfoForIndex:index];
    if (session && [session isEqual:WCZZGetOrCreateHelperSession()]) {
        return;
    }
    
    if ([self respondsToSelector:@selector(cellDataVector)]) {
        NSMutableArray *realVector = [self cellDataVector];
        if (realVector && session) {
            NSUInteger realIndex = [realVector indexOfObject:session];
            if (realIndex != NSNotFound) {
                %orig((unsigned int)realIndex);
                return;
            }
        }
    }
    
    %orig(index);
}

%end

// =============================================================================
// 4. 视图控制器 Hook (NewMainFrameViewController)
// =============================================================================

%hook NewMainFrameViewController

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0 && [self respondsToSelector:@selector(m_mainFrameLogicController)]) {
        MainFrameLogicController *logic = [self valueForKey:@"m_mainFrameLogicController"];
        if (logic && [logic respondsToSelector:@selector(getSessionInfoForIndex:)]) {
            MMSessionInfo *session = [logic getSessionInfoForIndex:(unsigned int)indexPath.row];
            
            if (session && [session respondsToSelector:@selector(m_nsUserName)] && 
                [session.m_nsUserName isEqualToString:kWCZZHelperUserName]) {
                
                static NSString *cellIdentifier = @"WCZZGroupHelperCell";
                UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellIdentifier];
                if (!cell) {
                    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellIdentifier];
                    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                }
                
                cell.textLabel.text = @"群聊助手";
                cell.textLabel.font = [UIFont boldSystemFontOfSize:16.0];
                
                if ([session respondsToSelector:@selector(m_uUnReadCount)] && session.m_uUnReadCount > 0) {
                    cell.detailTextLabel.text = [NSString stringWithFormat:@"[%u条未读消息]", session.m_uUnReadCount];
                    cell.detailTextLabel.textColor = [UIColor systemRedColor];
                } else {
                    cell.detailTextLabel.text = [NSString stringWithFormat:@"已折叠 %lu 个群聊", (unsigned long)(g_foldedSessions ? g_foldedSessions.count : 0)];
                    cell.detailTextLabel.textColor = [UIColor systemGrayColor];
                }
                
                return cell;
            }
        }
    }
    
    return %orig(tableView, indexPath);
}

%end
