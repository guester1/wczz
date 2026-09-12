#import "WeChatCompat.h"
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

// wczz 1.0-2
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
    NSArray *all = WCZZSessionList();
    if (idx < 0 || idx >= (NSInteger)all.count) return;
    id session = all[(NSUInteger)idx];
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

#pragma mark - Main list integration
//
// WeChat 8.0.75 already has a first-class "fake main-frame cell" path:
// MainFrameLogicController exposes getFakeCellCount/getFakeCellData and the
// binary contains FakeMainFrameCell/FakeMainFrameCellData.
//
// The previous implementation inserted a fake row into
// getSessionCountForSection:. That is the wrong layer: the table treats fake
// cells separately, so returning FakeMainFrameCellData from
// getCellDataAtIndexPath: can result in no cell, wrong mapping, or no tap.
//
// v25 uses the native fake-cell path and only filters the real session array.
// Every session is hard-filtered by *@chatroom before it can be folded.

static const void *WCZZRowsCacheKey = &WCZZRowsCacheKey;
static const void *WCZZOriginalCountCacheKey = &WCZZOriginalCountCacheKey;
static const void *WCZZFoldedRowsCacheKey = &WCZZFoldedRowsCacheKey;
static const void *WCZZReentryKey = &WCZZReentryKey;

static NSArray *WCZZLogicRows(id self) {
    return objc_getAssociatedObject(self, WCZZRowsCacheKey);
}
static void WCZZSetLogicRows(id self, NSArray *rows) {
    objc_setAssociatedObject(self, WCZZRowsCacheKey, rows ?: @[], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static long long WCZZLogicOriginalCount(id self) {
    NSNumber *n = objc_getAssociatedObject(self, WCZZOriginalCountCacheKey);
    return [n isKindOfClass:[NSNumber class]] ? n.longLongValue : -1;
}
static void WCZZSetLogicOriginalCount(id self, long long n) {
    objc_setAssociatedObject(self, WCZZOriginalCountCacheKey, @(n), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static NSArray *WCZZLogicFoldedRows(id self) {
    return objc_getAssociatedObject(self, WCZZFoldedRowsCacheKey);
}
static void WCZZSetLogicFoldedRows(id self, NSArray *rows) {
    objc_setAssociatedObject(self, WCZZFoldedRowsCacheKey, rows ?: @[], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static BOOL WCZZLogicReentry(id self) {
    return [objc_getAssociatedObject(self, WCZZReentryKey) boolValue];
}
static void WCZZSetLogicReentry(id self, BOOL on) {
    objc_setAssociatedObject(self, WCZZReentryKey, @(on), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static NSArray *WCZZBuildLogicRows(id self, long long originalCount, NSMutableArray **foldedOut) {
    if (originalCount <= 0) {
        if (foldedOut) *foldedOut = [NSMutableArray array];
        return @[];
    }

    NSMutableArray *visible = [NSMutableArray arrayWithCapacity:(NSUInteger)originalCount];
    NSMutableArray *folded = [NSMutableArray array];

    WCZZSetLogicReentry(self, YES);
    for (NSInteger i = 0; i < originalCount; i++) {
        NSIndexPath *ip = [NSIndexPath indexPathForRow:i inSection:0];
        id session = nil;
        @try {
            session = [(MainFrameLogicController *)self getSessionInfoAtIndexPath:ip];
        } @catch (__unused NSException *e) {
            session = nil;
        }

        // ABSOLUTE GROUP-ONLY GATE:
        // If the username is not *@chatroom, it can NEVER be folded.
        if (WCZZShouldFold(session)) {
            [folded addObject:@(i)];
        } else {
            [visible addObject:@(i)];
        }
    }
    WCZZSetLogicReentry(self, NO);

    if (foldedOut) *foldedOut = folded;
    return visible;
}

static void WCZZPrepareLogicRows(id self, long long originalCount) {
    if (originalCount < 0) {
        WCZZSetLogicRows(self, nil);
        WCZZSetLogicFoldedRows(self, nil);
        WCZZSetLogicOriginalCount(self, -1);
        return;
    }

    if (!WCZZEnabled() || !WCZZBool(WCZZGroupEnabledKey, YES) || originalCount == 0) {
        WCZZSetLogicRows(self, nil);
        WCZZSetLogicFoldedRows(self, nil);
        WCZZSetLogicOriginalCount(self, originalCount);
        return;
    }

    NSMutableArray *folded = nil;
    NSArray *visible = WCZZBuildLogicRows(self, originalCount, &folded);
    WCZZSetLogicRows(self, visible);
    WCZZSetLogicFoldedRows(self, folded ?: @[]);
    WCZZSetLogicOriginalCount(self, originalCount);
}

static BOOL WCZZEnsureLogicRows(id self) {
    long long original = WCZZLogicOriginalCount(self);
    if (original >= 0 && [WCZZLogicRows(self) isKindOfClass:[NSArray class]]) return YES;

    WCZZSetLogicReentry(self, YES);
    @try {
        original = [(MainFrameLogicController *)self getSessionCountForSection:0];
    } @catch (__unused NSException *e) {
        original = -1;
    }
    WCZZSetLogicReentry(self, NO);

    if (original < 0) return NO;
    WCZZPrepareLogicRows(self, original);
    return YES;
}

static NSIndexPath *WCZZOriginalIPForVisibleIP(id self, NSIndexPath *ip) {
    if (!ip || ip.section != 0) return nil;
    NSArray *rows = WCZZLogicRows(self);
    if (![rows isKindOfClass:[NSArray class]]) return nil;
    if (ip.row < 0 || ip.row >= (NSInteger)rows.count) return nil;

    NSInteger originalRow = [rows[(NSUInteger)ip.row] integerValue];
    return [NSIndexPath indexPathForRow:originalRow inSection:ip.section];
}

static BOOL WCZZHasFoldedGroups(id self) {
    NSArray *folded = WCZZLogicFoldedRows(self);
    return WCZZEnabled() &&
           WCZZBool(WCZZGroupEnabledKey, YES) &&
           [folded isKindOfClass:[NSArray class]] &&
           folded.count > 0;
}

static FakeMainFrameCellData *WCZZBuildFakeCellData(id self) {
    FakeMainFrameCellData *data = [FakeMainFrameCellData new];

    NSArray *foldedRows = WCZZLogicFoldedRows(self);
    NSUInteger groupCount = foldedRows.count;

    unsigned long long unreadTotal = 0;
    NSString *latestMessage = nil;
    NSString *latestTime = nil;

    // Build a compact preview from folded GROUP sessions only.
    // This never reads or counts a friend session.
    for (NSNumber *n in foldedRows) {
        NSInteger row = n.integerValue;
        NSIndexPath *ip = [NSIndexPath indexPathForRow:row inSection:0];

        id session = nil;
        id cellData = nil;
        WCZZSetLogicReentry(self, YES);
        @try { session = [(MainFrameLogicController *)self getSessionInfoAtIndexPath:ip]; } @catch (__unused NSException *e) {}
        @try { cellData = [(MainFrameLogicController *)self getCellDataAtIndexPath:ip]; } @catch (__unused NSException *e) {}
        WCZZSetLogicReentry(self, NO);

        NSString *username = WCZZUsername(session);
        if (!WCZZIsGroupUsername(username)) continue;

        unreadTotal += (unsigned long long)[WCZZValue(session, @"m_uUnReadCount") unsignedIntValue];

        id msg = WCZZValue(cellData, @"m_textForMessageLabel");
        if (!msg) msg = WCZZValue(cellData, @"textForMessageLabel");
        if ([msg isKindOfClass:[NSString class]] && [(NSString *)msg length] > 0) latestMessage = msg;

        id time = WCZZValue(cellData, @"m_textForTimeLabel");
        if (!time) time = WCZZValue(cellData, @"textForTimeLabel");
        if ([time isKindOfClass:[NSString class]] && [(NSString *)time length] > 0) latestTime = time;
    }

    NSString *message = [NSString stringWithFormat:@"%lu 个群", (unsigned long)groupCount];
    if (unreadTotal > 0) {
        message = [NSString stringWithFormat:@"%@ · %llu 条未读", message, unreadTotal];
    }
    if (latestMessage.length > 0) {
        message = [NSString stringWithFormat:@"%@ · %@", message, latestMessage];
    }

    data.userName = WCZZGroupUserName;
    data.textForNameLabel = @"群助手";
    data.textForMessageLabel = message;
    data.textForTimeLabel = latestTime ?: @"";
    data.widthForNameLabel = 0;
    data.bNormalCell = YES;
    data.bTopCell = WCZZBool(WCZZGroupTopKey, YES);
    return data;
}

static BOOL WCZZIsOurFakeData(id data) {
    return [WCZZValue(data, @"userName") isEqual:WCZZGroupUserName];
}

%group WCZZMainLogicHooks
%hook MainFrameLogicController

- (long long)getSessionCountForSection:(long long)section {
    long long original = %orig(section);

    if (WCZZLogicReentry(self)) return original;
    if (section != 0 || !WCZZEnabled() || !WCZZBool(WCZZGroupEnabledKey, YES)) {
        if (section == 0) {
            WCZZSetLogicRows(self, nil);
            WCZZSetLogicFoldedRows(self, nil);
            WCZZSetLogicOriginalCount(self, original);
        }
        return original;
    }

    WCZZPrepareLogicRows(self, original);
    NSArray *visible = WCZZLogicRows(self);
    if (![visible isKindOfClass:[NSArray class]]) return original;

    // IMPORTANT: only remove sessions that passed WCZZShouldFold(),
    // which itself requires *@chatroom.
    return (long long)visible.count;
}

- (id)getSessionInfoAtIndexPath:(id)indexPath {
    if (WCZZLogicReentry(self)) return %orig(indexPath);

    NSIndexPath *ip = [indexPath isKindOfClass:[NSIndexPath class]] ? (NSIndexPath *)indexPath : nil;
    if (!ip || ip.section != 0 || !WCZZEnabled() || !WCZZBool(WCZZGroupEnabledKey, YES)) {
        return %orig(indexPath);
    }

    WCZZEnsureLogicRows(self);
    NSIndexPath *origIP = WCZZOriginalIPForVisibleIP(self, ip);
    if (origIP) {
        return %orig(origIP);
    }
    return %orig(indexPath);
}

- (id)getCellDataAtIndexPath:(id)indexPath {
    if (WCZZLogicReentry(self)) return %orig(indexPath);

    NSIndexPath *ip = [indexPath isKindOfClass:[NSIndexPath class]] ? (NSIndexPath *)indexPath : nil;
    if (!ip || ip.section != 0 || !WCZZEnabled() || !WCZZBool(WCZZGroupEnabledKey, YES)) {
        return %orig(indexPath);
    }

    WCZZEnsureLogicRows(self);
    NSIndexPath *origIP = WCZZOriginalIPForVisibleIP(self, ip);
    if (origIP) {
        return %orig(origIP);
    }
    return %orig(indexPath);
}

- (long long)getFakeCellCount {
    long long original = %orig;
    if (WCZZLogicReentry(self)) return original;
    if (!WCZZEnabled() || !WCZZBool(WCZZGroupEnabledKey, YES)) return original;

    WCZZEnsureLogicRows(self);

    // Do not interfere with WeChat's own fake cells. We only add our row
    // when the native fake-cell list is empty.
    return original == 0 && WCZZHasFoldedGroups(self) ? 1 : original;
}

- (id)getFakeCellData:(unsigned int)index {
    if (WCZZLogicReentry(self)) return %orig(index);
    if (!WCZZEnabled() || !WCZZBool(WCZZGroupEnabledKey, YES)) return %orig(index);

    WCZZEnsureLogicRows(self);

    WCZZSetLogicReentry(self, YES);
    long long originalFakeCount = 0;
    @try { originalFakeCount = [(MainFrameLogicController *)self getFakeCellCount]; }
    @catch (__unused NSException *e) { originalFakeCount = 0; }
    WCZZSetLogicReentry(self, NO);

    if (originalFakeCount == 0 && index == 0 && WCZZHasFoldedGroups(self)) {
        return WCZZBuildFakeCellData(self);
    }
    return %orig(index);
}

- (void)onDidSelectCellAt:(id)indexPath {
    if (WCZZLogicReentry(self)) {
        %orig(indexPath);
        return;
    }

    NSIndexPath *ip = [indexPath isKindOfClass:[NSIndexPath class]] ? (NSIndexPath *)indexPath : nil;
    if (ip && ip.section == 0 && WCZZHasFoldedGroups(self)) {
        BOOL top = WCZZBool(WCZZGroupTopKey, YES);
        NSArray *visible = WCZZLogicRows(self);

        // FakeMainFrameCell is represented separately by the main-frame data
        // source. For the zero-native-fake-cell case, its row is top or bottom.
        long long fakeRow = top ? 0 : (long long)visible.count;
        if (ip.row == fakeRow) {
            id delegate = WCZZValue(self, @"m_delegate");
            UIViewController *base = [delegate isKindOfClass:[UIViewController class]] ? (UIViewController *)delegate : nil;
            if (!base) base = WCZZFindMainController();

            UINavigationController *nav = base.navigationController;
            if (!nav && [base isKindOfClass:[UINavigationController class]]) {
                nav = (UINavigationController *)base;
            }
            if (nav) {
                WCZZGroupHelperViewController *vc = [WCZZGroupHelperViewController new];
                vc.mainController = base;
                [nav pushViewController:vc animated:YES];
            }
            return;
        }
    }

    %orig(indexPath);
}

- (void)onSessionRebuildEnd {
    WCZZSetLogicRows(self, nil);
    WCZZSetLogicFoldedRows(self, nil);
    WCZZSetLogicOriginalCount(self, -1);
    %orig;
}

%end
%end

%group WCZZMainVCSelectionHooks
%hook NewMainFrameViewController

- (void)handleSelectIndexPath:(id)indexPath tableView:(id)tableView {
    NSIndexPath *ip = [indexPath isKindOfClass:[NSIndexPath class]] ? (NSIndexPath *)indexPath : nil;
    if (ip && ip.section == 0 && WCZZEnabled() && WCZZBool(WCZZGroupEnabledKey, YES)) {
        id logic = WCZZValue(self, @"m_mainFrameLogicController");
        Class logicClass = objc_getClass("MainFrameLogicController");
        if (logic && logicClass && [logic isKindOfClass:logicClass]) {
            WCZZEnsureLogicRows(logic);
            if (WCZZHasFoldedGroups(logic)) {
                BOOL top = WCZZBool(WCZZGroupTopKey, YES);
                NSArray *visible = WCZZLogicRows(logic);
                NSInteger helperRow = top ? 0 : (NSInteger)visible.count;
                if (ip.row == helperRow) {
                    UINavigationController *nav = self.navigationController;
                    if (nav) {
                        WCZZGroupHelperViewController *vc = [WCZZGroupHelperViewController new];
                        vc.mainController = self;
                        [nav pushViewController:vc animated:YES];
                    }
                    return;
                }
            }
        }
    }
    %orig(indexPath, tableView);
}

%end
%end

#pragma mark - Red detail

static const void *WCZZRedDataKey = &WCZZRedDataKey;

static void WCZZApplyRedDetailFromData(id vc, id data) {
    if (!WCZZEnabled() || !WCZZBool(WCZZRedDetailKey, YES) || !vc || !data) return;
    id info = WCZZValue(data, @"m_oWCRedEnvelopesDetailInfo");
    id labelObj = WCZZValue(vc, @"m_receivedInfoLable");
    if (!info || ![labelObj isKindOfClass:[UILabel class]]) return;
    long long totalAmount = [WCZZValue(info, @"m_lTotalAmount") longLongValue];
    long long totalNum = [WCZZValue(info, @"m_lTotalNum") longLongValue];
    long long recNum = [WCZZValue(info, @"m_lRecNum") longLongValue];
    long long recAmount = [WCZZValue(info, @"m_lRecAmount") longLongValue];
    if (totalAmount < 0) totalAmount = 0;
    if (totalNum < 0) totalNum = 0;
    if (recNum < 0) recNum = 0;
    if (recAmount < 0) recAmount = 0;
    long long remainNum = MAX(0LL, totalNum - recNum);
    long long remainAmount = MAX(0LL, totalAmount - recAmount);
    ((UILabel *)labelObj).text = [NSString stringWithFormat:@"总金额:%.2f元\n总个数:%lld个\n剩余:%lld个\n剩余:%.2f元", totalAmount / 100.0, totalNum, remainNum, remainAmount / 100.0];
    ((UILabel *)labelObj).numberOfLines = 4;
    ((UILabel *)labelObj).textAlignment = NSTextAlignmentCenter;
}

%group WCZZRedHooks
%hook WCRedEnvelopesRedEnvelopesDetailViewController
- (void)refreshViewWithData:(id)data {
    %orig(data);
    if (!WCZZEnabled() || !WCZZBool(WCZZRedDetailKey, YES)) return;
    objc_setAssociatedObject(self, WCZZRedDataKey, data, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_async(dispatch_get_main_queue(), ^{
        WCZZApplyRedDetailFromData(self, data);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            WCZZApplyRedDetailFromData(self, data);
        });
    });
}
- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    if (!WCZZEnabled() || !WCZZBool(WCZZRedDetailKey, YES)) return;
    id data = objc_getAssociatedObject(self, WCZZRedDataKey);
    if (data) {
        dispatch_async(dispatch_get_main_queue(), ^{ WCZZApplyRedDetailFromData(self, data); });
    }
}
%end
%end

#pragma mark - Plugin manager

static BOOL WCZZRegistered = NO;
static void WCZZRegisterPlugin(void) {
    if (WCZZRegistered) return;

    Class c = objc_getClass("WCPluginsMgr");
    SEL shared = NSSelectorFromString(@"sharedInstance");
    SEL reg = NSSelectorFromString(@"registerControllerWithTitle:version:controller:");
    if (!c || ![c respondsToSelector:shared]) return;

    id mgr = ((id (*)(id, SEL))objc_msgSend)(c, shared);
    if (!mgr || ![mgr respondsToSelector:reg]) return;

    ((void (*)(id, SEL, id, id, id))objc_msgSend)(
        mgr, reg, @"wczz", @"1.0-2", @"WCZZSettingsViewController"
    );
    WCZZRegistered = YES;
}

%ctor {
    @autoreleasepool {
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        if ([d objectForKey:WCZZPluginEnabledKey] == nil) [d setBool:YES forKey:WCZZPluginEnabledKey];
        if ([d objectForKey:WCZZGroupEnabledKey] == nil) [d setBool:YES forKey:WCZZGroupEnabledKey];
        if ([d objectForKey:WCZZGroupTopKey] == nil) [d setBool:YES forKey:WCZZGroupTopKey];
        if ([d objectForKey:WCZZRedDetailKey] == nil) [d setBool:YES forKey:WCZZRedDetailKey];
        if ([d objectForKey:WCZZCommonRoomsKey] == nil) [d setObject:@[] forKey:WCZZCommonRoomsKey];
        [d synchronize];

        // 8.0.75 headers confirm these classes exist. Initialize Logos
        // groups directly from the constructor instead of waiting 0.5s and
        // hoping the class appears later.
        %init(WCZZMainLogicHooks);
        %init(WCZZMainVCSelectionHooks);
        %init(WCZZRedHooks);
        NSLog(@"[wczz] 8.0.75 hooks installed");

        // Plugin-manager registration can safely happen after the app UI is
        // alive. The tweak hooks themselves are already active above.
        dispatch_async(dispatch_get_main_queue(), ^{
            WCZZRegisterPlugin();
        });
    }
}
