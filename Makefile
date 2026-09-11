#import <UIKit/UIKit.h>

// =============================================================================
// 1. 头文件与类型声明
// =============================================================================

static NSString *const kWCZZHelperUserName = @"wczz_group_helper_session";
static NSMutableArray<id> *g_foldedSessions = nil;

@interface MMSessionInfo : NSObject
@property(nonatomic, retain) NSString *m_nsUserName;
@property(nonatomic, assign) unsigned int m_uUnReadCount;
@property(nonatomic, assign) unsigned int m_uLastMsgTime;
@end

@interface MainFrameLogicController : NSObject
- (NSMutableArray *)cellDataVector;
- (id)getSessionInfoForIndex:(unsigned int)index;
@end

// =============================================================================
// 2. 辅助工具函数
// =============================================================================

static MMSessionInfo *WCZZGetOrCreateHelperSession(void) {
    static MMSessionInfo *helperSession = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        helperSession = [[%c(MMSessionInfo) alloc] init];
        helperSession.m_nsUserName = kWCZZHelperUserName;
    });
    
    unsigned int totalUnread = 0;
    unsigned int latestTime = 0;
    
    @synchronized (g_foldedSessions) {
        for (MMSessionInfo *info in g_foldedSessions) {
            totalUnread += info.m_uUnReadCount;
            if (info.m_uLastMsgTime > latestTime) {
                latestTime = info.m_uLastMsgTime;
            }
        }
    }
    
    helperSession.m_uUnReadCount = totalUnread;
    helperSession.m_uLastMsgTime = latestTime;
    return helperSession;
}

static BOOL WCZZIsFoldedGroupSession(MMSessionInfo *session) {
    if (!session || ![session respondsToSelector:@selector(m_nsUserName)]) return NO;
    if ([session.m_nsUserName hasSuffix:@"@chatroom"]) {
        return YES;
    }
    return NO;
}

// =============================================================================
// 3. 逻辑层 Hook (MainFrameLogicController)
// =============================================================================

%hook MainFrameLogicController

- (unsigned int)getSessionCountForSection:(unsigned int)section {
    unsigned int origCount = %orig(section);
    if (section != 0) return origCount;

    NSMutableArray *realVector = [self cellDataVector];
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
    NSMutableArray *realVector = [self cellDataVector];
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
    if ([session isEqual:WCZZGetOrCreateHelperSession()]) {
        return;
    }
    
    NSMutableArray *realVector = [self cellDataVector];
    NSUInteger realIndex = [realVector indexOfObject:session];
    if (realIndex != NSNotFound) {
        %orig((unsigned int)realIndex);
    }
}

%end

// =============================================================================
// 4. 界面层 Hook (NewMainFrameViewController)
// =============================================================================

%hook NewMainFrameViewController

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    MainFrameLogicController *logic = [self valueForKey:@"m_mainFrameLogicController"];
    MMSessionInfo *session = [logic getSessionInfoForIndex:(unsigned int)indexPath.row];
    
    if ([session.m_nsUserName isEqualToString:kWCZZHelperUserName]) {
        static NSString *cellIdentifier = @"WCZZGroupHelperCell";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellIdentifier];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellIdentifier];
        }
        
        cell.textLabel.text = @"群聊助手";
        cell.textLabel.font = [UIFont boldSystemFontOfSize:16.0];
        
        if (session.m_uUnReadCount > 0) {
            cell.detailTextLabel.text = [NSString stringWithFormat:@"[%u条未读消息]", session.m_uUnReadCount];
            cell.detailTextLabel.textColor = [UIColor systemRedColor];
        } else {
            cell.detailTextLabel.text = @"暂无新消息";
            cell.detailTextLabel.textColor = [UIColor systemGrayColor];
        }
        
        return cell;
    }
    
    return %orig(tableView, indexPath);
}

%end
