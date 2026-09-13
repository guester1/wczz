#import "WeChatCompat.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Foundation/Foundation.h>
#import <stdarg.h>
#import <objc/message.h>
#import <objc/runtime.h>

// wczz 1.0-29
// Independent implementation for WeChat 8.0.75.
// The main-list implementation works at MainFrameLogicController's logical
// session boundary instead of fighting UITableView or WeChat's native fold UI.

static NSString * const WCZZPluginEnabledKey = @"wczz.plugin.enabled";
static NSString * const WCZZGroupEnabledKey  = @"wczz.group.enabled";
static NSString * const WCZZGroupTopKey      = @"wczz.group.top";
static NSString * const WCZZCommonRoomsKey   = @"wczz.group.commonRooms";
static NSString * const WCZZRedDetailKey     = @"wczz.redDetail.enabled";
static NSString * const WCZZGroupAvatarKey   = @"wczz.group.avatar";
static NSString * const WCZZDebugEnabledKey  = @"wczz.debug.enabled";
static NSString * const WCZZDebugLogsKey     = @"wczz.debug.logs";
static NSString * const WCZZGroupUserName    = @"wczz_group_helper";

static BOOL WCZZBool(NSString *key, BOOL fallback) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    return v ? [v boolValue] : fallback;
}
static void WCZZSetBool(NSString *key, BOOL value) {
    [[NSUserDefaults standardUserDefaults] setBool:value forKey:key];
}
static BOOL WCZZEnabled(void) { return WCZZBool(WCZZPluginEnabledKey, YES); }
static BOOL WCZZDebugEnabled(void) { return WCZZBool(WCZZDebugEnabledKey, NO); }
static void WCZZReloadMainList(void);
static void WCZZInvalidateMainLogicCache(void) { WCZZReloadMainList(); }
static NSArray *WCZZCommonRooms(void) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:WCZZCommonRoomsKey];
    return [v isKindOfClass:[NSArray class]] ? v : @[];
}
static void WCZZSetCommonRooms(NSArray *rooms) {
    [[NSUserDefaults standardUserDefaults] setObject:rooms ?: @[] forKey:WCZZCommonRoomsKey];
}
static NSMutableArray *WCZZDebugLogMemory = nil;
static NSArray *WCZZDebugLogs(void) {
    if (WCZZDebugLogMemory) return [WCZZDebugLogMemory copy];
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:WCZZDebugLogsKey];
    if ([v isKindOfClass:[NSArray class]]) {
        WCZZDebugLogMemory = [v mutableCopy];
        return [WCZZDebugLogMemory copy];
    }
    WCZZDebugLogMemory = [NSMutableArray array];
    return @[];
}
static void WCZZFlushDebugLogs(void);
static void WCZZClearDebugLogs(void) {
    WCZZDebugLogMemory = [NSMutableArray array];
    WCZZFlushDebugLogs();
}
static void WCZZFlushDebugLogs(void) {
    NSArray *logs = WCZZDebugLogMemory ?: @[];
    [[NSUserDefaults standardUserDefaults] setObject:logs forKey:WCZZDebugLogsKey];
}
static void WCZZLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[wczz] %@", msg);
    if (!WCZZDebugEnabled()) return;
    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"[%@] %@", [df stringFromDate:[NSDate date]], msg ?: @""];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!WCZZDebugLogMemory) {
            id saved = [[NSUserDefaults standardUserDefaults] objectForKey:WCZZDebugLogsKey];
            WCZZDebugLogMemory = [saved isKindOfClass:[NSArray class]] ? [saved mutableCopy] : [NSMutableArray array];
        }
        [WCZZDebugLogMemory addObject:line];
        if (WCZZDebugLogMemory.count > 500) [WCZZDebugLogMemory removeObjectsInRange:NSMakeRange(0, WCZZDebugLogMemory.count - 500)];
    });
}

static id WCZZValue(id obj, NSString *key) {
    if (!obj) return nil;
    @try { return [obj valueForKey:key]; } @catch (__unused NSException *e) { return nil; }
}
static NSString *WCZZUsername(id session) {
    id v = WCZZValue(session, @"m_nsUserName");
    return [v isKindOfClass:[NSString class]] ? v : nil;
}
static id WCZZContact(id session) { return WCZZValue(session, @"m_contact"); }
static BOOL WCZZIsGroupUsername(NSString *username) {
    return [username isKindOfClass:[NSString class]] && username.length > 0 && [username hasSuffix:@"@chatroom"];
}
static BOOL WCZZIsCommonRoom(NSString *username) {
    return username.length && [WCZZCommonRooms() containsObject:username];
}
static BOOL WCZZShouldFold(id session) {
    if (!WCZZEnabled() || !WCZZBool(WCZZGroupEnabledKey, YES) || !session) return NO;
    NSString *u = WCZZUsername(session);
    return WCZZIsGroupUsername(u) && !WCZZIsCommonRoom(u);
}
static NSString *WCZZDisplayName(id contact) {
    SEL s = NSSelectorFromString(@"getContactDisplayName");
    if (contact && [contact respondsToSelector:s]) {
        @try {
            id n = ((id (*)(id, SEL))objc_msgSend)(contact, s);
            if ([n isKindOfClass:[NSString class]] && [n length]) return n;
        } @catch (__unused NSException *e) {}
    }
    id n = WCZZValue(contact, @"m_nsNickName");
    if ([n isKindOfClass:[NSString class]] && [n length]) return n;
    return @"群聊";
}

#pragma mark - Session service

static NSArray *WCZZSessionList(void) {
    Class ctxClass = objc_getClass("MMContext");
    Class mgrClass = objc_getClass("MMNewSessionMgr");
    SEL current = NSSelectorFromString(@"currentContext");
    SEL service = NSSelectorFromString(@"getService:");
    SEL listSel = NSSelectorFromString(@"GetSessionInfoList");
    if (!ctxClass || !mgrClass || ![ctxClass respondsToSelector:current]) return @[];
    id ctx = ((id (*)(id, SEL))objc_msgSend)(ctxClass, current);
    id center = WCZZValue(ctx, @"serviceCenter");
    if (!center || ![center respondsToSelector:service]) return @[];
    id mgr = ((id (*)(id, SEL, Class))objc_msgSend)(center, service, mgrClass);
    if (!mgr || ![mgr respondsToSelector:listSel]) return @[];
    id list = ((id (*)(id, SEL))objc_msgSend)(mgr, listSel);
    return [list isKindOfClass:[NSArray class]] ? list : @[];
}
static void WCZZMarkRead(NSString *username) {
    if (!username.length) return;
    Class ctxClass = objc_getClass("MMContext");
    Class mgrClass = objc_getClass("MMNewSessionMgr");
    SEL current = NSSelectorFromString(@"currentContext");
    SEL service = NSSelectorFromString(@"getService:");
    SEL clear = NSSelectorFromString(@"ChangeSessionUnReadCount:to:");
    if (!ctxClass || !mgrClass || ![ctxClass respondsToSelector:current]) return;
    id ctx = ((id (*)(id, SEL))objc_msgSend)(ctxClass, current);
    id center = WCZZValue(ctx, @"serviceCenter");
    id mgr = center && [center respondsToSelector:service] ? ((id (*)(id, SEL, Class))objc_msgSend)(center, service, mgrClass) : nil;
    if (!mgr || ![mgr respondsToSelector:clear]) {
        WCZZLog(@"markRead: selector missing");
        return;
    }
    @try { ((void (*)(id, SEL, id, unsigned int))objc_msgSend)(mgr, clear, username, 0U); } @catch (__unused NSException *e) {
        WCZZLog(@"markRead: exception for %@", username);
    }
}

static UIViewController *WCZZFindMainController(void) {
    Class cls = objc_getClass("NewMainFrameViewController");
    if (!cls) return nil;
    UIApplication *app = UIApplication.sharedApplication;
    NSMutableArray *roots = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (scene.activationState == UISceneActivationStateUnattached) continue;
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) if (w.rootViewController) [roots addObject:w.rootViewController];
        }
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        for (UIWindow *w in app.windows) if (w.rootViewController) [roots addObject:w.rootViewController];
#pragma clang diagnostic pop
    }
    NSMutableArray *stack = [NSMutableArray arrayWithArray:roots];
    NSHashTable *seen = [NSHashTable weakObjectsHashTable];
    while (stack.count) {
        UIViewController *vc = stack.lastObject;
        [stack removeLastObject];
        if (!vc || [seen containsObject:vc]) continue;
        [seen addObject:vc];
        if ([vc isKindOfClass:cls]) return vc;
        if (vc.presentedViewController) [stack addObject:vc.presentedViewController];
        if (vc.navigationController && vc.navigationController != vc) [stack addObject:vc.navigationController];
        for (UIViewController *child in vc.childViewControllers) [stack addObject:child];
    }
    return nil;
}

#pragma mark - Helper controllers

@interface WCZZCommonRoomsViewController : UITableViewController
@property(nonatomic, strong) NSArray *groups;
@property(nonatomic, strong) NSMutableSet *selected;
@end

@interface WCZZGroupHelperViewController : UITableViewController
@property(nonatomic, strong) UIViewController *mainController;
@property(nonatomic, strong) NSArray *sessions;
@end

static id WCZZSessionCellDataForUsername(NSString *username) {
    if (!username.length) return nil;
    id main = WCZZFindMainController();
    id logic = WCZZValue(main, @"m_mainFrameLogicController");
    SEL sel = NSSelectorFromString(@"getCellDataByUsrName:");
    if (logic && [logic respondsToSelector:sel]) {
        @try { return ((id (*)(id, SEL, id))objc_msgSend)(logic, sel, username); } @catch (__unused NSException *e) {}
    }
    return nil;
}

static NSTimeInterval WCZZSessionLastMessageTime(id session) {
    id value = WCZZValue(session, @"m_uLastMsgTime");
    if ([value isKindOfClass:[NSNumber class]]) return [value doubleValue];
    if ([value isKindOfClass:[NSDate class]]) return [(NSDate *)value timeIntervalSince1970];

    value = WCZZValue(session, @"m_nsLastMsgTime");
    if ([value isKindOfClass:[NSNumber class]]) return [value doubleValue];
    if ([value isKindOfClass:[NSDate class]]) return [(NSDate *)value timeIntervalSince1970];

    id contact = WCZZContact(session);
    NSArray *keys = @[@"m_uLastMsgTime", @"m_nsLastMsgTime", @"m_lastMsgTime", @"m_nsLastMessageTime"];
    for (NSString *key in keys) {
        value = WCZZValue(contact, key);
        if ([value isKindOfClass:[NSNumber class]]) return [value doubleValue];
        if ([value isKindOfClass:[NSDate class]]) return [(NSDate *)value timeIntervalSince1970];
    }
    return 0.0;
}

static NSTimeInterval WCZZLastHelperPushTime = 0.0;
static BOOL WCZZHelperPushInProgress = NO;
static void WCZZPushGroupHelper(UIViewController *base) {
    if (!base) base = WCZZFindMainController();
    UINavigationController *nav = base.navigationController;
    if (!nav && [base isKindOfClass:[UINavigationController class]]) nav = (UINavigationController *)base;
    if (!nav) {
        WCZZLog(@"helper push: navigation controller missing");
        return;
    }
    UIViewController *top = nav.topViewController;
    if ([top isKindOfClass:objc_getClass("WCZZGroupHelperViewController")]) return;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (WCZZHelperPushInProgress || (now - WCZZLastHelperPushTime) < 0.60) return;
    WCZZHelperPushInProgress = YES;
    WCZZLastHelperPushTime = now;
    WCZZGroupHelperViewController *vc = [WCZZGroupHelperViewController new];
    vc.mainController = base ?: WCZZFindMainController();
    [nav pushViewController:vc animated:YES];
    WCZZLog(@"helper pushed");
    dispatch_async(dispatch_get_main_queue(), ^{ WCZZHelperPushInProgress = NO; });
}

@implementation WCZZGroupHelperViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"群消息";
    self.tableView.tableFooterView = [UIView new];
    self.tableView.separatorInset = UIEdgeInsetsMake(0, 78, 0, 0);
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"更多" style:UIBarButtonItemStylePlain target:self action:@selector(wczzMore)];
}
- (void)wczzReloadSessions {
    NSMutableArray *groups = [NSMutableArray array];
    for (id s in WCZZSessionList()) if (WCZZShouldFold(s)) [groups addObject:s];
    if (groups.count) WCZZLog(@"helper time check first=%.0f", WCZZSessionLastMessageTime(groups[0]));

    // Sort newest message first.  Use the original array position as the
    // secondary key so equal timestamps keep their original relative order.
    NSMutableArray *indexedGroups = [NSMutableArray arrayWithCapacity:groups.count];
    [groups enumerateObjectsUsingBlock:^(id session, NSUInteger idx, BOOL *stop) {
        [indexedGroups addObject:@{
            @"session": session,
            @"index": @(idx)
        }];
        (void)stop;
    }];
    [indexedGroups sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSTimeInterval ta = WCZZSessionLastMessageTime(a[@"session"]);
        NSTimeInterval tb = WCZZSessionLastMessageTime(b[@"session"]);
        if (ta > tb) return NSOrderedAscending;
        if (ta < tb) return NSOrderedDescending;
        NSUInteger ia = [a[@"index"] unsignedIntegerValue];
        NSUInteger ib = [b[@"index"] unsignedIntegerValue];
        if (ia < ib) return NSOrderedAscending;
        if (ia > ib) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    NSMutableArray *sortedGroups = [NSMutableArray arrayWithCapacity:indexedGroups.count];
    for (NSDictionary *entry in indexedGroups) {
        id session = entry[@"session"];
        if (session) [sortedGroups addObject:session];
    }
    self.sessions = sortedGroups;
    [self.tableView reloadData];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self wczzReloadSessions];
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section { return section == 0 ? (NSInteger)self.sessions.count : 0; }
- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip { return 64.0; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *reuse = @"wczz.native.session";
    if (ip.row >= (NSInteger)self.sessions.count) return [UITableViewCell new];
    id session = self.sessions[(NSUInteger)ip.row];
    NSString *u = WCZZUsername(session);

    Class cellClass = objc_getClass("MMBaseSessionTableViewCell");
    Class lpClass = objc_getClass("SessionCellLayoutParam");
    if (cellClass && lpClass) {
        SEL defaultLP = NSSelectorFromString(@"defaultSessionCellLayoutParam");
        id lp = [lpClass respondsToSelector:defaultLP] ? ((id (*)(id, SEL))objc_msgSend)(lpClass, defaultLP) : nil;
        id cell = nil;
        SEL initSel = NSSelectorFromString(@"initWithLayoutParam:reuseIdentifier:");
        if (lp && [cellClass instancesRespondToSelector:initSel]) {
            cell = ((id (*)(id, SEL, id, id))objc_msgSend)([cellClass alloc], initSel, lp, reuse);
        }
        id data = WCZZSessionCellDataForUsername(u);
        SEL updateSel = NSSelectorFromString(@"updateWithSessionCellData:");
        if (cell && data && [cell respondsToSelector:updateSel]) {
            @try { ((void (*)(id, SEL, id))objc_msgSend)(cell, updateSel, data); } @catch (__unused NSException *e) {}
            return cell;
        }
    }

    UITableViewCell *fallback = [tv dequeueReusableCellWithIdentifier:@"wczz.fallback"];
    if (!fallback) fallback = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"wczz.fallback"];
    fallback.textLabel.text = WCZZDisplayName(WCZZContact(session));
    unsigned int unread = [WCZZValue(session, @"m_uUnReadCount") unsignedIntValue];
    fallback.detailTextLabel.text = unread ? [NSString stringWithFormat:@"[%u条]", unread] : @"";
    return fallback;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.row >= (NSInteger)self.sessions.count) return;
    id session = self.sessions[(NSUInteger)ip.row];
    UIViewController *main = self.mainController;
    SEL open = NSSelectorFromString(@"onLogicOpenSession:");
    if (main && [main respondsToSelector:open]) {
        @try { ((void (*)(id, SEL, id))objc_msgSend)(main, open, session); } @catch (__unused NSException *e) {}
    }
}
- (void)wczzMore {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:nil message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:@"一键已读" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *x) {
        for (id s in self.sessions) WCZZMarkRead(WCZZUsername(s));
        [self wczzReloadSessions];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"管理常用群" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *x) {
        [self.navigationController pushViewController:[WCZZCommonRoomsViewController new] animated:YES];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
@end

@implementation WCZZCommonRoomsViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"常用群";
    self.tableView.tableFooterView = [UIView new];
    self.selected = [NSMutableSet setWithArray:WCZZCommonRooms()];
    NSMutableArray *groups = [NSMutableArray array];
    for (id s in WCZZSessionList()) if (WCZZIsGroupUsername(WCZZUsername(s))) [groups addObject:s];
    self.groups = groups;
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section { return section == 0 ? (NSInteger)self.groups.count : 0; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"wczz.common"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"wczz.common"];
    if (ip.row < (NSInteger)self.groups.count) {
        id s = self.groups[(NSUInteger)ip.row];
        NSString *u = WCZZUsername(s);
        cell.textLabel.text = WCZZDisplayName(WCZZContact(s));
        cell.accessoryType = [self.selected containsObject:u] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    }
    return cell;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.row >= (NSInteger)self.groups.count) return;
    NSString *u = WCZZUsername(self.groups[(NSUInteger)ip.row]);
    if (!WCZZIsGroupUsername(u)) return;
    if ([self.selected containsObject:u]) [self.selected removeObject:u]; else [self.selected addObject:u];
    WCZZSetCommonRooms(self.selected.allObjects);
    // The main-list mapping is cached by MainFrameLogicController.  Invalidate it
    // before reloading so a newly selected common group immediately returns to the
    // normal WeChat session list (and vice versa).
    WCZZInvalidateMainLogicCache();
    [tv reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *main = WCZZFindMainController();
        id table = WCZZValue(main, @"m_tableView");
        if ([table respondsToSelector:@selector(reloadData)]) [(UITableView *)table reloadData];
    });
}
@end

#pragma mark - Settings

@interface WCZZDebugLogViewController : UITableViewController @end
@implementation WCZZDebugLogViewController
- (void)viewDidLoad { [super viewDidLoad]; self.title = @"调试日志"; self.tableView.tableFooterView = [UIView new];
    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithTitle:@"清空" style:UIBarButtonItemStylePlain target:self action:@selector(wczzClear)],
        [[UIBarButtonItem alloc] initWithTitle:@"复制" style:UIBarButtonItemStylePlain target:self action:@selector(wczzCopy)]
    ];
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self.tableView reloadData]; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section { return (NSInteger)WCZZDebugLogs().count; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"wczz.log"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"wczz.log"];
    NSArray *logs = WCZZDebugLogs();
    c.textLabel.numberOfLines = 0;
    c.textLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    c.textLabel.text = ip.row < (NSInteger)logs.count ? logs[(NSUInteger)ip.row] : @"";
    return c;
}
- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip { return UITableViewAutomaticDimension; }
- (void)wczzClear { WCZZClearDebugLogs(); [self.tableView reloadData]; }
- (void)wczzCopy { [UIPasteboard generalPasteboard].string = [WCZZDebugLogs() componentsJoinedByString:@"\n"]; }
@end

@interface WCZZGroupSettingsViewController : UITableViewController @end
static const void *WCZZGroupSwitchUsernameKey = &WCZZGroupSwitchUsernameKey;
@implementation WCZZGroupSettingsViewController
- (instancetype)init { return [super initWithStyle:UITableViewStyleGrouped]; }
- (void)viewDidLoad { [super viewDidLoad]; self.title = @"群助手"; self.tableView.tableFooterView = [UIView new]; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 3; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 2;
    if (section == 1) return 2;
    NSInteger n = 0; for (id s in WCZZSessionList()) if (WCZZIsGroupUsername(WCZZUsername(s))) n++;
    return MIN(20, n);
}
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section { return section == 2 ? @"只有 @chatroom 群聊会被归纳。常用群会始终保留在主列表。" : nil; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"wczz.gs"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"wczz.gs"];
    c.accessoryView = nil; c.accessoryType = UITableViewCellAccessoryNone; c.detailTextLabel.text = nil;
    if (ip.section == 0) {
        c.textLabel.text = ip.row == 0 ? @"开启群助手" : @"群助手置顶";
        UISwitch *sw = [UISwitch new]; sw.tag = 500 + ip.row; sw.on = ip.row == 0 ? WCZZBool(WCZZGroupEnabledKey, YES) : WCZZBool(WCZZGroupTopKey, YES);
        [sw addTarget:self action:@selector(wczzSwitch:) forControlEvents:UIControlEventValueChanged]; c.accessoryView = sw;
    } else if (ip.section == 1) {
        if (ip.row == 0) { c.textLabel.text = @"群助手头像"; c.detailTextLabel.text = [[NSUserDefaults standardUserDefaults] objectForKey:WCZZGroupAvatarKey] ?: @"默认头像"; c.accessoryType = UITableViewCellAccessoryDisclosureIndicator; }
        else { c.textLabel.text = @"常用群列表"; c.detailTextLabel.text = [NSString stringWithFormat:@"已选 %lu 个群", (unsigned long)WCZZCommonRooms().count]; c.accessoryType = UITableViewCellAccessoryDisclosureIndicator; }
    } else {
        NSMutableArray *all = [NSMutableArray array]; for (id s in WCZZSessionList()) if (WCZZIsGroupUsername(WCZZUsername(s))) [all addObject:s];
        if (ip.row < (NSInteger)MIN(20, all.count)) {
            id s = all[(NSUInteger)ip.row]; NSString *u = WCZZUsername(s); c.textLabel.text = WCZZDisplayName(WCZZContact(s));
            UISwitch *sw = [UISwitch new];
            sw.tag = 1000 + ip.row;
            sw.on = !WCZZIsCommonRoom(u);
            objc_setAssociatedObject(sw, WCZZGroupSwitchUsernameKey, u, OBJC_ASSOCIATION_COPY_NONATOMIC);
            [sw addTarget:self action:@selector(wczzItem:) forControlEvents:UIControlEventValueChanged];
            c.accessoryView = sw;
        }
    }
    return c;
}
- (void)wczzSwitch:(UISwitch *)sw { if (sw.tag == 500) WCZZSetBool(WCZZGroupEnabledKey, sw.on); else WCZZSetBool(WCZZGroupTopKey, sw.on); WCZZInvalidateMainLogicCache(); dispatch_async(dispatch_get_main_queue(), ^{ id main = WCZZFindMainController(); id table = WCZZValue(main, @"m_tableView"); if ([table respondsToSelector:@selector(reloadData)]) [(UITableView *)table reloadData]; }); }
- (void)wczzItem:(UISwitch *)sw {
    NSString *u = objc_getAssociatedObject(sw, WCZZGroupSwitchUsernameKey);
    if (![u isKindOfClass:[NSString class]] || !WCZZIsGroupUsername(u)) return;
    NSMutableArray *rooms = [WCZZCommonRooms() mutableCopy];
    if (sw.on) [rooms removeObject:u]; else if (![rooms containsObject:u]) [rooms addObject:u];
    WCZZSetCommonRooms(rooms);
    [self.tableView reloadData]; WCZZInvalidateMainLogicCache(); dispatch_async(dispatch_get_main_queue(), ^{ id main = WCZZFindMainController(); id table = WCZZValue(main, @"m_tableView"); if ([table respondsToSelector:@selector(reloadData)]) [(UITableView *)table reloadData]; });
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip { [tv deselectRowAtIndexPath:ip animated:YES]; if (ip.section != 1) return; if (ip.row == 0) { UIAlertController *a = [UIAlertController alertControllerWithTitle:@"群助手头像" message:nil preferredStyle:UIAlertControllerStyleActionSheet]; for (NSString *n in @[@"默认头像", @"微信头像", @"QQ邮箱头像"]) [a addAction:[UIAlertAction actionWithTitle:n style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *x){ [[NSUserDefaults standardUserDefaults] setObject:n forKey:WCZZGroupAvatarKey]; [self.tableView reloadData]; }]]; [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]]; [self presentViewController:a animated:YES completion:nil]; } else [self.navigationController pushViewController:[WCZZCommonRoomsViewController new] animated:YES]; }
@end

@interface WCZZSettingsViewController : UITableViewController @end
@implementation WCZZSettingsViewController
- (instancetype)init { return [super initWithStyle:UITableViewStyleGrouped]; }
- (void)viewDidLoad { [super viewDidLoad]; self.title = @"wczz"; self.tableView.tableFooterView = [UIView new]; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section { return section == 0 ? 5 : 0; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"wczz.setting"]; if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"wczz.setting"];
    c.accessoryView = nil; c.accessoryType = UITableViewCellAccessoryNone; c.detailTextLabel.text = nil;
    if (ip.row == 0) { c.textLabel.text = @"启用 wczz"; UISwitch *sw=[UISwitch new]; sw.tag=99; sw.on=WCZZEnabled(); [sw addTarget:self action:@selector(wczzMain:) forControlEvents:UIControlEventValueChanged]; c.accessoryView=sw; }
    else if (ip.row == 1) { c.textLabel.text=@"群助手"; c.accessoryType=UITableViewCellAccessoryDisclosureIndicator; }
    else if (ip.row == 2) { c.textLabel.text=@"红包详情"; UISwitch *sw=[UISwitch new]; sw.tag=100; sw.on=WCZZBool(WCZZRedDetailKey,YES); [sw addTarget:self action:@selector(wczzMain:) forControlEvents:UIControlEventValueChanged]; c.accessoryView=sw; }
    else if (ip.row == 3) { c.textLabel.text=@"启用调试日志"; UISwitch *sw=[UISwitch new]; sw.tag=101; sw.on=WCZZDebugEnabled(); [sw addTarget:self action:@selector(wczzMain:) forControlEvents:UIControlEventValueChanged]; c.accessoryView=sw; }
    else { c.textLabel.text=@"查看调试日志"; c.detailTextLabel.text=[NSString stringWithFormat:@"%lu 条",(unsigned long)WCZZDebugLogs().count]; c.accessoryType=UITableViewCellAccessoryDisclosureIndicator; }
    return c;
}
- (void)wczzMain:(UISwitch *)sw { if(sw.tag==99) WCZZSetBool(WCZZPluginEnabledKey,sw.on); else if(sw.tag==100) WCZZSetBool(WCZZRedDetailKey,sw.on); else { WCZZSetBool(WCZZDebugEnabledKey,sw.on); WCZZLog(@"debug logging %@",sw.on?@"enabled":@"disabled"); [self.tableView reloadData]; return; } dispatch_async(dispatch_get_main_queue(), ^{ id main=WCZZFindMainController(); id table=WCZZValue(main,@"m_tableView"); if([table respondsToSelector:@selector(reloadData)]) [(UITableView *)table reloadData]; }); }
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip { [tv deselectRowAtIndexPath:ip animated:YES]; if(ip.row==1) [self.navigationController pushViewController:[WCZZGroupSettingsViewController new] animated:YES]; else if(ip.row==4) [self.navigationController pushViewController:[WCZZDebugLogViewController new] animated:YES]; }
@end

#pragma mark - Main list logical filtering

// WeChat 8.0.75 actually obtains session rows through MainFrameLogicController.
// Filter only @chatroom sessions here.  We do not call WeChat's native fold APIs.
static const void *WCZZLogicRowsKey = &WCZZLogicRowsKey;
static const void *WCZZLogicFoldedKey = &WCZZLogicFoldedKey;
static const void *WCZZLogicOriginalCountKey = &WCZZLogicOriginalCountKey;
static const void *WCZZLogicReentryKey = &WCZZLogicReentryKey;

static NSArray *WCZZLogicRows(id obj) {
    return objc_getAssociatedObject(obj, WCZZLogicRowsKey);
}
static NSArray *WCZZLogicFolded(id obj) {
    return objc_getAssociatedObject(obj, WCZZLogicFoldedKey);
}
static long long WCZZLogicOriginalCount(id obj) {
    id v = objc_getAssociatedObject(obj, WCZZLogicOriginalCountKey);
    return [v isKindOfClass:[NSNumber class]] ? [v longLongValue] : -1;
}
static BOOL WCZZLogicReentry(id obj) {
    return [objc_getAssociatedObject(obj, WCZZLogicReentryKey) boolValue];
}
static void WCZZSetLogicReentry(id obj, BOOL on) {
    objc_setAssociatedObject(obj, WCZZLogicReentryKey, @(on), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static void WCZZClearLogicRows(id obj) {
    objc_setAssociatedObject(obj, WCZZLogicRowsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(obj, WCZZLogicFoldedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(obj, WCZZLogicOriginalCountKey, @(-1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static NSArray *WCZZBuildLogicRows(id obj, long long originalCount, NSMutableArray **foldedOut);

static NSArray *WCZZEnsureLogicRows(id obj, long long originalCount, NSMutableArray **foldedOut) {
    NSArray *cached = WCZZLogicRows(obj);
    NSArray *cachedFolded = WCZZLogicFolded(obj);
    long long cachedOriginal = WCZZLogicOriginalCount(obj);
    if ([cached isKindOfClass:[NSArray class]] &&
        [cachedFolded isKindOfClass:[NSArray class]] &&
        cachedOriginal == originalCount) {
        if (foldedOut) *foldedOut = [cachedFolded mutableCopy];
        return cached;
    }
    return WCZZBuildLogicRows(obj, originalCount, foldedOut);
}

static NSArray *WCZZBuildLogicRows(id obj, long long originalCount, NSMutableArray **foldedOut) {
    if (originalCount <= 0) {
        if (foldedOut) *foldedOut = [NSMutableArray array];
        return @[];
    }

    NSMutableArray *visible = [NSMutableArray arrayWithCapacity:(NSUInteger)originalCount];
    NSMutableArray *folded = [NSMutableArray array];
    NSMutableDictionary *sessionByRow = [NSMutableDictionary dictionaryWithCapacity:(NSUInteger)originalCount];
    NSArray *serviceSessions = WCZZSessionList();
    WCZZSetLogicReentry(obj, YES);

    for (NSInteger i = 0; i < originalCount; i++) {
        NSIndexPath *ip = [NSIndexPath indexPathForRow:i inSection:0];
        id session = nil;
        id cellData = nil;
        NSString *username = nil;

        // On this 8.0.75 build getSessionInfoAtIndexPath: can return nil even
        // though the row is real.  Prefer the session object, then fall back to
        // the row's cell-data username, and finally to MMNewSessionMgr's
        // GetSessionInfoList.  The previous implementation treated nil as a
        // non-group row, which is why the group assistant never folded anything.
        @try {
            session = [(MainFrameLogicController *)obj getSessionInfoAtIndexPath:ip];
        } @catch (__unused NSException *e) {}

        if (session) {
            username = WCZZUsername(session);
        }

        if (!username.length) {
            @try {
                cellData = [(MainFrameLogicController *)obj getCellDataAtIndexPath:ip];
            } @catch (__unused NSException *e) {}
            id cellUsername = WCZZValue(cellData, @"userName");
            if ([cellUsername isKindOfClass:[NSString class]]) username = cellUsername;
        }

        if (!username.length && i < (NSInteger)serviceSessions.count) {
            id fallback = serviceSessions[(NSUInteger)i];
            NSString *fallbackUsername = WCZZUsername(fallback);
            if (fallbackUsername.length) {
                session = fallback;
                username = fallbackUsername;
            }
        }

        if (!session && username.length) {
            for (id candidate in serviceSessions) {
                if ([WCZZUsername(candidate) isEqualToString:username]) {
                    session = candidate;
                    break;
                }
            }
        }

        if (session) sessionByRow[@(i)] = session;

        BOOL fold = WCZZIsGroupUsername(username) && !WCZZIsCommonRoom(username) &&
                    WCZZEnabled() && WCZZBool(WCZZGroupEnabledKey, YES);
        if (fold) {
            [folded addObject:@(i)];
        } else {
            [visible addObject:@(i)];
        }

    }

    WCZZSetLogicReentry(obj, NO);

    // Keep folded rows untouched. Reorder only visible rows by unread count
    // descending. The original row number is the secondary key, preserving
    // the original order for equal unread counts.
    NSArray *sortedVisible = [visible sortedArrayUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        id sa = sessionByRow[a];
        id sb = sessionByRow[b];
        unsigned long long ua = (unsigned long long)[WCZZValue(sa, @"m_uUnReadCount") unsignedIntValue];
        unsigned long long ub = (unsigned long long)[WCZZValue(sb, @"m_uUnReadCount") unsignedIntValue];
        if (ua > ub) return NSOrderedAscending;
        if (ua < ub) return NSOrderedDescending;
        NSInteger ia = [a integerValue];
        NSInteger ib = [b integerValue];
        if (ia < ib) return NSOrderedAscending;
        if (ia > ib) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    visible = [sortedVisible mutableCopy];

    objc_setAssociatedObject(obj, WCZZLogicRowsKey, visible, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(obj, WCZZLogicFoldedKey, folded, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(obj, WCZZLogicOriginalCountKey, @(originalCount), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    WCZZLog(@"logic rows rebuilt original=%lld visible=%lu folded=%lu",
            originalCount,
            (unsigned long)visible.count,
            (unsigned long)folded.count);

    if (foldedOut) *foldedOut = folded;
    return visible;
}

static NSIndexPath *WCZZOriginalIPForLogicRow(id obj, NSIndexPath *visibleIP) {
    NSArray *rows = WCZZLogicRows(obj);
    if (![rows isKindOfClass:[NSArray class]] || !visibleIP || visibleIP.section != 0) return nil;

    BOOL top = WCZZBool(WCZZGroupTopKey, YES);
    NSInteger helperRow = top ? 0 : (NSInteger)rows.count;
    if (visibleIP.row == helperRow) return nil;

    NSInteger visibleIndex = top ? visibleIP.row - 1 : visibleIP.row;
    if (visibleIndex < 0 || visibleIndex >= (NSInteger)rows.count) return nil;

    NSInteger originalRow = [rows[(NSUInteger)visibleIndex] integerValue];
    return [NSIndexPath indexPathForRow:originalRow inSection:0];
}

static id WCZZBuildHelperCellData(id obj) {
    Class c = objc_getClass("FakeMainFrameCellData");
    if (!c) {
        WCZZLog(@"helper cell data failed: FakeMainFrameCellData missing");
        return nil;
    }

    NSArray *foldedRows = WCZZLogicFolded(obj);
    unsigned long long unreadTotal = 0;
    NSString *latestMessage = nil;
    NSString *latestTime = nil;
    double latestWidth = 0.0;

    if ([foldedRows isKindOfClass:[NSArray class]]) {
        for (NSNumber *n in foldedRows) {
            NSIndexPath *ip = [NSIndexPath indexPathForRow:n.integerValue inSection:0];
            id session = nil;
            id data = nil;

            WCZZSetLogicReentry(obj, YES);
            @try {
                session = [(MainFrameLogicController *)obj getSessionInfoAtIndexPath:ip];
            } @catch (__unused NSException *e) {}
            @try {
                data = [(MainFrameLogicController *)obj getCellDataAtIndexPath:ip];
            } @catch (__unused NSException *e) {}
            WCZZSetLogicReentry(obj, NO);

            unreadTotal += (unsigned long long)[WCZZValue(session, @"m_uUnReadCount") unsignedIntValue];
            if (data) {
                id msg = WCZZValue(data, @"textForMessageLabel");
                id time = WCZZValue(data, @"textForTimeLabel");
                if (!latestMessage.length && [msg isKindOfClass:[NSString class]] && [(NSString *)msg length]) {
                    latestMessage = msg;
                    latestWidth = [WCZZValue(data, @"widthForNameLabel") doubleValue];
                }
                if (!latestTime.length && [time isKindOfClass:[NSString class]] && [(NSString *)time length]) latestTime = time;
            }
        }
    }

    NSString *message = latestMessage.length
        ? [NSString stringWithFormat:@"[%llu条] %@", unreadTotal, latestMessage]
        : [NSString stringWithFormat:@"[%llu条]", unreadTotal];

    id data = [[c alloc] init];
    @try {
        [data setValue:WCZZGroupUserName forKey:@"userName"];
        [data setValue:@"群助手" forKey:@"textForNameLabel"];
        [data setValue:message forKey:@"textForMessageLabel"];
        [data setValue:(latestTime ?: @"") forKey:@"textForTimeLabel"];
        [data setValue:@YES forKey:@"bNormalCell"];
        [data setValue:@(WCZZBool(WCZZGroupTopKey, YES)) forKey:@"bTopCell"];
        [data setValue:@(latestWidth) forKey:@"widthForNameLabel"];
    } @catch (__unused NSException *e) {}
    return data;
}

static void WCZZReloadMainList(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *main = WCZZFindMainController();
        if (!main) return;

        id logic = WCZZValue(main, @"m_mainFrameLogicController");
        if (logic) WCZZClearLogicRows(logic);

        id table = WCZZValue(main, @"m_tableView");
        if ([table respondsToSelector:@selector(reloadData)]) {
            [(UITableView *)table reloadData];
        }
        WCZZLog(@"main list reload requested");
    });
}

%group WCZZMainLogicHooks
%hook MainFrameLogicController

- (long long)getSessionCountForSection:(long long)section {
    if (WCZZLogicReentry(self)) return %orig(section);

    long long original = %orig(section);
    if (section != 0 || !WCZZEnabled() || !WCZZBool(WCZZGroupEnabledKey, YES) || original <= 0) {
        if (section == 0) {
            WCZZClearLogicRows(self);
            objc_setAssociatedObject(self, WCZZLogicOriginalCountKey, @(original), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return original;
    }

    NSMutableArray *folded = nil;
    NSArray *visible = WCZZEnsureLogicRows(self, original, &folded);
    if (![visible isKindOfClass:[NSArray class]]) return original;
    if (folded.count == 0) return original;


    long long result = (long long)visible.count + 1;
    return result;
}

- (unsigned long long)getFilteredSessionCount {
    if (WCZZLogicReentry(self)) return %orig;
    unsigned long long original = %orig;
    if (!WCZZEnabled() || !WCZZBool(WCZZGroupEnabledKey, YES) || original == 0) return original;
    NSMutableArray *folded = nil;
    NSArray *rows = WCZZEnsureLogicRows(self, (long long)original, &folded);
    if (![rows isKindOfClass:[NSArray class]] || folded.count == 0) return original;
    return (unsigned long long)rows.count + 1ULL;
}

- (id)getSessionBaseInfoAtIndexPath:(id)indexPath {
    if (WCZZLogicReentry(self)) return %orig(indexPath);

    NSIndexPath *ip = [indexPath isKindOfClass:[NSIndexPath class]] ? (NSIndexPath *)indexPath : nil;
    if (!ip || ip.section != 0 || !WCZZEnabled() || !WCZZBool(WCZZGroupEnabledKey, YES)) {
        return %orig(indexPath);
    }

    NSArray *rows = WCZZLogicRows(self);
    long long original = WCZZLogicOriginalCount(self);
    if (![rows isKindOfClass:[NSArray class]] || original < 0) {
        WCZZSetLogicReentry(self, YES);
        @try { original = [self getSessionCountForSection:0]; } @catch (__unused NSException *e) { original = -1; }
        WCZZSetLogicReentry(self, NO);
        if (original > 0) {
            NSMutableArray *folded = nil;
            rows = WCZZEnsureLogicRows(self, original, &folded);
        }
    }

    if (![rows isKindOfClass:[NSArray class]] || original <= 0 || rows.count >= (NSUInteger)original) {
        return %orig(indexPath);
    }

    BOOL top = WCZZBool(WCZZGroupTopKey, YES);
    NSInteger helperRow = top ? 0 : (NSInteger)rows.count;
    if (ip.row == helperRow) return nil;

    NSIndexPath *origIP = WCZZOriginalIPForLogicRow(self, ip);
    if (!origIP) return nil;
    return %orig(origIP);
}

- (unsigned int)getVisibleSessionCount {
    if (WCZZLogicReentry(self)) return %orig;

    unsigned int original = %orig;
    if (!WCZZEnabled() || !WCZZBool(WCZZGroupEnabledKey, YES) || original == 0) return original;

    NSMutableArray *folded = nil;
    NSArray *rows = WCZZEnsureLogicRows(self, (long long)original, &folded);
    if (![rows isKindOfClass:[NSArray class]] || folded.count == 0) return original;

    unsigned int result = (unsigned int)rows.count + 1U;
    return result;
}

- (id)getSessionInfoAtIndexPath:(id)indexPath {
    if (WCZZLogicReentry(self)) return %orig(indexPath);

    NSIndexPath *ip = [indexPath isKindOfClass:[NSIndexPath class]] ? (NSIndexPath *)indexPath : nil;
    if (!ip || ip.section != 0 || !WCZZEnabled() || !WCZZBool(WCZZGroupEnabledKey, YES)) return %orig(indexPath);

    NSArray *rows = WCZZLogicRows(self);
    long long original = WCZZLogicOriginalCount(self);
    if (![rows isKindOfClass:[NSArray class]] || original < 0) {
        WCZZSetLogicReentry(self, YES);
        @try {
            original = [self getSessionCountForSection:0];
        } @catch (__unused NSException *e) {
            original = -1;
        }
        WCZZSetLogicReentry(self, NO);
        if (original > 0) {
            NSMutableArray *folded = nil;
            rows = WCZZEnsureLogicRows(self, original, &folded);
        }
    }

    if (![rows isKindOfClass:[NSArray class]] || original <= 0 || rows.count >= (NSUInteger)original) return %orig(indexPath);

    BOOL top = WCZZBool(WCZZGroupTopKey, YES);
    NSInteger helperRow = top ? 0 : (NSInteger)rows.count;
    if (ip.row == helperRow) return nil;

    NSIndexPath *origIP = WCZZOriginalIPForLogicRow(self, ip);
    if (!origIP) return nil;
    return %orig(origIP);
}

- (id)getCellDataAtIndexPath:(id)indexPath {
    if (WCZZLogicReentry(self)) return %orig(indexPath);

    NSIndexPath *ip = [indexPath isKindOfClass:[NSIndexPath class]] ? (NSIndexPath *)indexPath : nil;
    if (!ip || ip.section != 0 || !WCZZEnabled() || !WCZZBool(WCZZGroupEnabledKey, YES)) return %orig(indexPath);

    NSArray *rows = WCZZLogicRows(self);
    long long original = WCZZLogicOriginalCount(self);
    if (![rows isKindOfClass:[NSArray class]] || original < 0) {
        // Obtain the original count without re-entering our count hook.
        WCZZSetLogicReentry(self, YES);
        @try {
            original = [self getSessionCountForSection:0];
        } @catch (__unused NSException *e) {
            original = -1;
        }
        WCZZSetLogicReentry(self, NO);
        if (original > 0) {
            NSMutableArray *folded = nil;
            rows = WCZZEnsureLogicRows(self, original, &folded);
        }
    }

    if (![rows isKindOfClass:[NSArray class]] || original <= 0 || rows.count >= (NSUInteger)original) return %orig(indexPath);

    BOOL top = WCZZBool(WCZZGroupTopKey, YES);
    NSInteger helperRow = top ? 0 : (NSInteger)rows.count;
    if (ip.row == helperRow) return WCZZBuildHelperCellData(self);

    NSIndexPath *origIP = WCZZOriginalIPForLogicRow(self, ip);
    if (origIP) return %orig(origIP);
    return %orig(indexPath);
}

- (void)onDidSelectCellAt:(id)indexPath {
    if (WCZZLogicReentry(self)) {
        %orig(indexPath);
        return;
    }

    NSIndexPath *ip = [indexPath isKindOfClass:[NSIndexPath class]] ? (NSIndexPath *)indexPath : nil;
    NSArray *rows = WCZZLogicRows(self);
    NSArray *folded = WCZZLogicFolded(self);
    long long original = WCZZLogicOriginalCount(self);

    if (ip && ip.section == 0 && WCZZEnabled() && WCZZBool(WCZZGroupEnabledKey, YES) &&
        [rows isKindOfClass:[NSArray class]] && [folded isKindOfClass:[NSArray class]] &&
        original > 0 && folded.count > 0) {

        BOOL top = WCZZBool(WCZZGroupTopKey, YES);
        NSInteger helperRow = top ? 0 : (NSInteger)rows.count;
        if (ip.row == helperRow) {
            id delegate = WCZZValue(self, @"m_delegate");
            UIViewController *base = [delegate isKindOfClass:[UIViewController class]] ? (UIViewController *)delegate : WCZZFindMainController();
            WCZZPushGroupHelper(base);
            WCZZLog(@"helper selected folded=%lu", (unsigned long)folded.count);
            return;
        }

        NSIndexPath *origIP = WCZZOriginalIPForLogicRow(self, ip);
        if (origIP) {
            %orig(origIP);
            return;
        }
    }

    %orig(indexPath);
}

- (void)onSessionRebuildEnd {
    WCZZClearLogicRows(self);
    %orig;
}

%end
%end

#pragma mark - Main VC navigation
%group WCZZMainOpenSessionHook
%hook NewMainFrameViewController

- (long long)logicGetCountForSection:(long long)section {
    long long original = %orig(section);
    if (section != 0 || !WCZZEnabled() || !WCZZBool(WCZZGroupEnabledKey, YES)) return original;
    id logic = WCZZValue(self, @"m_mainFrameLogicController");
    if (!logic) return original;
    long long filtered = original;
    @try { filtered = [(MainFrameLogicController *)logic getSessionCountForSection:0]; } @catch (__unused NSException *e) {}
    if (filtered != original) WCZZLog(@"main VC logicGetCount original=%lld filtered=%lld", original, filtered);
    return filtered;
}

- (id)visibleIndexPaths {
    NSArray *origPaths = %orig;
    if (!WCZZEnabled() || !WCZZBool(WCZZGroupEnabledKey, YES)) return origPaths;

    id logic = WCZZValue(self, @"m_mainFrameLogicController");
    if (!logic) return origPaths;
    NSArray *rows = WCZZLogicRows(logic);
    NSArray *folded = WCZZLogicFolded(logic);
    if (![rows isKindOfClass:[NSArray class]] || ![folded isKindOfClass:[NSArray class]] || folded.count == 0) {
        @try { (void)[(MainFrameLogicController *)logic getSessionCountForSection:0]; } @catch (__unused NSException *e) {}
        rows = WCZZLogicRows(logic);
        folded = WCZZLogicFolded(logic);
    }
    if (![rows isKindOfClass:[NSArray class]] || folded.count == 0) return origPaths;

    BOOL top = WCZZBool(WCZZGroupTopKey, YES);
    NSMutableArray *paths = [NSMutableArray arrayWithCapacity:rows.count + 1];
    if (top) [paths addObject:[NSIndexPath indexPathForRow:0 inSection:0]];
    for (NSUInteger i = 0; i < rows.count; i++) {
        NSInteger visibleRow = top ? (NSInteger)i + 1 : (NSInteger)i;
        [paths addObject:[NSIndexPath indexPathForRow:visibleRow inSection:0]];
    }
    if (!top) [paths addObject:[NSIndexPath indexPathForRow:rows.count inSection:0]];
    return paths;
}

- (id)indexPathOfSessionUserName:(id)username {
    id origResult = %orig(username);
    if (!WCZZEnabled() || !WCZZBool(WCZZGroupEnabledKey, YES)) return origResult;
    id logic = WCZZValue(self, @"m_mainFrameLogicController");
    NSArray *rows = logic ? WCZZLogicRows(logic) : nil;
    NSArray *folded = logic ? WCZZLogicFolded(logic) : nil;
    if (![rows isKindOfClass:[NSArray class]] || ![folded isKindOfClass:[NSArray class]] || folded.count == 0) return origResult;

    NSString *u = [username isKindOfClass:[NSString class]] ? username : nil;
    if (!u.length) return origResult;
    BOOL top = WCZZBool(WCZZGroupTopKey, YES);
    for (NSUInteger i = 0; i < rows.count; i++) {
        NSNumber *n = rows[i];
        id session = nil;
        WCZZSetLogicReentry(logic, YES);
        @try { session = [(MainFrameLogicController *)logic getSessionInfoAtIndexPath:[NSIndexPath indexPathForRow:n.integerValue inSection:0]]; } @catch (__unused NSException *e) {}
        WCZZSetLogicReentry(logic, NO);
        if ([WCZZUsername(session) isEqualToString:u]) {
            NSInteger row = top ? (NSInteger)i + 1 : (NSInteger)i;
            return [NSIndexPath indexPathForRow:row inSection:0];
        }
    }
    return origResult;
}

- (long long)indexInAllVisibleSessions:(id)session {
    long long origResult = %orig(session);
    if (!WCZZEnabled() || !WCZZBool(WCZZGroupEnabledKey, YES)) return origResult;
    NSString *u = WCZZUsername(session);
    if (!u.length) return origResult;
    if (WCZZIsGroupUsername(u) && !WCZZIsCommonRoom(u)) return origResult;
    id logic = WCZZValue(self, @"m_mainFrameLogicController");
    NSArray *rows = logic ? WCZZLogicRows(logic) : nil;
    NSArray *folded = logic ? WCZZLogicFolded(logic) : nil;
    if (![rows isKindOfClass:[NSArray class]] || ![folded isKindOfClass:[NSArray class]] || folded.count == 0) return origResult;
    BOOL top = WCZZBool(WCZZGroupTopKey, YES);
    for (NSUInteger i = 0; i < rows.count; i++) {
        NSNumber *n = rows[i];
        id rowSession = nil;
        WCZZSetLogicReentry(logic, YES);
        @try { rowSession = [(MainFrameLogicController *)logic getSessionInfoAtIndexPath:[NSIndexPath indexPathForRow:n.integerValue inSection:0]]; } @catch (__unused NSException *e) {}
        WCZZSetLogicReentry(logic, NO);
        if (rowSession == session || [WCZZUsername(rowSession) isEqualToString:u]) return top ? (long long)i + 1 : (long long)i;
    }
    return origResult;
}

- (id)logicGetSessionAtIndexPath:(id)indexPath {
    NSIndexPath *ip = [indexPath isKindOfClass:[NSIndexPath class]] ? (NSIndexPath *)indexPath : nil;
    if (!ip || ip.section != 0 || !WCZZEnabled() || !WCZZBool(WCZZGroupEnabledKey, YES)) return %orig(indexPath);
    id logic = WCZZValue(self, @"m_mainFrameLogicController");
    NSIndexPath *mapped = logic ? WCZZOriginalIPForLogicRow(logic, ip) : nil;
    if (!mapped) return nil;
    if (mapped.row != ip.row) {
        WCZZSetLogicReentry(logic, YES);
        id result = %orig(mapped);
        WCZZSetLogicReentry(logic, NO);
        return result;
    }
    return %orig(indexPath);
}

- (id)logicGetCellDataAtIndexPath:(id)indexPath {
    NSIndexPath *ip = [indexPath isKindOfClass:[NSIndexPath class]] ? (NSIndexPath *)indexPath : nil;
    if (!ip || ip.section != 0 || !WCZZEnabled() || !WCZZBool(WCZZGroupEnabledKey, YES)) return %orig(indexPath);
    id logic = WCZZValue(self, @"m_mainFrameLogicController");
    if (!logic) return %orig(indexPath);
    NSArray *rows = WCZZLogicRows(logic);
    NSArray *folded = WCZZLogicFolded(logic);
    if (![rows isKindOfClass:[NSArray class]] || ![folded isKindOfClass:[NSArray class]] || folded.count == 0) {
        @try { (void)[(MainFrameLogicController *)logic getSessionCountForSection:0]; } @catch (__unused NSException *e) {}
        rows = WCZZLogicRows(logic);
        folded = WCZZLogicFolded(logic);
    }
    BOOL top = WCZZBool(WCZZGroupTopKey, YES);
    NSInteger helperRow = top ? 0 : (NSInteger)rows.count;
    if (ip.row == helperRow && folded.count > 0) return WCZZBuildHelperCellData(logic);
    NSIndexPath *mapped = WCZZOriginalIPForLogicRow(logic, ip);
    if (!mapped) return nil;
    if (mapped.row != ip.row) {
        WCZZSetLogicReentry(logic, YES);
        id result = %orig(mapped);
        WCZZSetLogicReentry(logic, NO);
        return result;
    }
    return %orig(indexPath);
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSInteger original = %orig(tableView, section);
    if (section != 0 || !WCZZEnabled() || !WCZZBool(WCZZGroupEnabledKey, YES)) return original;

    id logic = WCZZValue(self, @"m_mainFrameLogicController");
    if (!logic) return original;

    long long count = original;
    @try {
        count = [(MainFrameLogicController *)logic getSessionCountForSection:0];
    } @catch (__unused NSException *e) {}

    if (count > 0 && count != original) {
        WCZZLog(@"table rows override original=%ld filtered=%lld", (long)original, count);
        return (NSInteger)count;
    }
    return original;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (!indexPath || indexPath.section != 0 || !WCZZEnabled() || !WCZZBool(WCZZGroupEnabledKey, YES)) {
        return %orig(tableView, indexPath);
    }

    id logic = WCZZValue(self, @"m_mainFrameLogicController");
    NSArray *rows = logic ? WCZZLogicRows(logic) : nil;
    NSArray *folded = logic ? WCZZLogicFolded(logic) : nil;
    if (logic && (![rows isKindOfClass:[NSArray class]] || ![folded isKindOfClass:[NSArray class]])) {
        @try { (void)[(MainFrameLogicController *)logic getSessionCountForSection:0]; } @catch (__unused NSException *e) {}
        rows = WCZZLogicRows(logic);
        folded = WCZZLogicFolded(logic);
    }
    if (![rows isKindOfClass:[NSArray class]] || ![folded isKindOfClass:[NSArray class]] || folded.count == 0) {
        return %orig(tableView, indexPath);
    }

    BOOL top = WCZZBool(WCZZGroupTopKey, YES);
    NSInteger helperRow = top ? 0 : (NSInteger)rows.count;
    if (indexPath.row == helperRow) {
        // Let WeChat build its normal session cell. Our logicGetCellDataAtIndexPath:
        // hook supplies the synthetic 群助手 data for this row.
        WCZZLog(@"table helper cell row=%ld", (long)indexPath.row);
        return %orig(tableView, indexPath);
    }

    NSIndexPath *mapped = WCZZOriginalIPForLogicRow(logic, indexPath);
    if (!mapped) return %orig(tableView, indexPath);

    if (mapped.row != indexPath.row) {
        WCZZSetLogicReentry(logic, YES);
        UITableViewCell *cell = %orig(tableView, mapped);
        WCZZSetLogicReentry(logic, NO);
        return cell;
    }
    return %orig(tableView, indexPath);
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (!indexPath || indexPath.section != 0 || !WCZZEnabled() || !WCZZBool(WCZZGroupEnabledKey, YES)) {
        %orig(tableView, indexPath);
        return;
    }

    id logic = WCZZValue(self, @"m_mainFrameLogicController");
    NSArray *rows = logic ? WCZZLogicRows(logic) : nil;
    NSArray *folded = logic ? WCZZLogicFolded(logic) : nil;
    if (logic && (![rows isKindOfClass:[NSArray class]] || ![folded isKindOfClass:[NSArray class]])) {
        @try { (void)[(MainFrameLogicController *)logic getSessionCountForSection:0]; } @catch (__unused NSException *e) {}
        rows = WCZZLogicRows(logic);
        folded = WCZZLogicFolded(logic);
    }
    if (![rows isKindOfClass:[NSArray class]] || ![folded isKindOfClass:[NSArray class]] || folded.count == 0) {
        %orig(tableView, indexPath);
        return;
    }

    BOOL top = WCZZBool(WCZZGroupTopKey, YES);
    NSInteger helperRow = top ? 0 : (NSInteger)rows.count;
    if (indexPath.row == helperRow) {
        // Prefer WeChat's normal selection chain. If 8.0.75 does not reach
        // MainFrameLogicController -onDidSelectCellAt:, use a delayed fallback.
        UIViewController *base = self;
        %orig(tableView, indexPath);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIViewController *current = WCZZFindMainController();
            if (!current) current = base;
            WCZZPushGroupHelper(current);
        });
        return;
    }

    NSIndexPath *mapped = WCZZOriginalIPForLogicRow(logic, indexPath);
    if (!mapped) return;
    if (mapped.row != indexPath.row) {
        WCZZSetLogicReentry(logic, YES);
        %orig(tableView, mapped);
        WCZZSetLogicReentry(logic, NO);
        return;
    }
    %orig(tableView, indexPath);
}

- (void)handleSelectIndexPath:(id)indexPath tableView:(id)tableView {
    NSIndexPath *ip = [indexPath isKindOfClass:[NSIndexPath class]] ? (NSIndexPath *)indexPath : nil;
    if (!ip || ip.section != 0 || !WCZZEnabled() || !WCZZBool(WCZZGroupEnabledKey, YES)) {
        %orig(indexPath, tableView);
        return;
    }
    id logic = WCZZValue(self, @"m_mainFrameLogicController");
    NSArray *rows = logic ? WCZZLogicRows(logic) : nil;
    NSArray *folded = logic ? WCZZLogicFolded(logic) : nil;
    if (![rows isKindOfClass:[NSArray class]] || ![folded isKindOfClass:[NSArray class]] || folded.count == 0) {
        if (logic) { @try { (void)[(MainFrameLogicController *)logic getSessionCountForSection:0]; } @catch (__unused NSException *e) {} }
        rows = logic ? WCZZLogicRows(logic) : nil;
        folded = logic ? WCZZLogicFolded(logic) : nil;
    }
    BOOL top = WCZZBool(WCZZGroupTopKey, YES);
    NSInteger helperRow = top ? 0 : (NSInteger)rows.count;
    if (folded.count > 0 && ip.row == helperRow) {
        // Centralized in MainFrameLogicController -onDidSelectCellAt:.
        %orig(indexPath, tableView);
        return;
    }
    NSIndexPath *mapped = logic ? WCZZOriginalIPForLogicRow(logic, ip) : nil;
    if (!mapped) return;
    if (mapped.row != ip.row) {
        WCZZSetLogicReentry(logic, YES);
        %orig(mapped, tableView);
        WCZZSetLogicReentry(logic, NO);
        return;
    }
    %orig(indexPath, tableView);
}
- (void)onLogicOpenSession:(id)session {
    NSString *u = WCZZUsername(session);
    if ([u isEqualToString:WCZZGroupUserName]) return;
    %orig(session);
}
%end
%end

#pragma mark - Red envelope summary overlay

static const void *WCZZRedDataKey = &WCZZRedDataKey;
static const void *WCZZRedSummaryLabelKey = &WCZZRedSummaryLabelKey;
static id WCZZLatestRedData = nil;

static id WCZZRedDetailInfo(id data) {
    if (!data) return nil;
    id info = WCZZValue(data, @"m_oWCRedEnvelopesDetailInfo");
    if (info) return info;
    id nested = WCZZValue(data, @"m_data");
    if (nested) {
        info = WCZZValue(nested, @"m_oWCRedEnvelopesDetailInfo");
        if (info) return info;
    }
    return nil;
}

static UILabel *WCZZRedSummaryLabel(id vc) {
    id label = objc_getAssociatedObject(vc, WCZZRedSummaryLabelKey);
    return [label isKindOfClass:[UILabel class]] ? label : nil;
}

static UILabel *WCZZEnsureRedSummaryLabel(id vc) {
    if (!vc || ![vc isKindOfClass:[UIViewController class]]) return nil;
    UILabel *label = WCZZRedSummaryLabel(vc);
    UIViewController *controller = (UIViewController *)vc;
    if (!label) {
        UIView *root = controller.view;
        if (!root) return nil;

        label = [[UILabel alloc] initWithFrame:CGRectZero];
        label.tag = 0x575A01;
        label.numberOfLines = 4;
        label.textAlignment = NSTextAlignmentCenter;
        label.textColor = [UIColor whiteColor];
        label.backgroundColor = [UIColor clearColor];
        label.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightRegular];
        label.userInteractionEnabled = NO;
        label.layer.zPosition = 1000.0;
        [root addSubview:label];
        objc_setAssociatedObject(vc, WCZZRedSummaryLabelKey, label, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return label;
}

static void WCZZLayoutRedSummaryLabel(id vc) {
    UILabel *label = WCZZEnsureRedSummaryLabel(vc);
    if (!label) return;

    UIView *root = [(UIViewController *)vc view];
    // The red header is above/around the safe-area region on this WeChat
    // screen.  Starting at safeAreaInsets.top made the four-line summary get
    // clipped by the header, leaving only about one and a half lines visible.
    // Put the overlay near the very top of the red header instead.
    CGFloat width = MIN(280.0, MAX(230.0, root.bounds.size.width * 0.68));
    CGFloat height = 102.0;
    CGFloat x = (root.bounds.size.width - width) * 0.5;
    CGFloat y = 40.0;
    label.frame = CGRectMake(x, y, width, height);
}

static void WCZZApplyRedSummary(id vc, id data) {
    if (!WCZZEnabled() || !WCZZBool(WCZZRedDetailKey, YES) || !vc || !data) return;

    id info = WCZZRedDetailInfo(data);
    if (!info) {
        WCZZLog(@"red summary: detail info missing data=%p", data);
        return;
    }

    UILabel *label = WCZZEnsureRedSummaryLabel(vc);
    if (!label) return;

    long long totalAmount = MAX(0LL, [WCZZValue(info, @"m_lTotalAmount") longLongValue]);
    long long totalNum = MAX(0LL, [WCZZValue(info, @"m_lTotalNum") longLongValue]);
    long long recAmount = MAX(0LL, [WCZZValue(info, @"m_lRecAmount") longLongValue]);
    long long recNum = MAX(0LL, [WCZZValue(info, @"m_lRecNum") longLongValue]);
    long long remainAmount = MAX(0LL, totalAmount - recAmount);
    long long remainNum = MAX(0LL, totalNum - recNum);

    // IMPORTANT: this is a separate overlay label.  Never modify
    // m_receivedInfoLable, because that label belongs to WeChat's sender/amount
    // area (for example: "小号发出的红包" and "0.01元").
    label.text = [NSString stringWithFormat:@"总金额:%.2f元\n总个数:%lld个\n剩余:%lld个\n剩余:%.2f元",
                  totalAmount / 100.0,
                  totalNum,
                  remainNum,
                  remainAmount / 100.0];
    [label.superview bringSubviewToFront:label];
    WCZZLayoutRedSummaryLabel(vc);
    WCZZLog(@"red summary applied total=%.2f num=%lld remain=%.2f/%lld label=%p",
            totalAmount / 100.0,
            totalNum,
            remainAmount / 100.0,
            remainNum,
            label);
}

static void WCZZScheduleRedSummary(id vc, id data) {
    if (!vc || !data) return;
    objc_setAssociatedObject(vc, WCZZRedDataKey, data, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    for (NSInteger i = 0; i < 6; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * i * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (vc) WCZZApplyRedSummary(vc, data);
        });
    }
}

%group WCZZRedHooks
%hook WCRedEnvelopesControlLogic
- (id)initWithData:(id)data {
    id obj = %orig(data);
    WCZZLatestRedData = data;
    if (obj && data) objc_setAssociatedObject(obj, WCZZRedDataKey, data, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    WCZZLog(@"red control init data=%p", data);
    return obj;
}
- (void)showDetailView {
    %orig;
    id data = WCZZValue(self, @"m_data");
    if (!data) data = objc_getAssociatedObject(self, WCZZRedDataKey);
    WCZZLatestRedData = data ?: WCZZLatestRedData;
    WCZZLog(@"red base showDetailView data=%p", data);
}
%end

%hook WCRedEnvelopesReceiveControlLogic
- (id)initWithData:(id)data Scene:(int)scene {
    id obj = %orig(data, scene);
    WCZZLatestRedData = data;
    WCZZLog(@"red receive init scene=%d data=%p obj=%p", scene, data, obj);
    if (obj && data) objc_setAssociatedObject(obj, WCZZRedDataKey, data, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return obj;
}
- (id)initWithData:(id)data {
    id obj = %orig(data);
    WCZZLatestRedData = data;
    WCZZLog(@"red receive init data=%p obj=%p", data, obj);
    if (obj && data) objc_setAssociatedObject(obj, WCZZRedDataKey, data, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return obj;
}
- (void)showDetailView {
    %orig;
    id data = WCZZValue(self, @"m_data");
    if (!data) data = objc_getAssociatedObject(self, WCZZRedDataKey);
    WCZZLatestRedData = data ?: WCZZLatestRedData;
    WCZZLog(@"red receive showDetailView data=%p", data);
}
%end

%hook WCRedEnvelopesRedEnvelopesDetailViewController
- (id)init {
    id obj = %orig;
    id data = WCZZLatestRedData;
    if (obj && data) objc_setAssociatedObject(obj, WCZZRedDataKey, data, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    WCZZLog(@"red detail init vc=%p", obj);
    return obj;
}
- (void)viewDidLoad {
    %orig;
    id data = objc_getAssociatedObject(self, WCZZRedDataKey);
    if (!data) data = WCZZLatestRedData;
    WCZZLog(@"red detail viewDidLoad data=%p", data);
    if (data) WCZZScheduleRedSummary(self, data);
    WCZZLayoutRedSummaryLabel(self);
}
- (void)viewDidLayoutSubviews {
    %orig;
    UILabel *label = WCZZRedSummaryLabel(self);
    if (label) WCZZLayoutRedSummaryLabel(self);
}
- (void)refreshViewWithData:(id)data {
    %orig(data);
    WCZZLog(@"red refreshViewWithData data=%p", data);
    if (data) WCZZScheduleRedSummary(self, data);
}
- (void)viewWillAppear:(BOOL)animated {
    %orig(animated);
    id data = objc_getAssociatedObject(self, WCZZRedDataKey);
    if (!data) data = WCZZLatestRedData;
    WCZZLog(@"red detail viewWillAppear data=%p", data);
    if (data) WCZZScheduleRedSummary(self, data);
}
- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    id data = objc_getAssociatedObject(self, WCZZRedDataKey);
    if (!data) data = WCZZLatestRedData;
    WCZZLog(@"red detail viewDidAppear data=%p", data);
    if (data) WCZZScheduleRedSummary(self, data);
}
- (void)viewDidDisappear:(BOOL)animated {
    %orig(animated);
    if (WCZZLatestRedData == objc_getAssociatedObject(self, WCZZRedDataKey)) WCZZLatestRedData = nil;
    objc_setAssociatedObject(self, WCZZRedDataKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
%end
%end

#pragma mark - Plugin registration / delayed hook installation

static BOOL WCZZRegistered = NO;
static BOOL WCZZMainHooksStarted = NO;
static BOOL WCZZRedHooksStarted = NO;
static NSInteger WCZZInstallAttempts = 0;

static void WCZZRegisterPlugin(void) {
    if (WCZZRegistered) return;
    Class c = objc_getClass("WCPluginsMgr");
    SEL shared = NSSelectorFromString(@"sharedInstance");
    SEL reg = NSSelectorFromString(@"registerControllerWithTitle:version:controller:");
    if (!c || ![c respondsToSelector:shared]) return;
    id mgr = ((id (*)(id, SEL))objc_msgSend)(c, shared);
    if (!mgr || ![mgr respondsToSelector:reg]) return;
    ((void (*)(id, SEL, id, id, id))objc_msgSend)(mgr, reg, @"wczz", @"1.0-29", @"WCZZSettingsViewController");
    WCZZRegistered = YES;
    WCZZLog(@"plugin registration OK");
}

static void WCZZInstallHooksWhenReady(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!WCZZMainHooksStarted && objc_getClass("MainFrameLogicController")) {
            %init(WCZZMainLogicHooks);
            %init(WCZZMainOpenSessionHook);
            WCZZMainHooksStarted = YES;
            WCZZLog(@"main logic hooks installed");
            WCZZReloadMainList();
        }
        if (!WCZZRedHooksStarted &&
            objc_getClass("WCRedEnvelopesControlLogic") &&
            objc_getClass("WCRedEnvelopesReceiveControlLogic") &&
            objc_getClass("WCRedEnvelopesRedEnvelopesDetailViewController")) {
            %init(WCZZRedHooks);
            WCZZRedHooksStarted = YES;
            WCZZLog(@"red hooks installed");
        }
        WCZZRegisterPlugin();
        if ((!WCZZMainHooksStarted || !WCZZRedHooksStarted || !WCZZRegistered) && WCZZInstallAttempts++ < 60) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.75 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                WCZZInstallHooksWhenReady();
            });
        }
    });
}

%ctor {
    @autoreleasepool {
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        if ([d objectForKey:WCZZPluginEnabledKey] == nil) [d setBool:YES forKey:WCZZPluginEnabledKey];
        if ([d objectForKey:WCZZGroupEnabledKey] == nil) [d setBool:YES forKey:WCZZGroupEnabledKey];
        if ([d objectForKey:WCZZGroupTopKey] == nil) [d setBool:YES forKey:WCZZGroupTopKey];
        if ([d objectForKey:WCZZRedDetailKey] == nil) [d setBool:YES forKey:WCZZRedDetailKey];
        if ([d objectForKey:WCZZCommonRoomsKey] == nil) [d setObject:@[] forKey:WCZZCommonRoomsKey];
        if ([d objectForKey:WCZZGroupAvatarKey] == nil) [d setObject:@"默认头像" forKey:WCZZGroupAvatarKey];
        if ([d objectForKey:WCZZDebugEnabledKey] == nil) [d setBool:NO forKey:WCZZDebugEnabledKey];
        if ([d objectForKey:WCZZDebugLogsKey] == nil) [d setObject:@[] forKey:WCZZDebugLogsKey];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        WCZZFlushDebugLogs();
    }];
        WCZZLog(@"v1.0-29 constructor");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ WCZZInstallHooksWhenReady(); });
    }
}
