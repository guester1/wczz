#import <UIKit/UIKit.h>
#import "WeChatCompat.h"

// =============================================================================
// 轻量接口声明（补充类型定义，避免 Clang 报错）
// =============================================================================

@interface MMSessionInfo : NSObject
@property (nonatomic, retain) NSString *m_nsUserName;
@property (nonatomic, assign) unsigned int m_uUnReadCount;
@property (nonatomic, assign) unsigned int m_uLastMsgTime;
@end

@interface MainFrameLogicController : NSObject
- (NSMutableArray *)cellDataVector;
- (id)getSessionInfoForIndex:(unsigned int)index;
@end

@interface NewMainFrameViewController : UIViewController
@property (nonatomic, strong) MainFrameLogicController *m_mainFrameLogicController;
@end

// =============================================================================
// 全局静态变量
// =============================================================================

static NSString *const kWCZZHelperUserName = @"wczz_group_helper_session";
static NSMutableArray<MMSessionInfo *> *g_foldedSessions = nil;

// 校验群聊 Session
static BOOL WCZZIsFoldedGroupSession(MMSessionInfo *session) {
    if (!session) return NO;
    if ([session respondsToSelector:@selector(m_nsUserName)]) {
        NSString *userName = session.m_nsUserName;
        if (userName && [userName hasSuffix:@"@chatroom"]) {
            return YES;
        }
    }
    return NO;
}

// 动态获取/创建群助手虚拟 Session
static MMSessionInfo *WCZZGetOrCreateHelperSession(void) {
    static MMSessionInfo *helperSession = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        helperSession = [[%c(MMSessionInfo) alloc] init];
        if ([helperSession respondsToSelector:@selector(setM_nsUserName:)]) {
            helperSession.m_nsUserName = kWCZZHelperUserName;
        }
    });
    
    unsigned int totalUnread = 0;
    unsigned int latestTime = 0;
    
    if (g_foldedSessions) {
        @synchronized (g_foldedSessions) {
            for (MMSessionInfo *info in g_foldedSessions) {
                if ([info respondsToSelector:@selector(m_uUnReadCount)]) {
                    totalUnread += (unsigned int)info.m_uUnReadCount;
                }
                if ([info respondsToSelector:@selector(m_uLastMsgTime)]) {
                    unsigned int msgTime = (unsigned int)info.m_uLastMsgTime;
                    if (msgTime > latestTime) {
                        latestTime = msgTime;
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
// 1. 红包功能 Hook (已保留)
// =============================================================================

%hook WCRedEnvelopesDetailViewController

- (void)viewDidLoad {
    %orig;
    
    Ivar dataIvar = class_getInstanceVariable([self class], "m_data");
    if (dataIvar) {
        id data = object_getIvar(self, dataIvar);
        if (data && [data respondsToSelector:@selector(m_structRedEnvelopesDetail)]) {
            self.title = @"红包详情";
        }
    }
}

%end

// =============================================================================
// 2. 群聊助手 - 核心逻辑 Hook (已保留)
// =============================================================================

%hook MainFrameLogicController

- (unsigned int)getSessionCountForSection:(unsigned int)section {
    unsigned int origCount = %orig(section);
    if (section != 0) return origCount;

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

%end

// =============================================================================
// 3. 群聊助手 - UI 渲染 Hook (已保留)
// =============================================================================

%hook NewMainFrameViewController

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = %orig(tableView, indexPath);
    
    if (indexPath.section == 0) {
        if ([self respondsToSelector:@selector(m_mainFrameLogicController)]) {
            MainFrameLogicController *logic = [self valueForKey:@"m_mainFrameLogicController"];
            if (logic && [logic respondsToSelector:@selector(getSessionInfoForIndex:)]) {
                MMSessionInfo *session = [logic getSessionInfoForIndex:(unsigned int)indexPath.row];
                
                if (session && [session.m_nsUserName isEqualToString:kWCZZHelperUserName]) {
                    cell.textLabel.text = @"群聊助手";
                    
                    if (session.m_uUnReadCount > 0) {
                        cell.detailTextLabel.text = [NSString stringWithFormat:@"[%u条未读消息]", (unsigned int)session.m_uUnReadCount];
                        cell.detailTextLabel.textColor = [UIColor systemRedColor];
                    } else {
                        NSUInteger count = g_foldedSessions ? g_foldedSessions.count : 0;
                        cell.detailTextLabel.text = [NSString stringWithFormat:@"已折叠 %lu 个群聊", (unsigned long)count];
                        cell.detailTextLabel.textColor = [UIColor systemGrayColor];
                    }
                }
            }
        }
    }
    
    return cell;
}

%end
