#import "WeChatCompat.h"
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <stdarg.h>
#import <objc/message.h>
#import <objc/runtime.h>

// wczz 1.0-4
// Independent implementation. Runtime dependency: WeChat only.

static NSString * const WCZZPluginEnabledKey = @"wczz.plugin.enabled";
static NSString * const WCZZGroupEnabledKey  = @"wczz.group.enabled";
static NSString * const WCZZGroupTopKey      = @"wczz.group.top";
static NSString * const WCZZCommonRoomsKey   = @"wczz.group.commonRooms";
static NSString * const WCZZRedDetailKey     = @"wczz.redDetail.enabled";
static NSString * const WCZZGroupUserName    = @"wczz_group_helper";
static NSString * const WCZZGroupAvatarKey   = @"wczz.group.avatar";
static NSString * const WCZZDebugEnabledKey = @"wczz.debug.enabled";
static NSString * const WCZZDebugLogsKey = @"wczz.debug.logs";

static BOOL WCZZBool(NSString *key, BOOL fallback);

static BOOL WCZZDebugEnabled(void) {
    return WCZZBool(WCZZDebugEnabledKey, NO);
}

static void WCZZLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSLog(@"[wczz] %@", msg);
    if (!WCZZDebugEnabled()) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        NSArray *old = [d objectForKey:WCZZDebugLogsKey];
        NSMutableArray *logs = old ? [old mutableCopy] : [NSMutableArray array];
        NSDateFormatter *df = [NSDateFormatter new];
        df.dateFormat = @"HH:mm:ss.SSS";
        NSString *line = [NSString stringWithFormat:@"[%@] %@", [df stringFromDate:[NSDate date]], msg ?: @""];
        [logs addObject:line];
        if (logs.count > 500) {
            [logs removeObjectsInRange:NSMakeRange(0, logs.count - 500)];
        }
        [d setObject:logs forKey:WCZZDebugLogsKey];
        [d synchronize];
    });
}

static NSArray *WCZZDebugLogs(void) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:WCZZDebugLogsKey];
    return [v isKindOfClass:[NSArray class]] ? v : @[];
}
static void WCZZClearDebugLogs(void) {
    [[NSUserDefaults standardUserDefaults] setObject:@[] forKey:WCZZDebugLogsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}


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
static id WCZZSessionManager(void) {
    Class ctxClass = objc_getClass("MMContext");
    Class mgrClass = objc_getClass("MMNewSessionMgr");
    SEL currentSel = NSSelectorFromString(@"currentContext");
    SEL serviceSel = NSSelectorFromString(@"getService:");
    if (!ctxClass || !mgrClass || ![ctxClass respondsToSelector:currentSel]) return nil;

    id ctx = ((id (*)(id, SEL))objc_msgSend)(ctxClass, currentSel);
    id center = WCZZValue(ctx, @"serviceCenter");
    if (!center || ![center respondsToSelector:serviceSel]) return nil;
    return ((id (*)(id, SEL, Class))objc_msgSend)(center, serviceSel, mgrClass);
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
static void WCZZScheduleNativeFolding(void);

static void WCZZReloadMainList(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = WCZZFindMainController();
        if (!vc) return;
        id tv = WCZZValue(vc, @"m_tableView");
        if ([tv isKindOfClass:[UITableView class]]) {
            [(UITableView *)tv reloadData];
        } else {
            SEL reload = NSSelectorFromString(@"reloadSessions");
            if ([vc respondsToSelector:reload]) {
                @try { ((void (*)(id, SEL))objc_msgSend)(vc, reload); } @catch (__unused NSException *e) {}
            }
        }
        WCZZScheduleNativeFolding();
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
@interface WCZZDebugLogViewController : UITableViewController
@end

@implementation WCZZDebugLogViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"调试日志";
    self.tableView.tableFooterView = [UIView new];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"清空" style:UIBarButtonItemStylePlain target:self action:@selector(wczzClear)];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)WCZZDebugLogs().count;
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *ID = @"wczz.debug.log";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:ID];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:ID];
    cell.textLabel.numberOfLines = 0;
    cell.textLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    NSArray *logs = WCZZDebugLogs();
    cell.textLabel.text = ip.row < logs.count ? logs[ip.row] : @"";
    return cell;
}
- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip { return UITableViewAutomaticDimension; }
- (void)wczzClear {
    WCZZClearDebugLogs();
    [self.tableView reloadData];
}
@end


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
- (instancetype)init { return [super initWithStyle:UITableViewStyleGrouped]; }
- (instancetype)init:(id)__unused model { return [self init]; }
- (void)viewDidLoad { [super viewDidLoad]; self.title = @"wczz"; self.tableView.tableFooterView = [UIView new]; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section { return section == 0 ? 5 : 0; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *ID = @"wczz.setting";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:ID];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:ID];
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
    } else if (ip.row == 2) {
        cell.textLabel.text = @"红包详情";
        UISwitch *sw = [UISwitch new];
        sw.on = WCZZBool(WCZZRedDetailKey, YES); sw.tag = 100;
        [sw addTarget:self action:@selector(wczzMainSwitch:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
    } else if (ip.row == 3) {
        cell.textLabel.text = @"启用调试日志";
        UISwitch *sw = [UISwitch new];
        sw.on = WCZZDebugEnabled(); sw.tag = 101;
        [sw addTarget:self action:@selector(wczzMainSwitch:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
    } else {
        cell.textLabel.text = @"查看调试日志";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu 条", (unsigned long)WCZZDebugLogs().count];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}
- (void)wczzMainSwitch:(UISwitch *)sw {
    if (sw.tag == 99) {
        WCZZSetBool(WCZZPluginEnabledKey, sw.on);
    } else if (sw.tag == 100) {
        WCZZSetBool(WCZZRedDetailKey, sw.on);
    } else if (sw.tag == 101) {
        WCZZSetBool(WCZZDebugEnabledKey, sw.on);
        WCZZLog(@"debug logging %@", sw.on ? @"enabled" : @"disabled");
        [self.tableView reloadData];
        return;
    }
    WCZZReloadMainList();
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.row == 1) {
        [self.navigationController pushViewController:[WCZZGroupSettingsViewController new] animated:YES];
    } else if (ip.row == 3) {
        [self.navigationController pushViewController:[WCZZDebugLogViewController new] animated:YES];
    }
}
@end

#pragma mark - Native WeChat session folding
// v28 uses WeChat 8.0.75's own session-folding engine instead of replacing
// UITableView rows. This is the important difference from the previous direct-table implementation: the native
// MainFrameLogicController remains the source of truth for row counts,
// index paths, cells and selection.
//
// Rules are intentionally strict:
// - only usernames ending in @chatroom are eligible;
// - common groups are never folded;
// - every non-chatroom session is explicitly kept unfolded.

static BOOL WCZZApplyingNativeFold = NO;

static NSArray *WCZZFoldableGroupNames(void) {
    if (!WCZZEnabled() || !WCZZBool(WCZZGroupEnabledKey, YES)) { WCZZLog(@"fold list disabled by settings"); return @[]; }

    NSMutableArray *names = [NSMutableArray array];
    for (id session in WCZZSessionList()) {
        NSString *u = WCZZUsername(session);
        if (!WCZZIsGroupUsername(u)) continue;
        if (WCZZIsCommonRoom(u)) continue;
        [names addObject:u];
    }
    WCZZLog(@"fold candidates=%lu common=%lu totalSessions=%lu", (unsigned long)names.count, (unsigned long)WCZZCommonRooms().count, (unsigned long)WCZZSessionList().count);
    return names;
}

static id WCZZMainLogicController(void) {
    UIViewController *vc = WCZZFindMainController();
    if (!vc) return nil;
    return WCZZValue(vc, @"m_mainFrameLogicController");
}

static void WCZZOpenHelper(id vc) {
    if (!vc || ![vc isKindOfClass:[UIViewController class]]) return;
    UINavigationController *nav = [(UIViewController *)vc navigationController];
    if (!nav) return;

    WCZZGroupHelperViewController *helper = [WCZZGroupHelperViewController new];
    helper.mainController = (UIViewController *)vc;
    [nav pushViewController:helper animated:YES];
}

static void WCZZApplyNativeFoldingNow(void) {
    if (WCZZApplyingNativeFold) return;
    WCZZApplyingNativeFold = YES;

    @try {
        id logic = WCZZMainLogicController();
        if (!logic) {
            WCZZApplyingNativeFold = NO;
            return;
        }

        SEL unfoldOneSel = NSSelectorFromString(@"unfoldSessionByName:");
        SEL unfoldAllSel = NSSelectorFromString(@"unfoldAllSessions");
        SEL foldSel = NSSelectorFromString(@"foldSessionUsernames:animate:");
        NSArray *names = WCZZFoldableGroupNames();
        id mgr = WCZZSessionManager();

        if (!WCZZEnabled() || !WCZZBool(WCZZGroupEnabledKey, YES)) {
            if (mgr && [mgr respondsToSelector:unfoldAllSel]) {
                @try { ((void (*)(id, SEL))objc_msgSend)(mgr, unfoldAllSel); } @catch (__unused NSException *e) {}
            } else if ([logic respondsToSelector:unfoldAllSel]) {
                @try { ((void (*)(id, SEL))objc_msgSend)(logic, unfoldAllSel); } @catch (__unused NSException *e) {}
            }
            WCZZLog(@"native fold disabled -> unfolded all");
            return;
        }

        // Explicitly unfold every group that the user marked as common.
        // This makes changing the common-group list take effect immediately.
        if (mgr && [mgr respondsToSelector:unfoldOneSel]) {
            for (id session in WCZZSessionList()) {
                NSString *u = WCZZUsername(session);
                if (WCZZIsGroupUsername(u) && WCZZIsCommonRoom(u)) {
                    @try { ((void (*)(id, SEL, id))objc_msgSend)(mgr, unfoldOneSel, u); } @catch (__unused NSException *e) {}
                }
            }
        }

        if (names.count && [logic respondsToSelector:foldSel]) {
            @try {
                ((void (*)(id, SEL, id, BOOL))objc_msgSend)(logic, foldSel, names, YES);
            } @catch (__unused NSException *e) {
                WCZZLog(@"foldSessionUsernames failed");
            }
        }

        WCZZLog(@"native fold applied: %lu groups", (unsigned long)names.count);
    } @finally {
        WCZZApplyingNativeFold = NO;
    }
}

static void WCZZScheduleNativeFolding(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        WCZZApplyNativeFoldingNow();
    });
}

%hook MMNewSessionMgr

- (BOOL)shouldFoldSession:(id)session {
    BOOL result = NO;
    // Never allow a friend, service account, file assistant, etc. to be
    // classified as one of wczz's groups.  Only @chatroom is eligible.
    if (!WCZZEnabled() || !WCZZBool(WCZZGroupEnabledKey, YES)) return NO;

    NSString *u = WCZZUsername(session);
    if (!WCZZIsGroupUsername(u)) return NO;
    if (WCZZIsCommonRoom(u)) return NO;

    result = YES;
    WCZZLog(@"shouldFoldSession %@ -> YES", u);
    return result;
}

- (void)foldSessionByNames:(id)names {
    WCZZLog(@"foldSessionByNames called: %@", [names isKindOfClass:[NSArray class]] ? [NSString stringWithFormat:@"%lu", (unsigned long)[(NSArray *)names count]] : @"non-array");
    if (!WCZZEnabled() || !WCZZBool(WCZZGroupEnabledKey, YES)) {
        %orig(@[]);
        return;
    }

    NSMutableArray *safe = [NSMutableArray array];
    if ([names isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)names) {
            if ([item isKindOfClass:[NSString class]] && WCZZIsGroupUsername(item) && !WCZZIsCommonRoom(item)) {
                [safe addObject:item];
            }
        }
    }
    %orig(safe);
}

%end

%hook MainFrameLogicController

- (void)onSessionRebuildEnd {
    %orig;
    WCZZLog(@"MainFrameLogicController onSessionRebuildEnd");
    WCZZScheduleNativeFolding();
}

- (id)getFakeCellData:(unsigned int)index {
    id data = %orig(index);
    WCZZLog(@"getFakeCellData index=%u data=%p", index, data);

    if (!data || !WCZZEnabled() || !WCZZBool(WCZZGroupEnabledKey, YES)) return data;

    NSArray *names = WCZZFoldableGroupNames();
    if (!names.count) return data;

    // This is the real WeChat fake-cell object returned by its own folding
    // engine.  We only mutate the returned object; we never instantiate the
    // private class, so there is no linker dependency on FakeMainFrameCellData.
    @try {
        [data setValue:WCZZGroupUserName forKey:@"userName"];
        [data setValue:@"群助手" forKey:@"textForNameLabel"];

        unsigned long long unread = 0;
        NSString *latest = nil;
        for (id session in WCZZSessionList()) {
            NSString *u = WCZZUsername(session);
            if (!WCZZIsGroupUsername(u) || WCZZIsCommonRoom(u)) continue;
            unread += (unsigned long long)[WCZZValue(session, @"m_uUnReadCount") unsignedIntValue];
            if (!latest) {
                id msg = WCZZValue(session, @"m_nsLastMsg");
                if ([msg isKindOfClass:[NSString class]] && [(NSString *)msg length]) latest = msg;
            }
        }

        NSString *summary = [NSString stringWithFormat:@"%lu 个群", (unsigned long)names.count];
        if (unread) summary = [NSString stringWithFormat:@"%@ · %llu 条未读", summary, unread];
        if (latest.length) summary = [NSString stringWithFormat:@"%@ · %@", summary, latest];

        [data setValue:summary forKey:@"textForMessageLabel"];
        [data setValue:@"" forKey:@"textForTimeLabel"];
        [data setValue:@0 forKey:@"widthForNameLabel"];
        [data setValue:@YES forKey:@"bNormalCell"];
        [data setValue:@(WCZZBool(WCZZGroupTopKey, YES)) forKey:@"bTopCell"];
    } @catch (NSException *e) {
        WCZZLog(@"fake cell update exception: %@", e);
    }

    return data;
}

%end

%hook NewMainFrameViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    WCZZLog(@"NewMainFrameViewController viewDidAppear");
    WCZZScheduleNativeFolding();
}

- (void)onSessionRebuildEnd {
    %orig;
    WCZZLog(@"NewMainFrameViewController onSessionRebuildEnd");
    WCZZScheduleNativeFolding();
}

- (void)reloadSessions {
    %orig;
    WCZZLog(@"NewMainFrameViewController reloadSessions");
    WCZZScheduleNativeFolding();
}

- (void)onLogicOpenSession:(id)session {
    NSString *u = WCZZUsername(session);
    WCZZLog(@"onLogicOpenSession username=%@", u ?: @"<nil>");
    if (WCZZEnabled() && WCZZBool(WCZZGroupEnabledKey, YES) && [u isEqualToString:WCZZGroupUserName]) {
        WCZZOpenHelper(self);
        return;
    }
    %orig(session);
}

%end

#pragma mark - Red envelope detail

static const void *WCZZRedDataKey = &WCZZRedDataKey;

static void WCZZApplyRedDetailFromData(id vc, id data) {
    if (!WCZZEnabled() || !WCZZBool(WCZZRedDetailKey, YES) || !vc || !data) return;

    id info = WCZZValue(data, @"m_oWCRedEnvelopesDetailInfo");
    id labelObj = WCZZValue(vc, @"m_receivedInfoLable");
    if (!info || ![labelObj isKindOfClass:[UILabel class]]) { WCZZLog(@"red detail data/info/label missing"); return; }

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
    WCZZLog(@"red detail applied total=%lld/%lld received=%lld/%lld", totalAmount, totalNum, recAmount, recNum);
}

%hook WCRedEnvelopesRedEnvelopesDetailViewController

- (void)refreshViewWithData:(id)data {
    %orig(data);
    WCZZLog(@"red refreshViewWithData data=%p", data);

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
        @"1.0-5",
        @"WCZZSettingsViewController"
    );

    WCZZRegistered = YES;
    WCZZLog(@"plugin manager registration succeeded");
}

static void WCZZRetryRegisterPlugin(void) {
    if (WCZZRegistered) return;

    WCZZRegisterPlugin();
    if (WCZZRegistered) return;

    static NSInteger attempts = 0;
    attempts++;
    if (attempts >= 30) {
        WCZZLog(@"plugin manager not found after retries");
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
        if ([d objectForKey:WCZZDebugEnabledKey] == nil) [d setBool:NO forKey:WCZZDebugEnabledKey];
        if ([d objectForKey:WCZZDebugLogsKey] == nil) [d setObject:@[] forKey:WCZZDebugLogsKey];
        [d synchronize];

        WCZZLog(@"v28.1 constructor loaded; debug=%@", WCZZDebugEnabled() ? @"ON" : @"OFF");

        Class mainVC = objc_getClass("NewMainFrameViewController");
        Class redVC = objc_getClass("WCRedEnvelopesRedEnvelopesDetailViewController");
        WCZZLog(@"classes: main=%p red=%p", mainVC, redVC);

        %init;

        dispatch_async(dispatch_get_main_queue(), ^{
            WCZZRetryRegisterPlugin();
        });
    }
}
