#import "WeChatCompat.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#pragma mark - wczz 1.0-0 (independent implementation)

static NSString * const WCZZPluginEnabledKey = @"wczz.plugin.enabled";
static NSString * const WCZZGroupEnabledKey  = @"wczz.group.enabled";
static NSString * const WCZZGroupTopKey      = @"wczz.group.top";
static NSString * const WCZZCommonRoomsKey   = @"wczz.group.commonRooms";
static NSString * const WCZZRedDetailKey     = @"wczz.redDetail.enabled";
static NSString * const WCZZGroupUserName    = @"wczz_group_helper";

static BOOL WCZZBool(NSString *key, BOOL fallback) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    return v ? [v boolValue] : fallback;
}
static void WCZZSetBool(NSString *key, BOOL value) {
    [[NSUserDefaults standardUserDefaults] setBool:value forKey:key];
    [[NSUserDefaults standardUserDefaults] synchronize];
}
static BOOL WCZZPluginEnabled(void) { return WCZZBool(WCZZPluginEnabledKey, YES); }

static NSArray *WCZZCommonRooms(void) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:WCZZCommonRoomsKey];
    return [v isKindOfClass:[NSArray class]] ? v : @[];
}
static void WCZZSetCommonRooms(NSArray *rooms) {
    [[NSUserDefaults standardUserDefaults] setObject:rooms ?: @[] forKey:WCZZCommonRoomsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
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
static BOOL WCZZIsChatRoomContact(id contact) {
    if (!contact) return NO;
    Class c = objc_getClass("CContact");
    SEL s = NSSelectorFromString(@"IsChatRoomContact:");
    if (c && [c respondsToSelector:s]) {
        @try {
            if (((BOOL (*)(id, SEL, id))objc_msgSend)(c, s, contact)) return YES;
        } @catch (__unused NSException *e) {}
    }
    NSString *username = WCZZValue(contact, @"m_nsUsrName");
    return [username isKindOfClass:[NSString class]] && [username hasSuffix:@"@chatroom"];
}
static NSString *WCZZContactDisplayName(id contact) {
    if (!contact) return @"群聊";
    SEL s = NSSelectorFromString(@"getContactDisplayName");
    if ([contact respondsToSelector:s]) {
        @try {
            id name = ((id (*)(id, SEL))objc_msgSend)(contact, s);
            if ([name isKindOfClass:[NSString class]] && [name length]) return name;
        } @catch (__unused NSException *e) {}
    }
    id n = WCZZValue(contact, @"m_nsNickName");
    return [n isKindOfClass:[NSString class]] && [n length] ? n : @"群聊";
}
static BOOL WCZZIsCommonRoom(NSString *username) {
    return username.length && [WCZZCommonRooms() containsObject:username];
}
static BOOL WCZZShouldFoldSession(id session) {
    if (!WCZZPluginEnabled() || !WCZZBool(WCZZGroupEnabledKey, YES)) return NO;
    NSString *username = WCZZUsername(session);
    id contact = WCZZContact(session);
    if (!username.length || !contact) return NO;
    return WCZZIsChatRoomContact(contact) && !WCZZIsCommonRoom(username);
}

#pragma mark - Session service

static NSArray *WCZZAllSessionInfoList(void) {
    Class ctxClass = objc_getClass("MMContext");
    Class mgrClass = objc_getClass("MMNewSessionMgr");
    SEL currentSel = NSSelectorFromString(@"currentContext");
    SEL getService = NSSelectorFromString(@"getService:");
    SEL getList = NSSelectorFromString(@"GetSessionInfoList");
    if (!ctxClass || !mgrClass || ![ctxClass respondsToSelector:currentSel]) return @[];
    id ctx = ((id (*)(id, SEL))objc_msgSend)(ctxClass, currentSel);
    id center = WCZZValue(ctx, @"serviceCenter");
    if (!center || ![center respondsToSelector:getService]) return @[];
    id mgr = ((id (*)(id, SEL, Class))objc_msgSend)(center, getService, mgrClass);
    if (!mgr || ![mgr respondsToSelector:getList]) return @[];
    id list = ((id (*)(id, SEL))objc_msgSend)(mgr, getList);
    return [list isKindOfClass:[NSArray class]] ? list : @[];
}

static void WCZZMarkSessionRead(id session) {
    NSString *username = WCZZUsername(session);
    if (!username.length) return;
    Class ctxClass = objc_getClass("MMContext");
    Class mgrClass = objc_getClass("MMNewSessionMgr");
    SEL currentSel = NSSelectorFromString(@"currentContext");
    SEL getService = NSSelectorFromString(@"getService:");
    SEL clearSel = NSSelectorFromString(@"ChangeSessionUnReadCount:to:");
    if (!ctxClass || !mgrClass || ![ctxClass respondsToSelector:currentSel]) return;
    id ctx = ((id (*)(id, SEL))objc_msgSend)(ctxClass, currentSel);
    id center = WCZZValue(ctx, @"serviceCenter");
    if (!center || ![center respondsToSelector:getService]) return;
    id mgr = ((id (*)(id, SEL, Class))objc_msgSend)(center, getService, mgrClass);
    if (!mgr || ![mgr respondsToSelector:clearSel]) return;
    @try {
        ((void (*)(id, SEL, id, unsigned int))objc_msgSend)(mgr, clearSel, username, 0U);
    } @catch (__unused NSException *e) {
        NSLog(@"[wczz] ChangeSessionUnReadCount failed for %@", username);
    }
}

#pragma mark - Main-list reload / session mapping

static UIViewController *WCZZFindMainController(void) {
    Class mainClass = objc_getClass("NewMainFrameViewController");
    if (!mainClass) return nil;
    UIApplication *app = UIApplication.sharedApplication;
    NSMutableArray *roots = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (scene.activationState == UISceneActivationStateUnattached) continue;
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (window.rootViewController) [roots addObject:window.rootViewController];
            }
        }
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        for (UIWindow *window in app.windows) if (window.rootViewController) [roots addObject:window.rootViewController];
#pragma clang diagnostic pop
    }
    NSMutableArray *stack = [NSMutableArray arrayWithArray:roots];
    NSHashTable *visited = [NSHashTable weakObjectsHashTable];
    while (stack.count) {
        UIViewController *cur = stack.lastObject;
        [stack removeLastObject];
        if (!cur || [visited containsObject:cur]) continue;
        [visited addObject:cur];
        if ([cur isKindOfClass:mainClass]) return cur;
        if (cur.presentedViewController) [stack addObject:cur.presentedViewController];
        if (cur.navigationController && cur.navigationController != cur) [stack addObject:cur.navigationController];
        for (UIViewController *child in cur.childViewControllers) [stack addObject:child];
    }
    return nil;
}

static void WCZZRequestMainListReload(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = WCZZFindMainController();
        if (!vc) return;
        SEL reload = NSSelectorFromString(@"reloadSessions");
        if ([vc respondsToSelector:reload]) {
            @try { ((void (*)(id, SEL))objc_msgSend)(vc, reload); }
            @catch (__unused NSException *e) { NSLog(@"[wczz] reloadSessions failed"); }
        }
    });
}

static id WCZZLogicForMain(UIViewController *vc) {
    return WCZZValue(vc, @"m_mainFrameLogicController");
}

static const void *WCZZMainRowsCacheKey = &WCZZMainRowsCacheKey;
static void WCZZCacheMainRows(UIViewController *vc, long long originalCount, NSArray *visibleRows) {
    if (!vc) return;
    NSDictionary *cache = @{ @"count": @(originalCount), @"rows": visibleRows ?: @[] };
    objc_setAssociatedObject(vc, WCZZMainRowsCacheKey, cache, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static NSDictionary *WCZZMainRowsCache(UIViewController *vc) {
    return vc ? objc_getAssociatedObject(vc, WCZZMainRowsCacheKey) : nil;
}

/*
 * Build the original row -> session map by asking WeChat's own logic object.
 * This avoids assuming that m_arrFilteredSession.count equals the table row
 * count (top/fold/search states can make those counts differ).
 */
static NSArray<NSNumber *> *WCZZVisibleOriginalRows(UIViewController *vc, NSInteger originalCount) {
    id logic = WCZZLogicForMain(vc);
    if (!logic || originalCount <= 0) return @[];
    SEL sel = NSSelectorFromString(@"getSessionInfoAtIndexPath:");
    if (![logic respondsToSelector:sel]) return @[];
    NSMutableArray *rows = [NSMutableArray array];
    for (NSInteger i = 0; i < originalCount; i++) {
        NSIndexPath *ip = [NSIndexPath indexPathForRow:i inSection:0];
        id session = nil;
        @try { session = ((id (*)(id, SEL, id))objc_msgSend)(logic, sel, ip); }
        @catch (__unused NSException *e) { session = nil; }
        if (!WCZZShouldFoldSession(session)) [rows addObject:@(i)];
    }
    return rows;
}

static UITableViewCell *WCZZMakeHelperCell(UITableView *tableView, NSUInteger groupCount) {
    static NSString *identifier = @"wczz.helper.cell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
    cell.textLabel.text = @"群助手";
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu 个群聊", (unsigned long)groupCount];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

#pragma mark - Group helper controllers

@interface WCZZCommonRoomsViewController : UITableViewController
@property(nonatomic,weak) id mainController;
@property(nonatomic,retain) NSArray *groups;
@property(nonatomic,retain) NSMutableSet *selected;
@end

@interface WCZZGroupHelperViewController : UITableViewController
@property(nonatomic,weak) id mainController;
@property(nonatomic,retain) NSArray *sessions;
@end

@implementation WCZZGroupHelperViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"群助手";
    self.tableView.tableFooterView = [UIView new];
    self.tableView.rowHeight = 60.0;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(wczzMore)];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    NSMutableArray *groups = [NSMutableArray array];
    for (id s in WCZZAllSessionInfoList()) if (WCZZShouldFoldSession(s)) [groups addObject:s];
    self.sessions = groups;
    [self.tableView reloadData];
}
- (void)wczzMore {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:nil message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:@"一键已读" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *x) {
        NSArray *snapshot = [self.sessions copy];
        // The action runs on the main queue and operates on a stable username snapshot.
        NSMutableArray *names = [NSMutableArray arrayWithCapacity:snapshot.count];
        for (id s in snapshot) { NSString *u = WCZZUsername(s); if (u.length) [names addObject:u]; }
        Class ctxClass = objc_getClass("MMContext");
        Class mgrClass = objc_getClass("MMNewSessionMgr");
        SEL currentSel = NSSelectorFromString(@"currentContext");
        SEL getService = NSSelectorFromString(@"getService:");
        SEL clearSel = NSSelectorFromString(@"ChangeSessionUnReadCount:to:");
        id ctx = (ctxClass && [ctxClass respondsToSelector:currentSel]) ? ((id (*)(id,SEL))objc_msgSend)(ctxClass,currentSel) : nil;
        id center = WCZZValue(ctx, @"serviceCenter");
        id mgr = (center && mgrClass && [center respondsToSelector:getService]) ? ((id (*)(id,SEL,Class))objc_msgSend)(center,getService,mgrClass) : nil;
        if (mgr && [mgr respondsToSelector:clearSel]) {
            for (NSString *u in names) {
                @try { ((void (*)(id,SEL,id,unsigned int))objc_msgSend)(mgr,clearSel,u,0U); } @catch (__unused NSException *e) {}
            }
        }
        [self.tableView reloadData];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"管理常用群" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *x) {
        WCZZCommonRoomsViewController *vc = [WCZZCommonRoomsViewController new];
        vc.mainController = self.mainController;
        [self.navigationController pushViewController:vc animated:YES];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section { return section == 0 ? self.sessions.count : 0; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *ID = @"wczz.group.session";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:ID];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:ID];
    if (ip.row < self.sessions.count) {
        id s = self.sessions[ip.row];
        cell.textLabel.text = WCZZContactDisplayName(WCZZContact(s));
        NSUInteger unread = [WCZZValue(s, @"m_uUnReadCount") unsignedIntegerValue];
        cell.detailTextLabel.text = unread ? [NSString stringWithFormat:@"%lu 条未读", (unsigned long)unread] : @"";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.row >= self.sessions.count) return;
    id session = self.sessions[ip.row];
    id controller = self.mainController;
    SEL open = NSSelectorFromString(@"onLogicOpenSession:");
    if (controller && [controller respondsToSelector:open]) {
        @try { ((void (*)(id,SEL,id))objc_msgSend)(controller,open,session); } @catch (__unused NSException *e) {}
    }
}
@end

@implementation WCZZCommonRoomsViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"常用群";
    self.tableView.tableFooterView = [UIView new];
    self.selected = [NSMutableSet setWithArray:WCZZCommonRooms()];
    NSMutableArray *groups = [NSMutableArray array];
    for (id s in WCZZAllSessionInfoList()) {
        NSString *u = WCZZUsername(s);
        if (u.length && WCZZIsChatRoomContact(WCZZContact(s))) [groups addObject:s];
    }
    self.groups = groups;
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section { return section == 0 ? self.groups.count : 0; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *ID = @"wczz.common.room";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:ID];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:ID];
    if (ip.row < self.groups.count) {
        id s = self.groups[ip.row];
        NSString *u = WCZZUsername(s);
        cell.textLabel.text = WCZZContactDisplayName(WCZZContact(s));
        cell.accessoryType = [self.selected containsObject:u] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    }
    return cell;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.row >= self.groups.count) return;
    id s = self.groups[ip.row];
    NSString *u = WCZZUsername(s);
    if (!u.length) return;
    if ([self.selected containsObject:u]) [self.selected removeObject:u]; else [self.selected addObject:u];
    WCZZSetCommonRooms(self.selected.allObjects);
    [tv reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
    WCZZRequestMainListReload();
}
@end

#pragma mark - Settings

@interface WCZZSettingsViewController : UITableViewController @end
@implementation WCZZSettingsViewController
- (instancetype)init:(id)__unused pluginModel { return [super initWithStyle:UITableViewStyleGrouped]; }
- (void)viewDidLoad { [super viewDidLoad]; self.title = @"wczz"; self.tableView.tableFooterView = [UIView new]; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section { return section == 0 ? 5 : 0; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *ID = @"wczz.setting";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:ID];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:ID];
    cell.accessoryView = nil; cell.accessoryType = UITableViewCellAccessoryNone;
    if (ip.row <= 3) {
        UISwitch *sw = [UISwitch new];
        sw.tag = 99 + ip.row;
        sw.on = ip.row == 0 ? WCZZPluginEnabled() : ip.row == 1 ? WCZZBool(WCZZGroupEnabledKey, YES) : ip.row == 2 ? WCZZBool(WCZZGroupTopKey, YES) : WCZZBool(WCZZRedDetailKey, YES);
        cell.textLabel.text = ip.row == 0 ? @"启用 wczz" : ip.row == 1 ? @"开启群助手" : ip.row == 2 ? @"置顶群助手" : @"红包详情";
        [sw addTarget:self action:@selector(wczzSwitch:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
    } else {
        cell.textLabel.text = @"常用群";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}
- (void)wczzSwitch:(UISwitch *)sw {
    if (sw.tag == 99) WCZZSetBool(WCZZPluginEnabledKey, sw.on);
    else if (sw.tag == 100) WCZZSetBool(WCZZGroupEnabledKey, sw.on);
    else if (sw.tag == 101) WCZZSetBool(WCZZGroupTopKey, sw.on);
    else if (sw.tag == 102) WCZZSetBool(WCZZRedDetailKey, sw.on);
    WCZZRequestMainListReload();
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.row <= 3) {
        UISwitch *sw = (UISwitch *)[(UITableViewCell *)[tv cellForRowAtIndexPath:ip] accessoryView];
        if ([sw isKindOfClass:[UISwitch class]]) [sw setOn:!sw.on animated:YES];
        [self wczzSwitch:sw];
        return;
    }
    if (ip.row == 4) {
        WCZZCommonRoomsViewController *vc = [WCZZCommonRoomsViewController new];
        vc.mainController = nil;
        [self.navigationController pushViewController:vc animated:YES];
    }
}
@end

#pragma mark - Main list: direct UITableView data-source boundary

%hook NewMainFrameViewController
- (long long)tableView:(id)tableView numberOfRowsInSection:(long long)section {
    long long original = %orig(tableView, section);
    if (section != 0 || !WCZZPluginEnabled() || !WCZZBool(WCZZGroupEnabledKey, YES)) return original;
    NSArray *visibleRows = WCZZVisibleOriginalRows(self, original);
    WCZZCacheMainRows(self, original, visibleRows);
    if (visibleRows.count == 0) return original;
    if (visibleRows.count == (NSUInteger)original) return original;
    return (long long)visibleRows.count + 1;
}

- (id)tableView:(id)tableView cellForRowAtIndexPath:(id)indexPath {
    if (!WCZZPluginEnabled() || !WCZZBool(WCZZGroupEnabledKey, YES) || ![indexPath respondsToSelector:@selector(section)] || [indexPath section] != 0) return %orig(tableView, indexPath);
    NSDictionary *cache = WCZZMainRowsCache(self);
    long long originalCount = [cache[@"count"] longLongValue];
    NSArray *visibleRows = cache[@"rows"];
    if (!cache || originalCount <= 0 || ![visibleRows isKindOfClass:[NSArray class]]) {
        id logic = WCZZLogicForMain(self);
        SEL countSel = NSSelectorFromString(@"getSessionCountForSection:");
        originalCount = (logic && [logic respondsToSelector:countSel]) ? ((long long (*)(id,SEL,long long))objc_msgSend)(logic, countSel, 0) : 0;
        visibleRows = WCZZVisibleOriginalRows(self, originalCount);
        WCZZCacheMainRows(self, originalCount, visibleRows);
    }
    if (visibleRows.count == (NSUInteger)originalCount || visibleRows.count == 0) return %orig(tableView, indexPath);
    NSUInteger row = [indexPath row];
    BOOL top = WCZZBool(WCZZGroupTopKey, YES);
    BOOL helper = (top && row == 0) || (!top && row == visibleRows.count);
    if (helper) return WCZZMakeHelperCell((UITableView *)tableView, originalCount - visibleRows.count);
    NSUInteger visibleIndex = top ? (row > 0 ? row - 1 : NSUIntegerMax) : row;
    if (visibleIndex >= visibleRows.count) return %orig(tableView, indexPath);
    NSIndexPath *origIP = [NSIndexPath indexPathForRow:[visibleRows[visibleIndex] integerValue] inSection:0];
    return %orig(tableView, origIP);
}

- (void)tableView:(id)tableView didSelectRowAtIndexPath:(id)indexPath {
    if (WCZZPluginEnabled() && WCZZBool(WCZZGroupEnabledKey, YES) && [indexPath respondsToSelector:@selector(section)] && [indexPath section] == 0) {
        id logic = WCZZLogicForMain(self);
        SEL countSel = NSSelectorFromString(@"getSessionCountForSection:");
        long long originalCount = (logic && [logic respondsToSelector:countSel]) ? ((long long (*)(id,SEL,long long))objc_msgSend)(logic, countSel, 0) : 0;
        NSArray *visibleRows = WCZZVisibleOriginalRows(self, originalCount);
        if (visibleRows.count > 0 && visibleRows.count < (NSUInteger)originalCount) {
            NSUInteger row = [indexPath row];
            BOOL top = WCZZBool(WCZZGroupTopKey, YES);
            BOOL helper = (top && row == 0) || (!top && row == visibleRows.count);
            if (helper) {
                [tableView deselectRowAtIndexPath:indexPath animated:YES];
                WCZZGroupHelperViewController *vc = [WCZZGroupHelperViewController new];
                vc.mainController = self;
                [self.navigationController pushViewController:vc animated:YES];
                return;
            }
            NSUInteger visibleIndex = top ? (row > 0 ? row - 1 : NSUIntegerMax) : row;
            if (visibleIndex < visibleRows.count) {
                NSIndexPath *origIP = [NSIndexPath indexPathForRow:[visibleRows[visibleIndex] integerValue] inSection:0];
                %orig(tableView, origIP);
                return;
            }
        }
    }
    %orig(tableView, indexPath);
}
%end

#pragma mark - Red detail

static void WCZZApplyRedDetail(id vc) {
    if (!WCZZPluginEnabled() || !WCZZBool(WCZZRedDetailKey, YES) || !vc) return;
    id info = WCZZValue(vc, @"m_oWCRedEnvelopesDetailInfo");
    if (!info) return;
    long long totalAmount = [WCZZValue(info, @"m_lTotalAmount") longLongValue];
    long long totalNum = [WCZZValue(info, @"m_lTotalNum") longLongValue];
    long long recNum = [WCZZValue(info, @"m_lRecNum") longLongValue];
    long long recAmount = [WCZZValue(info, @"m_lRecAmount") longLongValue];
    if (totalAmount <= 0 && totalNum <= 0 && recNum <= 0 && recAmount <= 0) return;
    id labelObj = WCZZValue(vc, @"m_receivedInfoLable");
    if (![labelObj isKindOfClass:[UILabel class]]) return;
    UILabel *label = (UILabel *)labelObj;
    label.text = [NSString stringWithFormat:@"共 %.2f 元 · %lld 人 · 已领取 %lld 人 / %.2f 元", totalAmount / 100.0, totalNum, recNum, recAmount / 100.0];
}

%hook WCRedEnvelopesRedEnvelopesDetailViewController
- (void)refreshViewWithData:(id)data {
    %orig(data);
    if (!WCZZPluginEnabled() || !WCZZBool(WCZZRedDetailKey, YES)) return;
    dispatch_async(dispatch_get_main_queue(), ^{ WCZZApplyRedDetail(self); });
}
- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    if (!WCZZPluginEnabled() || !WCZZBool(WCZZRedDetailKey, YES)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        WCZZApplyRedDetail(self);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ WCZZApplyRedDetail(self); });
    });
}
%end

#pragma mark - Plugin manager registration

static BOOL WCZZPluginManagerRegistered = NO;
static void WCZZRegisterPluginManager(void) {
    if (WCZZPluginManagerRegistered) return;
    Class mgrClass = objc_getClass("WCPluginsMgr");
    if (!mgrClass) return;
    SEL shared = NSSelectorFromString(@"sharedInstance");
    SEL reg = NSSelectorFromString(@"registerControllerWithTitle:version:controller:");
    if (![mgrClass respondsToSelector:shared]) return;
    id mgr = ((id (*)(id,SEL))objc_msgSend)(mgrClass,shared);
    if (!mgr || ![mgr respondsToSelector:reg]) return;
    ((void (*)(id,SEL,id,id,id))objc_msgSend)(mgr,reg,@"wczz",@"1.0-0",@"WCZZSettingsViewController");
    WCZZPluginManagerRegistered = YES;
}

%ctor {
    NSLog(@"[wczz] loaded into WeChat");
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:WCZZPluginEnabledKey] == nil) [d setBool:YES forKey:WCZZPluginEnabledKey];
    if ([d objectForKey:WCZZGroupEnabledKey] == nil) [d setBool:YES forKey:WCZZGroupEnabledKey];
    if ([d objectForKey:WCZZGroupTopKey] == nil) [d setBool:YES forKey:WCZZGroupTopKey];
    if ([d objectForKey:WCZZRedDetailKey] == nil) [d setBool:YES forKey:WCZZRedDetailKey];
    if ([d objectForKey:WCZZCommonRoomsKey] == nil) [d setObject:@[] forKey:WCZZCommonRoomsKey];
    [d synchronize];
    dispatch_async(dispatch_get_main_queue(), ^{
        WCZZRegisterPluginManager();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ WCZZRegisterPluginManager(); WCZZRequestMainListReload(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ WCZZRegisterPluginManager(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ WCZZRegisterPluginManager(); });
    });
}
