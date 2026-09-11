#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "WeChatCompat.h"

// 全局静态变量
static NSString *const kWCZZHelperUserName = @"wczz_group_helper_session";
static NSMutableArray *g_foldedSessions = nil;

// 安全判断是否为群聊 Session
static BOOL WCZZIsFoldedGroupSession(id session) {
    if (!session) return NO;
    if ([session respondsToSelector:@selector(m_nsUserName)]) {
        NSString *userName = [session performSelector:@selector(m_nsUserName)];
        if (userName && [userName hasSuffix:@"@chatroom"]) {
            return YES;
        }
    }
    return NO;
}

// 动态生成/更新助手 Session
static id WCZZGetOrCreateHelperSession(void) {
    static id helperSession = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class sessionClass = objc_getClass("MMSessionInfo");
        if (sessionClass) {
            helperSession = [[sessionClass alloc] init];
            if ([helperSession respondsToSelector:@selector(setM_nsUserName:)]) {
                [helperSession performSelector:@selector(setM_nsUserName:) withObject:kWCZZHelperUserName];
            }
        }
    });
    
    return helperSession;
}

// =============================================================================
// 1. 红包功能 Hook (保留原有逻辑)
// =============================================================================

%hook WCRedEnvelopesDetailViewController

- (void)viewDidLoad {
    %orig;
    
    Ivar dataIvar = class_getInstanceVariable([self class], "m_data");
    if (dataIvar) {
        id data = object_getIvar(self, dataIvar);
        if (data && [data respondsToSelector:@selector(m_structRedEnvelopesDetail)]) {
            ((UIViewController *)self).title = @"红包详情";
        }
    }
}

%end

// =============================================================================
// 2. 群聊折叠 Hook (使用 id 类型规避 @class 编译报错)
// =============================================================================

%hook MainFrameLogicController

- (unsigned int)getSessionCountForSection:(unsigned int)section {
    unsigned int origCount = %orig(section);
    if (section != 0) return origCount;

    if (![self respondsToSelector:@selector(cellDataVector)]) return origCount;
    NSMutableArray *realVector = [self performSelector:@selector(cellDataVector)];
    if (!realVector) return origCount;

    if (!g_foldedSessions) {
        g_foldedSessions = [[NSMutableArray alloc] init];
    }
    
    @synchronized (g_foldedSessions) {
        [g_foldedSessions removeAllObjects];
        unsigned int foldedCount = 0;
        
        for (id info in realVector) {
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
    if (![self respondsToSelector:@selector(cellDataVector)]) return %orig(index);
    NSMutableArray *realVector = [self performSelector:@selector(cellDataVector)];
    if (!realVector) return %orig(index);

    NSMutableArray *visibleSessions = [NSMutableArray array];
    BOOL hasFoldedGroup = NO;
    
    for (id info in realVector) {
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
// 3. UI 视图渲染 Hook
// =============================================================================

%hook NewMainFrameViewController

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = %orig(tableView, indexPath);
    
    if (indexPath.section == 0) {
        if ([self respondsToSelector:@selector(m_mainFrameLogicController)]) {
            id logic = [self valueForKey:@"m_mainFrameLogicController"];
            if (logic && [logic respondsToSelector:@selector(getSessionInfoForIndex:)]) {
                id session = [logic performSelector:@selector(getSessionInfoForIndex:) withObject:@(indexPath.row)];
                
                if (session && [session respondsToSelector:@selector(m_nsUserName)]) {
                    NSString *usrName = [session performSelector:@selector(m_nsUserName)];
                    if ([usrName isEqualToString:kWCZZHelperUserName]) {
                        cell.textLabel.text = @"群聊助手";
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
