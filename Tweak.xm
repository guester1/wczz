#import "WeChatCompat.h"
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

// wczz 1.0-3
// Independent implementation. Runtime dependency: WeChat only.

static NSString * const WCZZPluginEnabledKey = @"wczz.plugin.enabled";
static NSString * const WCZZGroupEnabledKey  = @"wczz.group.enabled";
static NSString * const WCZZGroupTopKey      = @"wczz.group.top";
static NSString * const WCZZCommonRoomsKey   = @"wczz.group.commonRooms";
static NSString * const WCZZRedDetailKey     = @"wczz.redDetail.enabled";
static NSString * const WCZZGroupUserName    = @"wczz_group_helper";
static NSString * const WCZZGroupAvatarKey   = @"wczz.group.avatar";

static BOOL WCZZBool(NSString *key, BOOL fallback) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    return v ? [v boolValue] : fallback;
}
static void WCZZSetBool(NSString *key, BOOL value) {
    [[NSUserDefaults standardUserDefaults] setBool:value forKey:key];
    [[NSUserDefaults standardUserDefaults] synchronize];
}
static BOOL WCZZEnabled(void) { return WCZZBool(WCZZPluginEnabledKey, YES); }
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
    return [v isKindOfClass:[NSString class]] ? (NSString *)v : nil;
}
static id WCZZContact(id session) { return WCZZValue(session, @"m_contact"); }
static BOOL WCZZIsGroupUsername(NSString *username) {
    return [username isKindOfClass:[NSString class]] && username.length > 0 && [username hasSuffix:@"@chatroom"];
}
static BOOL WCZZIsChatRoom(id __unused contact, NSString *username) { return WCZZIsGroupUsername(username); }

static BOOL WCZZIsCommonRoom(NSString *u) {
    return u.length > 0 && [WCZZCommonRooms() containsObject:u];
}
static BOOL WCZZShouldFold(id session) {
    if (!WCZZEnabled() || !WCZZBool(WCZZGroupEnabledKey, YES) || !session) return NO;
    NSString *u = WCZZUsername(session);
    if (!WCZZIsGroupUsername(u)) return NO;
    if (WCZZIsCommonRoom(u)) return NO;
    return YES;
}
static NSString *WCZZDisplayName(id contact) {
    SEL s = NSSelectorFromString(@"getContactDisplayName");
    if (contact && [contact respondsToSelector:s]) {
        @try {
            id n = ((id (*)(id, SEL))objc_msgSend)(contact, s);
            if ([n isKindOfClass:[NSString class]] && [(NSString *)n length] > 0) return (NSString *)n;
        } @catch (__unused NSException *e) {}
    }
    id n = WCZZValue(contact, @"m_nsNickName");
    if ([n isKindOfClass:[NSString class]] && [(NSString *)n length] > 0) return (NSString *)n;
    return @"群聊";
}

#pragma mark - WeChat Session service

static NSArray *WCZZSessionList(void) {
    Class ctxClass = objc_getClass("MMContext");
    Class mgrClass = objc_getClass("MMNewSessionMgr");
    SEL currentSel = NSSelectorFromString(@"currentContext");
    SEL serviceSel = NSSelectorFromString(@"getService:");
    SEL listSel = NSSelectorFromString(@"GetSessionInfoList");
    if (!ctxClass || !mgrClass || ![ctxClass respondsToSelector:currentSel]) return @[];
    id ctx = ((id (*)(id, SEL))objc_msgSend)(ctxClass, currentSel);
    id center = WCZZValue(ctx, @"serviceCenter");
    if (!center || ![center respondsToSelector:serviceSel]) return @[];
    id mgr = ((id (*)(id, SEL, Class))objc_msgSend)(center, serviceSel, mgrClass);
    if (!mgr || ![mgr respondsToSelector:listSel]) return @[];
    id list = ((id (*)(id, SEL))objc_msgSend)(mgr, listSel);
    return [list isKindOfClass:[NSArray class]] ? (NSArray *)list : @[];
}
static void WCZZMarkRead(NSString *username) {
    if (!username.length) return;
    Class ctxClass = objc_getClass("MMContext");
    Class mgrClass = objc_getClass("MMNewSessionMgr");
    SEL currentSel = NSSelectorFromString(@"currentContext");
    SEL serviceSel = NSSelectorFromString(@"getService:");
    SEL clearSel = NSSelectorFromString(@"ChangeSessionUnReadCount:to:");
    if (!ctxClass || !mgrClass || ![ctxClass respondsToSelector:currentSel]) return;
    id ctx = ((id (*)(id, SEL))objc_msgSend)(ctxClass, currentSel);
    id center = WCZZValue(ctx, @"serviceCenter");
    if (!center || ![center respondsToSelector:serviceSel]) return;
    id mgr = ((id (*)(id, SEL, Class))objc_msgSend)(center, serviceSel, mgrClass);
    if (!mgr || ![mgr respondsToSelector:clearSel]) return;
    @try {
        // The first argument is the session username; the new unread count is zero.
        ((void (*)(id, SEL, id, unsigned int))objc_msgSend)(mgr, clearSel, username, 0U);
    } @catch (__unused NSException *e) {
        NSLog(@"[wczz] ChangeSessionUnReadCount failed: %@", username);
    }
}

#pragma mark - Main controller discovery / reload

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
        UIViewController *presented = cur.presentedViewController;
        if (presented) [stack addObject:presented];
        UINavigationController *nav = cur.navigationController;
        if (nav && nav != cur) [stack addObject:nav];
        for (UIViewController *child in cur.childViewControllers) [stack addObject:child];
    }
    return nil;
}
static void WCZZReloadMainList(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = WCZZFindMainController();
        if (!vc) return;
        id tv = WCZZValue(vc, @"m_tableView");
        if ([tv isKindOfClass:[UITableView class]]) {
            [(UITableView *)tv reloadData];
            return;
        }
        SEL reload = NSSelectorFromString(@"reloadSessions");
        if ([vc respondsToSelector:reload]) {
            @try { ((void (*)(id, SEL))objc_msgSend)(vc, reload); } @catch (__unused NSException *e) {}
        }
    });
}

#pragma mark - Group helper UI declarations

@interface WCZZCommonRoomsViewController : UITableViewController
@property(nonatomic, strong) NSArray *groups;
@property(nonatomic, strong) NSMutableSet *selected;
@end

@interface WCZZGroupHelperViewController : UITableViewController
@property(nonatomic, weak) UIViewController *mainController;
@property(nonatomic, strong) NSArray *sessions;
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
    for (id session in WCZZSessionList()) if (WCZZShouldFold(session)) [groups addObject:session];
    self.sessions = groups;
    [self.tableView reloadData];
}
- (void)wczzMore {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:nil message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:@"一键已读" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSArray *snapshot = [self.sessions copy];
        NSMutableArray *names = [NSMutableArray arrayWithCapacity:snapshot.count];
        for (id session in snapshot) {
            NSString *u = WCZZUsername(session);
            if (u.length) [names addObject:u];
        }
        for (NSString *u in names) WCZZMarkRead(u);
        // Refresh only the helper UI. Do not trigger a session rebuild here.
        NSMutableArray *groups = [NSMutableArray array];
        for (id session in WCZZSessionList()) if (WCZZShouldFold(session)) [groups addObject:session];
        self.sessions = groups;
        [self.tableView reloadData];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"管理常用群" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        WCZZCommonRoomsViewController *v = [WCZZCommonRoomsViewController new];
        [self.navigationController pushViewController:v animated:YES];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section { return section == 0 ? (NSInteger)self.sessions.count : 0; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *ID = @"wczz.group";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:ID];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:ID];
    if (ip.row < self.sessions.count) {
        id session = self.sessions[ip.row];
        cell.textLabel.text = WCZZDisplayName(WCZZContact(session));
        unsigned long n = [WCZZValue(session, @"m_uUnReadCount") unsignedLongValue];
        cell.detailTextLabel.text = n ? [NSString stringWithFormat:@"%lu 条未读", n] : @"";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.row >= self.sessions.count) return;
    id session = self.sessions[ip.row];
    UIViewController *main = self.mainController;
    SEL open = NSSelectorFromString(@"onLogicOpenSession:");
    if (main && [main respondsToSelector:open]) {
        @try { ((void (*)(id, SEL, id))objc_msgSend)(main, open, session); } @catch (__unused NSException *e) {}
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
    for (id session in WCZZSessionList()) {
        NSString *u = WCZZUsername(session);
        if (WCZZIsGroupUsername(u)) [groups addObject:session];
    }
    self.groups = groups;
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section { return section == 0 ? (NSInteger)self.groups.count : 0; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *ID = @"wczz.common";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:ID];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:ID];
    if (ip.row < self.groups.count) {
        id session = self.groups[ip.row];
        NSString *u = WCZZUsername(session);
        cell.textLabel.text = WCZZDisplayName(WCZZContact(session));
        cell.accessoryType = [self.selected containsObject:u] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    }
    return cell;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.row >= self.groups.count) return;
    NSString *u = WCZZUsername(self.groups[ip.row]);
    if (!u.length) return;
    if ([self.selected containsObject:u]) [self.selected removeObject:u];
    else [self.selected addObject:u];
    WCZZSetCommonRooms(self.selected.allObjects);
    [tv reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
    WCZZReloadMainList();
}
@end

#pragma mark - Settings

@interface WCZZGroupSettingsViewController : UITableViewController @end

@implementation WCZZGroupSettingsViewController
- (instancetype)init { return [super initWithStyle:UITableViewStyleGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"群助手";
    self.tableView.tableFooterView = [UIView new];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 3; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 2;       // 开启 / 置顶
    if (section == 1) return 2;       // 头像 / 常用群
    NSInteger count = 0;
    for (id session in WCZZSessionList()) if (WCZZIsGroupUsername(WCZZUsername(session))) count++;
    return MIN(20, count); // 只显示群聊
}
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    if (section == 2) return @"开启群助手后会将微信群归纳至群助手，可以通过常用群列表筛选不想被归纳的群。";
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *ID = @"wczz.group.setting";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:ID];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:ID];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.detailTextLabel.text = nil;

    if (ip.section == 0) {
        cell.textLabel.text = ip.row == 0 ? @"开启群助手" : @"置顶群助手";
        UISwitch *sw = [UISwitch new];
        sw.tag = 500 + ip.row;
        sw.on = ip.row == 0 ? WCZZBool(WCZZGroupEnabledKey, YES) : WCZZBool(WCZZGroupTopKey, YES);
        [sw addTarget:self action:@selector(wczzGroupSwitch:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
    } else if (ip.section == 1) {
        if (ip.row == 0) {
            cell.textLabel.text = @"群助手头像";
            cell.detailTextLabel.text = [[NSUserDefaults standardUserDefaults] objectForKey:WCZZGroupAvatarKey] ?: @"QQ邮箱头像";
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            cell.textLabel.text = @"常用群列表";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"已选 %lu 个群", (unsigned long)WCZZCommonRooms().count];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    } else {
        NSMutableArray *all = [NSMutableArray array];
        for (id session in WCZZSessionList()) if (WCZZIsGroupUsername(WCZZUsername(session))) [all addObject:session];
        if (ip.row < (NSInteger)MIN(20, all.count)) {
            id session = all[(NSUInteger)ip.row];
            cell.textLabel.text = WCZZDisplayName(WCZZContact(session));
            NSString *u = WCZZUsername(session);
            UISwitch *sw = [UISwitch new];
            sw.on = u.length && !WCZZIsCommonRoom(u);
            sw.enabled = WCZZIsChatRoom(WCZZContact(session), u);
            sw.tag = 1000 + ip.row;
            [sw addTarget:self action:@selector(wczzGroupItemSwitch:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        }
    }
    return cell;
}
- (void)wczzGroupSwitch:(UISwitch *)sw {
    if (sw.tag == 500) WCZZSetBool(WCZZGroupEnabledKey, sw.on);
    else WCZZSetBool(WCZZGroupTopKey, sw.on);
    WCZZReloadMainList();
}
- (void)wczzGroupItemSwitch:(UISwitch *)sw {
    NSInteger idx = sw.tag - 1000;
    NSMutableArray *allGroups = [NSMutableArray array];
    for (id candidate in WCZZSessionList()) {
        if (WCZZIsGroupUsername(WCZZUsername(candidate))) [allGroups addObject:candidate];
    }
    if (idx < 0 || idx >= (NSInteger)allGroups.count) return;
    id session = allGroups[(NSUInteger)idx];
    NSString *u = WCZZUsername(session);
    if (!u.length || !WCZZIsChatRoom(WCZZContact(session), u)) return;
    NSMutableArray *rooms = [WCZZCommonRooms() mutableCopy];
    // The item switch means "keep this group in the normal chat list".
    if (sw.on) [rooms removeObject:u];
    else if (![rooms containsObject:u]) [rooms addObject:u];
    WCZZSetCommonRooms(rooms);
    [self.tableView reloadData];
    WCZZReloadMainList();
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section != 1) return;
    if (ip.row == 0) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"群助手头像" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
        for (NSString *name in @[@"QQ邮箱头像", @"微信头像", @"默认头像"]) {
            [a addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                [[NSUserDefaults standardUserDefaults] setObject:name forKey:WCZZGroupAvatarKey];
                [[NSUserDefaults standardUserDefaults] synchronize];
                [self.tableView reloadData];
            }]];
        }
        [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    } else {
        [self.navigationController pushViewController:[WCZZCommonRoomsViewController new] animated:YES];
    }
}
@end

@interface WCZZSettingsViewController : UITableViewController @end
@implementation WCZZSettingsViewController
- (instancetype)init:(id)__unused model { return [super initWithStyle:UITableViewStyleGrouped]; }
- (void)viewDidLoad { [super viewDidLoad]; self.title = @"wczz"; self.tableView.tableFooterView = [UIView new]; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section { return section == 0 ? 3 : 0; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *ID = @"wczz.setting";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:ID];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:ID];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    if (ip.row == 0) {
        cell.textLabel.text = @"启用 wczz";
        UISwitch *sw = [UISwitch new];
        sw.on = WCZZEnabled(); sw.tag = 99;
        [sw addTarget:self action:@selector(wczzMainSwitch:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
    } else if (ip.row == 1) {
        cell.textLabel.text = @"群助手";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        cell.textLabel.text = @"红包详情";
        UISwitch *sw = [UISwitch new];
        sw.on = WCZZBool(WCZZRedDetailKey, YES); sw.tag = 100;
        [sw addTarget:self action:@selector(wczzMainSwitch:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
    }
    return cell;
}
- (void)wczzMainSwitch:(UISwitch *)sw {
    if (sw.tag == 99) WCZZSetBool(WCZZPluginEnabledKey, sw.on);
    else WCZZSetBool(WCZZRedDetailKey, sw.on);
    WCZZReloadMainList();
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.row == 1) [self.navigationController pushViewController:[WCZZGroupSettingsViewController new] animated:YES];
}
@end

#pragma mark - Main list integration (v27 direct UITableView engine)

#pragma mark - v27 main list engine
//
// v27 deliberately does NOT hook MainFrameLogicController's data-source methods.
// The table view controller is the actual UITableViewDataSource/Delegate surface
// exposed by WeChat 8.0.75. We filter rows at that boundary and map visible rows
// back to WeChat's original rows.
//
// Rules:
// 1. Only usernames ending in @chatroom can ever be folded.
// 2. "Common groups" stay in the normal list.
// 3. Friends and every non-@chatroom session are never counted as groups.
// 4. The helper row is a real UITableViewCell, not FakeMainFrameCellData.
// 5. No guessed fake-cell row indexes.

static const void *WCZZRowsKey = &WCZZRowsKey;
static const void *WCZZOriginalCountKey = &WCZZOriginalCountKey;

static void WCZZClearRows(id vc) {
    objc_setAssociatedObject(vc, WCZZRowsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(vc, WCZZOriginalCountKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static NSArray *WCZZVisibleOriginalRows(id vc, long long originalCount) {
    if (!vc || originalCount <= 0) return @[];

    SEL logicSessionSel = NSSelectorFromString(@"logicGetSessionAtIndexPath:");
    if (![vc respondsToSelector:logicSessionSel]) return nil;

    NSMutableArray *rows = [NSMutableArray arrayWithCapacity:(NSUInteger)originalCount];
    for (long long r = 0; r < originalCount; r++) {
        NSIndexPath *ip = [NSIndexPath indexPathForRow:(NSInteger)r inSection:0];
        id session = nil;
        @try {
            session = ((id (*)(id, SEL, id))objc_msgSend)(vc, logicSessionSel, ip);
        } @catch (__unused NSException *e) {
            session = nil;
        }

        // A nil session is left untouched. We do not guess its type.
        // This prevents unrelated special/fake rows from being mistaken for groups.
        if (session && WCZZShouldFold(session)) continue;
        [rows addObject:@(r)];
    }
    return rows;
}

static NSArray *WCZZGetCachedRows(id vc) {
    id rows = objc_getAssociatedObject(vc, WCZZRowsKey);
    return [rows isKindOfClass:[NSArray class]] ? rows : nil;
}

static long long WCZZCachedOriginalCount(id vc) {
    NSNumber *n = objc_getAssociatedObject(vc, WCZZOriginalCountKey);
    return n ? n.longLongValue : -1;
}

static NSArray *WCZZRebuildRows(id vc, long long originalCount) {
    if (!WCZZEnabled() || !WCZZBool(WCZZGroupEnabledKey, YES)) {
        WCZZClearRows(vc);
        return nil;
    }

    NSArray *rows = WCZZVisibleOriginalRows(vc, originalCount);
    if (!rows) {
        WCZZClearRows(vc);
        return nil;
    }

    objc_setAssociatedObject(vc, WCZZRowsKey, rows, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(vc, WCZZOriginalCountKey, @(originalCount), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return rows;
}

static NSArray *WCZZEnsureRows(id vc) {
    NSArray *rows = WCZZGetCachedRows(vc);
    long long cachedCount = WCZZCachedOriginalCount(vc);
    if (rows && cachedCount >= 0) return rows;

    SEL countSel = NSSelectorFromString(@"logicGetCountForSection:");
    if (![vc respondsToSelector:countSel]) return nil;

    long long count = -1;
    @try {
        count = ((long long (*)(id, SEL, long long))objc_msgSend)(vc, countSel, 0);
    } @catch (__unused NSException *e) {
        count = -1;
    }
    if (count < 0) return nil;
    return WCZZRebuildRows(vc, count);
}

static BOOL WCZZHasHiddenGroups(id vc) {
    NSArray *rows = WCZZGetCachedRows(vc);
    long long original = WCZZCachedOriginalCount(vc);
    return rows && original >= 0 && (long long)rows.count < original;
}

static NSInteger WCZZHelperRow(id vc) {
    NSArray *rows = WCZZGetCachedRows(vc);
    if (!rows || !WCZZHasHiddenGroups(vc)) return NSNotFound;
    return WCZZBool(WCZZGroupTopKey, YES) ? 0 : (NSInteger)rows.count;
}

static NSIndexPath *WCZZOriginalIndexPathForVisible(id vc, NSIndexPath *visibleIP) {
    if (!visibleIP || visibleIP.section != 0) return nil;

    NSArray *rows = WCZZEnsureRows(vc);
    if (!rows) return nil;

    if (WCZZHasHiddenGroups(vc)) {
        BOOL top = WCZZBool(WCZZGroupTopKey, YES);
        NSInteger helper = top ? 0 : (NSInteger)rows.count;
        if (visibleIP.row == helper) return nil;

        NSInteger visible = visibleIP.row;
        if (top) visible -= 1;
        if (visible < 0 || visible >= (NSInteger)rows.count) return nil;

        NSInteger original = [rows[visible] integerValue];
        return [NSIndexPath indexPathForRow:original inSection:visibleIP.section];
    }

    if (visibleIP.row < 0 || visibleIP.row >= (NSInteger)rows.count) return nil;
    NSInteger original = [rows[visibleIP.row] integerValue];
    return [NSIndexPath indexPathForRow:original inSection:visibleIP.section];
}

static UITableViewCell *WCZZBuildHelperCell(UITableView *tableView) {
    static NSString *identifier = @"wczz.v27.helper";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:identifier];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }

    NSInteger groupCount = 0;
    NSInteger unread = 0;
    NSString *latest = nil;

    for (id session in WCZZSessionList()) {
        if (!WCZZShouldFold(session)) continue;
        groupCount++;

        unsigned long count = [WCZZValue(session, @"m_uUnReadCount") unsignedLongValue];
        unread += (NSInteger)MIN(count, (unsigned long)NSIntegerMax);

        if (!latest) {
            id last = WCZZValue(session, @"m_nsLastMsg");
            if ([last isKindOfClass:[NSString class]] && [(NSString *)last length] > 0) {
                latest = last;
            }
        }
    }

    cell.textLabel.text = @"群助手";
    cell.detailTextLabel.text = latest.length
        ? [NSString stringWithFormat:@"%ld 个群 · %ld 条未读 · %@", (long)groupCount, (long)unread, latest]
        : [NSString stringWithFormat:@"%ld 个群 · %ld 条未读", (long)groupCount, (long)unread];

    if (@available(iOS 13.0, *)) {
        UIImage *image = [UIImage systemImageNamed:@"envelope.fill"];
        cell.imageView.image = image;
        cell.imageView.tintColor = [UIColor systemBlueColor];
    } else {
        cell.imageView.image = nil;
    }

    cell.textLabel.textColor = [UIColor labelColor];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    return cell;
}

static void WCZZOpenHelper(id vc) {
    UINavigationController *nav = nil;
    if ([vc isKindOfClass:[UIViewController class]]) {
        nav = [(UIViewController *)vc navigationController];
    }
    if (!nav) return;

    WCZZGroupHelperViewController *helper = [WCZZGroupHelperViewController new];
    helper.mainController = vc;
    [nav pushViewController:helper animated:YES];
}

%hook NewMainFrameViewController

- (long long)tableView:(id)tableView numberOfRowsInSection:(long long)section {
    long long original = %orig(tableView, section);

    if (section != 0 || !WCZZEnabled() || !WCZZBool(WCZZGroupEnabledKey, YES)) {
        if (section == 0) WCZZClearRows(self);
        return original;
    }

    NSArray *rows = WCZZRebuildRows(self, original);
    if (!rows) return original;

    if ((long long)rows.count == original) return original;
    return (long long)rows.count + 1;
}

- (id)tableView:(id)tableView cellForRowAtIndexPath:(id)indexPath {
    NSIndexPath *ip = [indexPath isKindOfClass:[NSIndexPath class]] ? indexPath : nil;

    if (ip && ip.section == 0 && WCZZEnabled() && WCZZBool(WCZZGroupEnabledKey, YES)) {
        NSArray *rows = WCZZEnsureRows(self);
        if (rows && WCZZHasHiddenGroups(self)) {
            NSInteger helper = WCZZHelperRow(self);
            if (ip.row == helper) {
                return WCZZBuildHelperCell((UITableView *)tableView);
            }

            NSIndexPath *originalIP = WCZZOriginalIndexPathForVisible(self, ip);
            if (originalIP) return %orig(tableView, originalIP);
        }
    }

    return %orig(tableView, indexPath);
}

- (double)tableView:(id)tableView heightForRowAtIndexPath:(id)indexPath {
    NSIndexPath *ip = [indexPath isKindOfClass:[NSIndexPath class]] ? indexPath : nil;
    if (ip && ip.section == 0 && WCZZEnabled() && WCZZBool(WCZZGroupEnabledKey, YES)) {
        NSArray *rows = WCZZEnsureRows(self);
        if (rows && WCZZHasHiddenGroups(self)) {
            if (ip.row == WCZZHelperRow(self)) return 60.0;

            NSIndexPath *originalIP = WCZZOriginalIndexPathForVisible(self, ip);
            if (originalIP) return %orig(tableView, originalIP);
        }
    }
    return %orig(tableView, indexPath);
}

- (void)tableView:(id)tableView didSelectRowAtIndexPath:(id)indexPath {
    NSIndexPath *ip = [indexPath isKindOfClass:[NSIndexPath class]] ? indexPath : nil;

    if (ip && ip.section == 0 && WCZZEnabled() && WCZZBool(WCZZGroupEnabledKey, YES)) {
        NSArray *rows = WCZZEnsureRows(self);
        if (rows && WCZZHasHiddenGroups(self)) {
            NSInteger helper = WCZZHelperRow(self);
            if (ip.row == helper) {
                [(UITableView *)tableView deselectRowAtIndexPath:ip animated:YES];
                WCZZOpenHelper(self);
                return;
            }

            NSIndexPath *originalIP = WCZZOriginalIndexPathForVisible(self, ip);
            if (originalIP) {
                return %orig(tableView, originalIP);
            }
        }
    }

    %orig(tableView, indexPath);
}

- (void)onSessionRebuildEnd {
    WCZZClearRows(self);
    %orig;
}

- (void)reloadSessions {
    WCZZClearRows(self);
    %orig;
}

%end

#pragma mark - Red envelope detail

static const void *WCZZRedDataKey = &WCZZRedDataKey;

static void WCZZApplyRedDetailFromData(id vc, id data) {
    if (!WCZZEnabled() || !WCZZBool(WCZZRedDetailKey, YES) || !vc || !data) return;

    id info = WCZZValue(data, @"m_oWCRedEnvelopesDetailInfo");
    id labelObj = WCZZValue(vc, @"m_receivedInfoLable");
    if (!info || ![labelObj isKindOfClass:[UILabel class]]) return;

    long long totalAmount = MAX(0LL, [WCZZValue(info, @"m_lTotalAmount") longLongValue]);
    long long totalNum = MAX(0LL, [WCZZValue(info, @"m_lTotalNum") longLongValue]);
    long long recNum = MAX(0LL, [WCZZValue(info, @"m_lRecNum") longLongValue]);
    long long recAmount = MAX(0LL, [WCZZValue(info, @"m_lRecAmount") longLongValue]);

    long long remainNum = MAX(0LL, totalNum - recNum);
    long long remainAmount = MAX(0LL, totalAmount - recAmount);

    UILabel *label = (UILabel *)labelObj;
    label.text = [NSString stringWithFormat:
                  @"总金额 %.2f 元    共 %lld 个\n已领取 %lld 个 / %.2f 元    剩余 %lld 个 / %.2f 元",
                  totalAmount / 100.0,
                  totalNum,
                  recNum,
                  recAmount / 100.0,
                  remainNum,
                  remainAmount / 100.0];
    label.numberOfLines = 2;
    label.textAlignment = NSTextAlignmentCenter;
}

%hook WCRedEnvelopesRedEnvelopesDetailViewController

- (void)refreshViewWithData:(id)data {
    %orig(data);

    if (!WCZZEnabled() || !WCZZBool(WCZZRedDetailKey, YES)) return;
    objc_setAssociatedObject(self, WCZZRedDataKey, data, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    dispatch_async(dispatch_get_main_queue(), ^{
        WCZZApplyRedDetailFromData(self, data);
    });
}

- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);

    if (!WCZZEnabled() || !WCZZBool(WCZZRedDetailKey, YES)) return;
    id data = objc_getAssociatedObject(self, WCZZRedDataKey);
    if (data) {
        dispatch_async(dispatch_get_main_queue(), ^{
            WCZZApplyRedDetailFromData(self, data);
        });
    }
}

%end

#pragma mark - Plugin manager

static BOOL WCZZRegistered = NO;

static void WCZZRegisterPlugin(void) {
    if (WCZZRegistered) return;

    Class mgrClass = objc_getClass("WCPluginsMgr");
    SEL sharedSel = NSSelectorFromString(@"sharedInstance");
    SEL registerSel = NSSelectorFromString(@"registerControllerWithTitle:version:controller:");

    if (!mgrClass || ![mgrClass respondsToSelector:sharedSel]) return;

    id mgr = ((id (*)(id, SEL))objc_msgSend)(mgrClass, sharedSel);
    if (!mgr || ![mgr respondsToSelector:registerSel]) return;

    ((void (*)(id, SEL, id, id, id))objc_msgSend)(
        mgr,
        registerSel,
        @"wczz",
        @"1.0-3",
        @"WCZZSettingsViewController"
    );

    WCZZRegistered = YES;
    NSLog(@"[wczz] plugin manager registration succeeded");
}

static void WCZZRetryRegisterPlugin(void) {
    if (WCZZRegistered) return;

    WCZZRegisterPlugin();
    if (WCZZRegistered) return;

    static NSInteger attempts = 0;
    attempts++;
    if (attempts >= 30) {
        NSLog(@"[wczz] plugin manager not found after retries");
        return;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        WCZZRetryRegisterPlugin();
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
        [d synchronize];

        NSLog(@"[wczz] v27 constructor loaded");

        Class mainVC = objc_getClass("NewMainFrameViewController");
        Class redVC = objc_getClass("WCRedEnvelopesRedEnvelopesDetailViewController");
        NSLog(@"[wczz] classes: main=%p red=%p", mainVC, redVC);

        %init;

        dispatch_async(dispatch_get_main_queue(), ^{
            WCZZRetryRegisterPlugin();
        });
    }
}
