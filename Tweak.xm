#import "WeChatCompat.h"
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <stdarg.h>
#import <objc/message.h>
#import <objc/runtime.h>

// wczz 1.0-8
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
    [[NSUserDefaults standardUserDefaults] synchronize];
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
    [[NSUserDefaults standardUserDefaults] synchronize];
}
static NSArray *WCZZDebugLogs(void) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:WCZZDebugLogsKey];
    return [v isKindOfClass:[NSArray class]] ? v : @[];
}
static void WCZZClearDebugLogs(void) {
    [[NSUserDefaults standardUserDefaults] setObject:@[] forKey:WCZZDebugLogsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
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
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        NSMutableArray *logs = ([[d objectForKey:WCZZDebugLogsKey] isKindOfClass:[NSArray class]] ? [[d objectForKey:WCZZDebugLogsKey] mutableCopy] : [NSMutableArray array]);
        [logs addObject:line];
        if (logs.count > 500) [logs removeObjectsInRange:NSMakeRange(0, logs.count - 500)];
        [d setObject:logs forKey:WCZZDebugLogsKey];
        [d synchronize];
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
    if (mgr && [mgr respondsToSelector:clear]) {
        @try { ((void (*)(id, SEL, id, unsigned int))objc_msgSend)(mgr, clear, username, 0U); } @catch (__unused NSException *e) {}
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
@property(nonatomic, weak) UIViewController *mainController;
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

@implementation WCZZGroupHelperViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"群消息";
    self.tableView.tableFooterView = [UIView new];
    self.tableView.separatorInset = UIEdgeInsetsMake(0, 78, 0, 0);
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    NSMutableArray *groups = [NSMutableArray array];
    for (id s in WCZZSessionList()) if (WCZZShouldFold(s)) [groups addObject:s];
    self.sessions = groups;
    [self.tableView reloadData];
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
        [self viewWillAppear:NO];
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
            UISwitch *sw = [UISwitch new]; sw.tag = 1000 + ip.row; sw.on = !WCZZIsCommonRoom(u); [sw addTarget:self action:@selector(wczzItem:) forControlEvents:UIControlEventValueChanged]; c.accessoryView = sw;
        }
    }
    return c;
}
- (void)wczzSwitch:(UISwitch *)sw { if (sw.tag == 500) WCZZSetBool(WCZZGroupEnabledKey, sw.on); else WCZZSetBool(WCZZGroupTopKey, sw.on); WCZZInvalidateMainLogicCache(); dispatch_async(dispatch_get_main_queue(), ^{ id main = WCZZFindMainController(); id table = WCZZValue(main, @"m_tableView"); if ([table respondsToSelector:@selector(reloadData)]) [(UITableView *)table reloadData]; }); }
- (void)wczzItem:(UISwitch *)sw {
    NSInteger idx = sw.tag - 1000; NSMutableArray *all = [NSMutableArray array]; for (id s in WCZZSessionList()) if (WCZZIsGroupUsername(WCZZUsername(s))) [all addObject:s];
    if (idx < 0 || idx >= (NSInteger)all.count) return; NSString *u = WCZZUsername(all[(NSUInteger)idx]); if (!WCZZIsGroupUsername(u)) return;
    NSMutableArray *rooms = [WCZZCommonRooms() mutableCopy]; if (sw.on) [rooms removeObject:u]; else if (![rooms containsObject:u]) [rooms addObject:u]; WCZZSetCommonRooms(rooms);
    [self.tableView reloadData]; WCZZInvalidateMainLogicCache(); dispatch_async(dispatch_get_main_queue(), ^{ id main = WCZZFindMainController(); id table = WCZZValue(main, @"m_tableView"); if ([table respondsToSelector:@selector(reloadData)]) [(UITableView *)table reloadData]; });
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip { [tv deselectRowAtIndexPath:ip animated:YES]; if (ip.section != 1) return; if (ip.row == 0) { UIAlertController *a = [UIAlertController alertControllerWithTitle:@"群助手头像" message:nil preferredStyle:UIAlertControllerStyleActionSheet]; for (NSString *n in @[@"默认头像", @"微信头像", @"QQ邮箱头像"]) [a addAction:[UIAlertAction actionWithTitle:n style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *x){ [[NSUserDefaults standardUserDefaults] setObject:n forKey:WCZZGroupAvatarKey]; [[NSUserDefaults standardUserDefaults] synchronize]; [self.tableView reloadData]; }]]; [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]]; [self presentViewController:a animated:YES completion:nil]; } else [self.navigationController pushViewController:[WCZZCommonRoomsViewController new] animated:YES]; }
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

static const void *WCZZVCRowsKey = &WCZZVCRowsKey;
static const void *WCZZVCFoldedKey = &WCZZVCFoldedKey;
static const void *WCZZVCOriginalCountKey = &WCZZVCOriginalCountKey;
static const void *WCZZVCReentryKey = &WCZZVCReentryKey;

static BOOL WCZZVCReentry(id vc) {
    return [objc_getAssociatedObject(vc, WCZZVCReentryKey) boolValue];
}
static void WCZZSetVCReentry(id vc, BOOL on) {
    objc_setAssociatedObject(vc, WCZZVCReentryKey, @(on), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static NSArray *WCZZVCRows(id vc) { return objc_getAssociatedObject(vc, WCZZVCRowsKey); }
static NSArray *WCZZVCFolded(id vc) { return objc_getAssociatedObject(vc, WCZZVCFoldedKey); }
static long long WCZZVCOriginalCount(id vc) { return [objc_getAssociatedObject(vc, WCZZVCOriginalCountKey) longLongValue]; }
static void WCZZClearVCRows(id vc) {
    objc_setAssociatedObject(vc, WCZZVCRowsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(vc, WCZZVCFoldedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(vc, WCZZVCOriginalCountKey, @(-1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static id WCZZMainLogicForVC(id vc) { return WCZZValue(vc, @"m_mainFrameLogicController"); }

static BOOL WCZZIsMainTable(id vc, id table) {
    id mainTable = WCZZValue(vc, @"m_tableView");
    return mainTable && table == mainTable;
}

static NSArray *WCZZBuildVCRows(id vc, long long originalCount) {
    if (originalCount <= 0) return @[];
    id logic = WCZZMainLogicForVC(vc);
    if (!logic) {
        WCZZLog(@"row scan failed: main logic nil");
        return @[];
    }
    SEL infoSel = NSSelectorFromString(@"getSessionInfoAtIndexPath:");
    if (![logic respondsToSelector:infoSel]) {
        WCZZLog(@"row scan failed: logic has no getSessionInfoAtIndexPath:");
        return @[];
    }
    NSMutableArray *visible = [NSMutableArray arrayWithCapacity:(NSUInteger)originalCount];
    NSMutableArray *folded = [NSMutableArray array];
    for (NSInteger i = 0; i < originalCount; i++) {
        NSIndexPath *ip = [NSIndexPath indexPathForRow:i inSection:0];
        id session = nil;
        @try {
            session = ((id (*)(id, SEL, id))objc_msgSend)(logic, infoSel, ip);
        } @catch (__unused NSException *e) {}
        NSString *u = WCZZUsername(session);
        BOOL fold = WCZZShouldFold(session);
        if (fold) [folded addObject:@(i)];
        else [visible addObject:@(i)];
        if (WCZZDebugEnabled() && i < 80) {
            WCZZLog(@"row scan %ld user=%@ group=%@ common=%@ fold=%@",
                    (long)i, u ?: @"<nil>",
                    WCZZIsGroupUsername(u) ? @"YES" : @"NO",
                    WCZZIsCommonRoom(u) ? @"YES" : @"NO",
                    fold ? @"YES" : @"NO");
        }
    }
    objc_setAssociatedObject(vc, WCZZVCRowsKey, visible, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(vc, WCZZVCFoldedKey, folded, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(vc, WCZZVCOriginalCountKey, @(originalCount), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    WCZZLog(@"table rows rebuilt original=%lld visible=%lu folded=%lu",
            originalCount, (unsigned long)visible.count, (unsigned long)folded.count);
    return visible;
}

static NSArray *WCZZEnsureVCRows(id vc, long long originalCount) {
    if (!WCZZEnabled() || !WCZZBool(WCZZGroupEnabledKey, YES) || originalCount <= 0) {
        WCZZClearVCRows(vc);
        return nil;
    }
    NSArray *rows = WCZZVCRows(vc);
    if (![rows isKindOfClass:[NSArray class]] || WCZZVCOriginalCount(vc) != originalCount) {
        rows = WCZZBuildVCRows(vc, originalCount);
    }
    return rows;
}

static NSIndexPath *WCZZOriginalIPForVCRow(id vc, NSIndexPath *visibleIP) {
    NSArray *rows = WCZZVCRows(vc);
    if (![rows isKindOfClass:[NSArray class]] || visibleIP.section != 0) return nil;
    BOOL top = WCZZBool(WCZZGroupTopKey, YES);
    NSInteger helperRow = top ? 0 : (NSInteger)rows.count;
    if (visibleIP.row == helperRow) return nil;
    NSInteger visibleIndex = top ? visibleIP.row - 1 : visibleIP.row;
    if (visibleIndex < 0 || visibleIndex >= (NSInteger)rows.count) return nil;
    NSInteger originalRow = [rows[(NSUInteger)visibleIndex] integerValue];
    return [NSIndexPath indexPathForRow:originalRow inSection:0];
}

static UITableViewCell *WCZZBuildAssistantCell(UITableView *tv, id vc) {
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"wczz.assistant.cell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:@"wczz.assistant.cell"];
    }
    cell.textLabel.text = @"群助手";
    NSArray *folded = WCZZVCFolded(vc);
    NSUInteger count = [folded isKindOfClass:[NSArray class]] ? folded.count : 0;
    unsigned long long unread = 0;
    NSString *latest = nil;
    NSString *latestTime = nil;
    id logic = WCZZMainLogicForVC(vc);
    SEL dataSel = NSSelectorFromString(@"getCellDataAtIndexPath:");
    for (NSNumber *n in folded) {
        NSIndexPath *ip = [NSIndexPath indexPathForRow:n.integerValue inSection:0];
        id data = nil;
        if (logic && [logic respondsToSelector:dataSel]) {
            @try {
                data = ((id (*)(id, SEL, id))objc_msgSend)(logic, dataSel, ip);
            } @catch (__unused NSException *e) {}
        }
        unread += [WCZZValue(data, @"m_uUnReadCount") unsignedIntValue];
        id msg = WCZZValue(data, @"textForMessageLabel");
        if (!msg) msg = WCZZValue(data, @"textForMsgLabel");
        id tm = WCZZValue(data, @"textForTimeLabel");
        if ([msg isKindOfClass:[NSString class]] && [(NSString *)msg length]) latest = msg;
        if ([tm isKindOfClass:[NSString class]] && [(NSString *)tm length]) latestTime = tm;
    }
    NSString *detail = latest.length
        ? [NSString stringWithFormat:@"%@  ·  %lu个群", latest, (unsigned long)count]
        : [NSString stringWithFormat:@"%lu个群", (unsigned long)count];
    if (latestTime.length) detail = [NSString stringWithFormat:@"%@  ·  %@", latestTime, detail];
    if (unread > 0) detail = [NSString stringWithFormat:@"[%llu条] %@", unread, detail];
    cell.detailTextLabel.text = detail;
    cell.accessoryType = UITableViewCellAccessoryNone;
    return cell;
}

static void WCZZReloadMainList(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *main = WCZZFindMainController();
        if (!main) return;
        WCZZClearVCRows(main);
        id table = WCZZValue(main, @"m_tableView");
        if ([table respondsToSelector:@selector(reloadData)]) {
            [(UITableView *)table reloadData];
        }
        WCZZLog(@"main list reload requested");
    });
}

%group WCZZMainVCHooks
%hook NewMainFrameViewController

- (long long)tableView:(id)tableView numberOfRowsInSection:(long long)section {
    long long original = %orig(tableView, section);
    if (WCZZVCReentry(self) || section != 0 || !WCZZIsMainTable(self, tableView) ||
        !WCZZEnabled() || !WCZZBool(WCZZGroupEnabledKey, YES)) {
        return original;
    }
    NSArray *rows = WCZZEnsureVCRows(self, original);
    if (![rows isKindOfClass:[NSArray class]]) return original;
    NSArray *folded = WCZZVCFolded(self);
    if (folded.count == 0) return original;
    long long result = (long long)rows.count + 1;
    WCZZLog(@"table numberOfRows original=%lld result=%lld folded=%lu top=%@",
            original, result, (unsigned long)folded.count,
            WCZZBool(WCZZGroupTopKey, YES) ? @"YES" : @"NO");
    return result;
}

- (id)tableView:(id)tableView cellForRowAtIndexPath:(id)indexPath {
    if (WCZZVCReentry(self)) return %orig(tableView, indexPath);
    NSIndexPath *ip = [indexPath isKindOfClass:[NSIndexPath class]] ? (NSIndexPath *)indexPath : nil;
    if (!ip || ip.section != 0 || !WCZZIsMainTable(self, tableView) ||
        !WCZZEnabled() || !WCZZBool(WCZZGroupEnabledKey, YES)) {
        return %orig(tableView, indexPath);
    }

    long long original = WCZZVCOriginalCount(self);
    NSArray *rows = WCZZVCRows(self);
    if (![rows isKindOfClass:[NSArray class]] || original <= 0) {
        id logic = WCZZMainLogicForVC(self);
        SEL countSel = NSSelectorFromString(@"getVisibleSessionCount");
        if (logic && [logic respondsToSelector:countSel]) {
            @try {
                original = ((long long (*)(id, SEL))objc_msgSend)(logic, countSel);
            } @catch (__unused NSException *e) {}
        }
        rows = WCZZEnsureVCRows(self, original);
    }
    if (![rows isKindOfClass:[NSArray class]]) return %orig(tableView, indexPath);

    NSArray *folded = WCZZVCFolded(self);
    if (folded.count == 0) return %orig(tableView, indexPath);

    BOOL top = WCZZBool(WCZZGroupTopKey, YES);
    NSInteger helperRow = top ? 0 : (NSInteger)rows.count;
    if (ip.row == helperRow) {
        return WCZZBuildAssistantCell((UITableView *)tableView, self);
    }

    NSIndexPath *origIP = WCZZOriginalIPForVCRow(self, ip);
    if (origIP) {
        WCZZSetVCReentry(self, YES);
        id cell = %orig(tableView, origIP);
        WCZZSetVCReentry(self, NO);
        return cell;
    }
    return %orig(tableView, indexPath);
}

- (void)tableView:(id)tableView didSelectRowAtIndexPath:(id)indexPath {
    if (WCZZVCReentry(self)) {
        %orig(tableView, indexPath);
        return;
    }
    NSIndexPath *ip = [indexPath isKindOfClass:[NSIndexPath class]] ? (NSIndexPath *)indexPath : nil;
    NSArray *rows = WCZZVCRows(self);
    NSArray *folded = WCZZVCFolded(self);
    if (ip && ip.section == 0 && WCZZIsMainTable(self, tableView) &&
        [rows isKindOfClass:[NSArray class]] && [folded isKindOfClass:[NSArray class]] &&
        folded.count > 0 && WCZZEnabled() && WCZZBool(WCZZGroupEnabledKey, YES)) {
        BOOL top = WCZZBool(WCZZGroupTopKey, YES);
        NSInteger helperRow = top ? 0 : (NSInteger)rows.count;
        if (ip.row == helperRow) {
            UINavigationController *nav = self.navigationController;
            if (nav) {
                WCZZGroupHelperViewController *helper = [WCZZGroupHelperViewController new];
                helper.mainController = self;
                [nav pushViewController:helper animated:YES];
                WCZZLog(@"helper selected folded=%lu", (unsigned long)folded.count);
            }
            return;
        }
        NSIndexPath *origIP = WCZZOriginalIPForVCRow(self, ip);
        if (origIP) {
            WCZZSetVCReentry(self, YES);
            %orig(tableView, origIP);
            WCZZSetVCReentry(self, NO);
            return;
        }
    }
    %orig(tableView, indexPath);
}

- (id)indexPathOfSessionUserName:(id)username {
    id result = %orig(username);
    if (!WCZZEnabled() || !WCZZBool(WCZZGroupEnabledKey, YES)) return result;
    if (!WCZZIsGroupUsername(username) || WCZZIsCommonRoom(username)) return result;
    return nil;
}

- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    WCZZLog(@"main VC appeared");
    if (WCZZEnabled() && WCZZBool(WCZZGroupEnabledKey, YES)) WCZZReloadMainList();
}

- (void)onSessionRebuildEnd {
    WCZZClearVCRows(self);
    %orig;
    if (WCZZEnabled() && WCZZBool(WCZZGroupEnabledKey, YES)) WCZZReloadMainList();
}
%end
%end

#pragma mark - Main VC navigation
%group WCZZMainOpenSessionHook
%hook NewMainFrameViewController
- (void)onLogicOpenSession:(id)session {
    NSString *u = WCZZUsername(session);
    if ([u isEqualToString:WCZZGroupUserName]) return;
    %orig(session);
}
%end
%end

#pragma mark - Red envelope

static const void *WCZZRedDataKey = &WCZZRedDataKey;
static id WCZZLatestRedData = nil;
static UILabel *WCZZRedLabel(id vc) {
    id label = WCZZValue(vc, @"m_receivedInfoLable");
    if ([label isKindOfClass:[UILabel class]]) return label;
    Ivar iv = class_getInstanceVariable([vc class], "_m_receivedInfoLable");
    if (iv) { id v = object_getIvar(vc, iv); if ([v isKindOfClass:[UILabel class]]) return v; }
    iv = class_getInstanceVariable([vc class], "m_receivedInfoLable");
    if (iv) { id v = object_getIvar(vc, iv); if ([v isKindOfClass:[UILabel class]]) return v; }
    return nil;
}
static UILabel *WCZZFindRedLabelInView(UIView *view) {
    if (!view) return nil;
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:[UILabel class]]) {
            UILabel *l=(UILabel *)sub; NSString *t=l.text ?: @"";
            if ([t containsString:@"领取"] || [t containsString:@"红包"] || [t containsString:@"个"]) return l;
        }
        UILabel *nested=WCZZFindRedLabelInView(sub); if (nested) return nested;
    }
    return nil;
}
static void WCZZScheduleRedApply(id vc, id data) {
    if (!vc) return;
    for (int i=0;i<8;i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.15*i*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            UILabel *label=WCZZRedLabel(vc);
            if (!label && [vc isViewLoaded]) label=WCZZFindRedLabelInView([(UIViewController *)vc view]);
            if (label && data) {
                objc_setAssociatedObject(vc, WCZZRedDataKey, data, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                id info=WCZZValue(data,@"m_oWCRedEnvelopesDetailInfo");
                if (info) {
                    long long totalAmount=MAX(0LL,[WCZZValue(info,@"m_lTotalAmount") longLongValue]);
                    long long totalNum=MAX(0LL,[WCZZValue(info,@"m_lTotalNum") longLongValue]);
                    long long recAmount=MAX(0LL,[WCZZValue(info,@"m_lRecAmount") longLongValue]);
                    long long recNum=MAX(0LL,[WCZZValue(info,@"m_lRecNum") longLongValue]);
                    long long remainAmount=MAX(0LL,totalAmount-recAmount);
                    long long remainNum=MAX(0LL,totalNum-recNum);
                    label.text=[NSString stringWithFormat:@"总金额 %.2f 元    共 %lld 个\n已领取 %lld 个 / %.2f 元    剩余 %lld 个 / %.2f 元",totalAmount/100.0,totalNum,recNum,recAmount/100.0,remainNum,remainAmount/100.0];
                    label.numberOfLines=2; label.textAlignment=NSTextAlignmentCenter;
                    WCZZLog(@"red detail applied total=%lld/%lld received=%lld/%lld label=%p",totalAmount,totalNum,recAmount,recNum,label);
                }
            }
        });
    }
}

static void WCZZApplyRedDetailFromData(id vc, id data) {
    if (!WCZZEnabled() || !WCZZBool(WCZZRedDetailKey, YES) || !vc || !data) return;
    id info = WCZZValue(data, @"m_oWCRedEnvelopesDetailInfo");
    id labelObj = WCZZRedLabel(vc);
    if (!info || ![labelObj isKindOfClass:[UILabel class]]) { WCZZLog(@"red apply missing info=%p label=%p", info, labelObj); return; }
    long long totalAmount = MAX(0LL, [WCZZValue(info, @"m_lTotalAmount") longLongValue]);
    long long totalNum = MAX(0LL, [WCZZValue(info, @"m_lTotalNum") longLongValue]);
    long long recAmount = MAX(0LL, [WCZZValue(info, @"m_lRecAmount") longLongValue]);
    long long recNum = MAX(0LL, [WCZZValue(info, @"m_lRecNum") longLongValue]);
    long long remainAmount = MAX(0LL, totalAmount - recAmount);
    long long remainNum = MAX(0LL, totalNum - recNum);
    UILabel *label = (UILabel *)labelObj;
    label.text = [NSString stringWithFormat:@"总金额 %.2f 元    共 %lld 个\n已领取 %lld 个 / %.2f 元    剩余 %lld 个 / %.2f 元", totalAmount / 100.0, totalNum, recNum, recAmount / 100.0, remainNum, remainAmount / 100.0];
    label.numberOfLines = 2;
    label.textAlignment = NSTextAlignmentCenter;
    WCZZLog(@"red detail applied total=%lld/%lld received=%lld/%lld", totalAmount, totalNum, recAmount, recNum);
    WCZZScheduleRedApply(vc, data);
}

%group WCZZRedHooks
%hook WCRedEnvelopesControlLogic
- (void)showDetailView {
    %orig;
    WCZZLog(@"red base showDetailView self=%p data=%p", self, WCZZValue(self,@"m_data"));
    id data=WCZZValue(self,@"m_data");
    if (data) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.15*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ WCZZLog(@"red base detail search data=%p",data); }); }
}
- (id)initWithData:(id)data {
    id obj = %orig(data);
    if (obj && data) objc_setAssociatedObject(obj, WCZZRedDataKey, data, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    WCZZLatestRedData = data; WCZZLog(@"red control init data=%p", data);
    return obj;
}
%end

%hook WCRedEnvelopesReceiveControlLogic
- (id)initWithData:(id)data Scene:(int)scene {
    id obj=%orig(data,scene);
    WCZZLatestRedData = data; WCZZLog(@"red receive init scene=%d data=%p obj=%p",scene,data,obj);
    return obj;
}
- (id)initWithData:(id)data {
    id obj=%orig(data);
    WCZZLatestRedData = data; WCZZLog(@"red receive init data=%p obj=%p",data,obj);
    return obj;
}
- (void)showDetailView {
    %orig;
    WCZZLog(@"red receive showDetailView");
    id data = WCZZValue(self, @"m_data");
    if (!data) data = objc_getAssociatedObject(self, WCZZRedDataKey);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIViewController *main = WCZZFindMainController();
        (void)main;
        // Find the detail VC from all visible controller trees.
        Class detail = objc_getClass("WCRedEnvelopesRedEnvelopesDetailViewController");
        if (!detail) return;
        UIApplication *app = UIApplication.sharedApplication;
        for (UIScene *scene in app.connectedScenes) {
            if (scene.activationState == UISceneActivationStateUnattached || ![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                UIViewController *root = w.rootViewController;
                NSMutableArray *stack = root ? [NSMutableArray arrayWithObject:root] : [NSMutableArray array];
                while (stack.count) {
                    UIViewController *vc = stack.lastObject; [stack removeLastObject];
                    if ([vc isKindOfClass:detail]) {
                        id d = data ?: WCZZValue(self, @"m_data");
                        if (d) { objc_setAssociatedObject(vc, WCZZRedDataKey, d, OBJC_ASSOCIATION_RETAIN_NONATOMIC); WCZZApplyRedDetailFromData(vc, d); WCZZScheduleRedApply(vc, d); }
                        return;
                    }
                    if (vc.presentedViewController) [stack addObject:vc.presentedViewController];
                    if (vc.navigationController) [stack addObject:vc.navigationController];
                    for (UIViewController *child in vc.childViewControllers) [stack addObject:child];
                }
            }
        }
    });
}
%end

%hook WCRedEnvelopesRedEnvelopesDetailViewController
- (id)init {
    id obj = %orig;
    WCZZLog(@"red detail init vc=%p", obj);
    return obj;
}
- (void)viewDidLoad {
    %orig;
    id d = objc_getAssociatedObject(self, WCZZRedDataKey);
    if (!d) d = WCZZLatestRedData;
    if (d) objc_setAssociatedObject(self, WCZZRedDataKey, d, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    WCZZLog(@"red detail viewDidLoad label=%p data=%p", WCZZRedLabel(self), d);
    if (d) WCZZScheduleRedApply(self, d);
}
- (void)refreshViewWithData:(id)data {
    %orig(data);
    WCZZLog(@"red refreshViewWithData data=%p", data);
    if (data) {
        objc_setAssociatedObject(self, WCZZRedDataKey, data, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        dispatch_async(dispatch_get_main_queue(), ^{
            WCZZApplyRedDetailFromData(self, data); WCZZScheduleRedApply(self, data);
        });
    }
}
- (void)viewWillAppear:(BOOL)animated {
    %orig(animated);
    id data = objc_getAssociatedObject(self, WCZZRedDataKey);
    if (!data) data = WCZZLatestRedData;
    if (data) objc_setAssociatedObject(self, WCZZRedDataKey, data, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    WCZZLog(@"red detail viewWillAppear data=%p label=%p", data, WCZZRedLabel(self));
    if (data) WCZZScheduleRedApply(self, data);
}
- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    id data = objc_getAssociatedObject(self, WCZZRedDataKey);
    if (!data) data = WCZZLatestRedData;
    if (data) objc_setAssociatedObject(self, WCZZRedDataKey, data, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    WCZZLog(@"red detail viewDidAppear data=%p label=%p", data, WCZZRedLabel(self));
    if (data) {
        dispatch_async(dispatch_get_main_queue(), ^{
            WCZZApplyRedDetailFromData(self, data);
            WCZZScheduleRedApply(self, data);
        });
    }
}
%end
%end

#pragma mark - Plugin registration / delayed hook installation

static BOOL WCZZRegistered = NO;
static BOOL WCZZMainVCHooksStarted = NO;
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
    ((void (*)(id, SEL, id, id, id))objc_msgSend)(mgr, reg, @"wczz", @"1.0-18", @"WCZZSettingsViewController");
    WCZZRegistered = YES;
    WCZZLog(@"plugin registration OK");
}

static void WCZZInstallHooksWhenReady(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!WCZZMainVCHooksStarted && objc_getClass("NewMainFrameViewController")) { %init(WCZZMainVCHooks); %init(WCZZMainOpenSessionHook); WCZZMainVCHooksStarted = YES; WCZZLog(@"main VC hooks installed"); WCZZReloadMainList(); }
        if (!WCZZRedHooksStarted && objc_getClass("WCRedEnvelopesControlLogic") && objc_getClass("WCRedEnvelopesReceiveControlLogic") && objc_getClass("WCRedEnvelopesRedEnvelopesDetailViewController")) { %init(WCZZRedHooks); WCZZRedHooksStarted = YES; WCZZLog(@"red hooks installed"); }
        WCZZRegisterPlugin();
        if ((!WCZZMainVCHooksStarted || !WCZZRedHooksStarted || !WCZZRegistered) && WCZZInstallAttempts++ < 60) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.75 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ WCZZInstallHooksWhenReady(); });
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
        [d synchronize];
        WCZZLog(@"v1.0-18 constructor");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ WCZZInstallHooksWhenReady(); });
    }
}
