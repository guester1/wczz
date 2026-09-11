#import "WeChatCompat.h"
#import <objc/message.h>
#import <objc/runtime.h>
#include <string.h>

#pragma mark - wczz 1.0-0

static NSString * const WCZZPluginEnabledKey = @"wczz.plugin.enabled";
static NSString * const WCZZGroupEnabledKey = @"wczz.group.enabled";
static NSString * const WCZZGroupTopKey = @"wczz.group.top";
static NSString * const WCZZCommonRoomsKey = @"wczz.group.commonRooms";
static NSString * const WCZZRedDetailKey = @"wczz.redDetail.enabled";
static NSString * const WCZZGroupUserName = @"wczz_group_helper";

static BOOL WCZZBool(NSString *key, BOOL fallback) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    return v ? [v boolValue] : fallback;
}
static BOOL WCZZPluginEnabled(void) { return WCZZBool(WCZZPluginEnabledKey, YES); }
static void WCZZSetBoolProperty(id object, SEL selector, BOOL value) {
    if (!object || ![object respondsToSelector:selector]) return;
    ((void (*)(id, SEL, BOOL))objc_msgSend)(object, selector, value);
}
static void WCZZSetObjectProperty(id object, SEL selector, id value) {
    if (!object || ![object respondsToSelector:selector]) return;
    ((void (*)(id, SEL, id))objc_msgSend)(object, selector, value);
}
static void WCZZSetBool(NSString *key, BOOL value) {
    [[NSUserDefaults standardUserDefaults] setBool:value forKey:key];
    [[NSUserDefaults standardUserDefaults] synchronize];
}
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
    Class c = objc_getClass("CContact");
    SEL s = NSSelectorFromString(@"IsChatRoomContact:");
    if (!c || ![c respondsToSelector:s] || !contact) return NO;
    return ((BOOL (*)(id,SEL,id))objc_msgSend)(c, s, contact);
}
static NSString *WCZZContactDisplayName(id contact) {
    if (!contact) return @"群聊";
    SEL s = NSSelectorFromString(@"getContactDisplayName");
    if ([contact respondsToSelector:s]) {
        id name = ((id (*)(id,SEL))objc_msgSend)(contact, s);
        if ([name isKindOfClass:[NSString class]] && [name length]) return name;
    }
    id n = WCZZValue(contact, @"m_nsNickName");
    return [n isKindOfClass:[NSString class]] && [n length] ? n : @"群聊";
}
static BOOL WCZZIsCommonRoom(NSString *username) {
    return username.length && [WCZZCommonRooms() containsObject:username];
}
static BOOL WCZZShouldFoldSession(id session) {
    if (!WCZZPluginEnabled() || !WCZZBool(WCZZGroupEnabledKey, YES)) return NO;
    id contact = WCZZContact(session);
    NSString *username = WCZZUsername(session);
    return contact && username.length && WCZZIsChatRoomContact(contact) && !WCZZIsCommonRoom(username);
}

static NSArray *WCZZSessionsFromLogic(id logic) {
    id a = WCZZValue(logic, @"m_frontSessionArray");
    if (![a isKindOfClass:[NSArray class]]) a = WCZZValue(logic, @"m_arrFilteredSession");
    return [a isKindOfClass:[NSArray class]] ? a : @[];
}
static NSArray *WCZZFoldedSessionsFromLogic(id logic) {
    NSArray *source = WCZZSessionsFromLogic(logic);
    NSMutableArray *out = [NSMutableArray array];
    for (id s in source) if (WCZZShouldFoldSession(s)) [out addObject:s];
    return out;
}
static NSArray *WCZZFilteredVisibleSessions(id logic) {
    if (!WCZZPluginEnabled()) return @[];
    id a = WCZZValue(logic, @"m_arrFilteredSession");
    if (![a isKindOfClass:[NSArray class]]) a = WCZZValue(logic, @"m_frontSessionArray");
    if (![a isKindOfClass:[NSArray class]]) return @[];
    if (!WCZZBool(WCZZGroupEnabledKey, YES)) return a;
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:[a count]];
    for (id s in a) if (!WCZZShouldFoldSession(s)) [out addObject:s];
    return out;
}


static void WCZZRequestMainListReload(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        Class cls = objc_getClass("NewMainFrameViewController");
        if (!cls) return;
        UIApplication *app = UIApplication.sharedApplication;
        for (UIWindow *window in app.windows) {
            UIViewController *vc = window.rootViewController;
            NSMutableArray *stack = [NSMutableArray array];
            if (vc) [stack addObject:vc];
            while (stack.count) {
                UIViewController *cur = stack.lastObject;
                [stack removeLastObject];
                if ([cur isKindOfClass:cls]) {
                    SEL reload = NSSelectorFromString(@"reloadSessions");
                    if ([cur respondsToSelector:reload]) ((void(*)(id,SEL))objc_msgSend)(cur,reload);
                    return;
                }
                if (cur.presentedViewController) [stack addObject:cur.presentedViewController];
                for (UIViewController *child in cur.childViewControllers) [stack addObject:child];
            }
        }
    });
}

static void WCZZMarkSessionRead(id session) {
    NSString *username = WCZZUsername(session);
    if (!username.length) return;
    Class ctxClass = objc_getClass("MMContext");
    SEL currentSel = NSSelectorFromString(@"currentContext");
    if (!ctxClass || ![ctxClass respondsToSelector:currentSel]) return;
    id ctx = ((id (*)(id, SEL))objc_msgSend)(ctxClass, currentSel);
    id center = WCZZValue(ctx, @"serviceCenter");
    Class mgrClass = objc_getClass("MMNewSessionMgr");
    SEL getService = NSSelectorFromString(@"getService:");
    if (!center || !mgrClass || ![center respondsToSelector:getService]) return;
    id mgr = ((id (*)(id, SEL, Class))objc_msgSend)(center, getService, mgrClass);
    SEL clearSel = NSSelectorFromString(@"ChangeSessionUnReadCount:to:");
    if (mgr && [mgr respondsToSelector:clearSel]) {
        ((void (*)(id, SEL, id, unsigned int))objc_msgSend)(mgr, clearSel, username, 0);
    }
}

static void WCZZMarkAllGroupSessionsRead(id logic) {
    for (id session in WCZZFoldedSessionsFromLogic(logic)) WCZZMarkSessionRead(session);
    WCZZRequestMainListReload();
}

#pragma mark - Group helper page

@interface WCZZGroupHelperViewController : UITableViewController
@property(nonatomic,weak) id mainController;
@property(nonatomic,retain) NSArray *sessions;
@end
@implementation WCZZGroupHelperViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"群消息";
    self.tableView.tableFooterView = [UIView new];
    self.tableView.rowHeight = 60.0;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(wczzMore)];
}
- (void)wczzMore {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:nil message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:@"一键已读" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *x) {
        id logic = WCZZValue(self.mainController, @"m_mainFrameLogicController");
        WCZZMarkAllGroupSessionsRead(logic);
        self.sessions = WCZZFoldedSessionsFromLogic(logic);
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
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; id logic = WCZZValue(self.mainController, @"m_mainFrameLogicController"); self.sessions = WCZZFoldedSessionsFromLogic(logic); [self.tableView reloadData]; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section { return (NSInteger)self.sessions.count; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *ID = @"wczz.group.session";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:ID];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:ID];
    id s = self.sessions[ip.row]; id c = WCZZContact(s); cell.textLabel.text = WCZZContactDisplayName(c);
    NSUInteger unread = [WCZZValue(s, @"m_uUnReadCount") unsignedIntegerValue];
    cell.detailTextLabel.text = unread ? [NSString stringWithFormat:@"%lu 条未读", (unsigned long)unread] : @"";
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; return cell;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES]; id s = self.sessions[ip.row]; SEL sel = NSSelectorFromString(@"onLogicOpenSession:");
    if ([self.mainController respondsToSelector:sel]) ((void(*)(id,SEL,id))objc_msgSend)(self.mainController, sel, s);
}
@end

#pragma mark - Common groups
@interface WCZZCommonRoomsViewController : UITableViewController
@property(nonatomic,weak) id mainController;
@property(nonatomic,retain) NSArray *groups;
@property(nonatomic,retain) NSMutableSet *selected;
@end
@implementation WCZZCommonRoomsViewController
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = @"常用群"; self.tableView.tableFooterView = [UIView new];
    self.selected = [NSMutableSet setWithArray:WCZZCommonRooms()];
    id logic = WCZZValue(self.mainController, @"m_mainFrameLogicController"); NSArray *src = WCZZSessionsFromLogic(logic); NSMutableArray *groups = [NSMutableArray array];
    for (id s in src) if (WCZZIsChatRoomContact(WCZZContact(s)) && WCZZUsername(s).length) [groups addObject:s];
    self.groups = groups;
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section { return (NSInteger)self.groups.count; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *ID = @"wczz.common.room"; UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:ID];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:ID];
    id s = self.groups[ip.row]; NSString *u = WCZZUsername(s); cell.textLabel.text = WCZZContactDisplayName(WCZZContact(s));
    cell.accessoryType = [self.selected containsObject:u] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone; return cell;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    id s = self.groups[ip.row]; NSString *u = WCZZUsername(s); if (!u.length) return;
    if ([self.selected containsObject:u]) [self.selected removeObject:u]; else [self.selected addObject:u];
    WCZZSetCommonRooms(self.selected.allObjects); [tv reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
    WCZZRequestMainListReload();
}
@end

#pragma mark - Settings
@interface WCZZSettingsViewController : UITableViewController @end
@implementation WCZZSettingsViewController
- (instancetype)init:(id)__unused pluginModel { return [super initWithStyle:UITableViewStyleGrouped]; }
- (void)viewDidLoad { [super viewDidLoad]; self.title = @"wczz"; self.tableView.tableFooterView = [UIView new]; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section { return 5; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *ID = @"wczz.setting"; UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:ID];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:ID];
    UISwitch *sw = [UISwitch new]; cell.accessoryView = nil; cell.accessoryType = UITableViewCellAccessoryNone;
    if (ip.row == 0) { cell.textLabel.text = @"启用 wczz"; sw.on = WCZZPluginEnabled(); sw.tag = 99; cell.accessoryView = sw; }
    else if (ip.row == 1) { cell.textLabel.text = @"开启群助手"; sw.on = WCZZBool(WCZZGroupEnabledKey, YES); sw.tag = 100; cell.accessoryView = sw; }
    else if (ip.row == 2) { cell.textLabel.text = @"置顶群助手"; sw.on = WCZZBool(WCZZGroupTopKey, YES); sw.tag = 101; cell.accessoryView = sw; }
    else if (ip.row == 3) { cell.textLabel.text = @"红包详情"; sw.on = WCZZBool(WCZZRedDetailKey, YES); sw.tag = 102; cell.accessoryView = sw; }
    else { cell.textLabel.text = @"常用群"; cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; }
    if (cell.accessoryView == sw) [sw addTarget:self action:@selector(wczzSwitch:) forControlEvents:UIControlEventValueChanged]; return cell;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES]; if (ip.row != 4) return;
    WCZZCommonRoomsViewController *vc = [WCZZCommonRoomsViewController new];
    UIViewController *main = nil;
    for (UIViewController *candidate in self.navigationController.viewControllers) {
        if ([NSStringFromClass(candidate.class) isEqualToString:@"NewMainFrameViewController"]) {
            main = candidate;
            break;
        }
    }
    vc.mainController = main;
    [self.navigationController pushViewController:vc animated:YES];
}
- (void)wczzSwitch:(UISwitch *)sw { if (sw.tag == 99) WCZZSetBool(WCZZPluginEnabledKey, sw.on); else if (sw.tag == 100) WCZZSetBool(WCZZGroupEnabledKey, sw.on); else if (sw.tag == 101) WCZZSetBool(WCZZGroupTopKey, sw.on); else if (sw.tag == 102) WCZZSetBool(WCZZRedDetailKey, sw.on); WCZZRequestMainListReload(); }
@end

#pragma mark - Main list / MiYou fake-cell path

%hook MainFrameLogicController

- (unsigned long long)getFilteredSessionCount {
    if (!WCZZPluginEnabled()) return %orig;
    unsigned long long original = %orig;
    if (!WCZZBool(WCZZGroupEnabledKey, YES)) return original;
    NSArray *a = WCZZValue(self, @"m_arrFilteredSession");
    if (![a isKindOfClass:[NSArray class]]) return original;
    return (unsigned long long)[WCZZFilteredVisibleSessions(self) count];
}

- (id)getFilteredSessionInfo:(unsigned int)index {
    if (WCZZPluginEnabled() && WCZZBool(WCZZGroupEnabledKey, YES)) {
        NSArray *a = WCZZValue(self, @"m_arrFilteredSession");
        if ([a isKindOfClass:[NSArray class]]) {
            NSArray *visible = WCZZFilteredVisibleSessions(self);
            if (index < visible.count) return visible[index];
            return nil;
        }
    }
    return %orig(index);
}

- (long long)getFakeCellCount {
    if (!WCZZPluginEnabled()) return %orig;
    long long original = %orig;
    if (!WCZZBool(WCZZGroupEnabledKey, YES)) return original;
    return WCZZFoldedSessionsFromLogic(self).count ? original + 1 : original;
}

- (id)getFakeCellData:(unsigned int)index {
    id original = %orig(index);
    if (!WCZZPluginEnabled() || !WCZZBool(WCZZGroupEnabledKey, YES)) return original;
    NSArray *groups = WCZZFoldedSessionsFromLogic(self);
    if (!groups.count) return original;
    long long originalCount = [self getFakeCellCount] - 1;
    if ((long long)index < originalCount) return original;
    Class dataClass = objc_getClass("FakeMainFrameCellData");
    if (!dataClass) return original;
    id data = [dataClass new];
    WCZZSetObjectProperty(data, NSSelectorFromString(@"setUserName:"), WCZZGroupUserName);
    WCZZSetObjectProperty(data, NSSelectorFromString(@"setTextForNameLabel:"), @"群消息");
    WCZZSetObjectProperty(data, NSSelectorFromString(@"setTextForMessageLabel:"), [NSString stringWithFormat:@"%lu 个群聊", (unsigned long)groups.count]);
    WCZZSetObjectProperty(data, NSSelectorFromString(@"setTextForTimeLabel:"), @"");
    WCZZSetBoolProperty(data, NSSelectorFromString(@"setBTopCell:"), WCZZBool(WCZZGroupTopKey, YES));
    WCZZSetBoolProperty(data, NSSelectorFromString(@"setBNormalCell:"), YES);
    return data;
}

- (void)onDidSelectCellAt:(id)indexPath {
    if (WCZZPluginEnabled() && WCZZBool(WCZZGroupEnabledKey, YES)) {
        NSArray *groups = WCZZFoldedSessionsFromLogic(self);
        if (groups.count) {
            NSUInteger row = [indexPath respondsToSelector:@selector(row)] ? (NSUInteger)[indexPath row] : NSUIntegerMax;
            NSUInteger fakeRow = (NSUInteger)([self getFakeCellCount] - 1);
            if (row == fakeRow) {
                UIViewController *presenter = nil; id delegate = WCZZValue(self, @"m_delegate");
                if ([delegate isKindOfClass:[UIViewController class]]) presenter = delegate;
                if (!presenter) { UIWindow *w = UIApplication.sharedApplication.keyWindow; UIViewController *r = w.rootViewController; while (r.presentedViewController) r = r.presentedViewController; presenter = r; }
                if (presenter) { WCZZGroupHelperViewController *vc = [WCZZGroupHelperViewController new]; vc.mainController = presenter; [presenter.navigationController pushViewController:vc animated:YES]; }
                return;
            }
        }
    }
    %orig(indexPath);
}

- (void)onSessionRebuildEnd {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:@"wczz.session.changed" object:nil];
    });
}
%end

%hook NewMainFrameViewController
- (void)logicUpdateSession:(id)session {
    %orig(session);
    if (WCZZShouldFoldSession(session)) dispatch_async(dispatch_get_main_queue(), ^{ SEL s = NSSelectorFromString(@"reloadSessions"); if ([self respondsToSelector:s]) ((void(*)(id,SEL))objc_msgSend)(self,s); });
}
%end

#pragma mark - Red detail

static id WCZZDetailInfoFromLogic(id logic) {
    return WCZZValue(logic, @"m_oWCRedEnvelopesDetailInfo");
}

static void WCZZApplyRedDetail(id vc, id info) {
    if (!WCZZBool(WCZZRedDetailKey, YES) || !vc || !info) return;
    long long totalAmount = [WCZZValue(info, @"m_lTotalAmount") longLongValue];
    long long totalNum = [WCZZValue(info, @"m_lTotalNum") longLongValue];
    long long recNum = [WCZZValue(info, @"m_lRecNum") longLongValue];
    long long recAmount = [WCZZValue(info, @"m_lRecAmount") longLongValue];
    if (totalAmount <= 0 && totalNum <= 0 && recNum <= 0 && recAmount <= 0) return;
    NSString *text = [NSString stringWithFormat:@"共 %.2f 元 · %lld 人 · 已领取 %lld 人 / %.2f 元", totalAmount / 100.0, totalNum, recNum, recAmount / 100.0];
    UILabel *label = WCZZValue(vc, @"m_receivedInfoLable");
    if ([label isKindOfClass:[UILabel class]]) label.text = text;
}

static void WCZZShowDetailView(id self, SEL _cmd);
static void WCZZOnQueryRedDetail(id self, SEL _cmd, id data, id error);
static void WCZZCloseRedDetail(id self, SEL _cmd, id data);

static void WCZZInstallRedDetailHooks(void) {
    Class cls = objc_getClass("WCRedEnvelopesReceiveControlLogic");
    if (!cls) return;

    Method m = class_getInstanceMethod(cls, NSSelectorFromString(@"showDetailView"));
    if (m && !class_getInstanceMethod(cls, NSSelectorFromString(@"wczz_orig_showDetailView"))) {
        class_addMethod(cls, NSSelectorFromString(@"wczz_orig_showDetailView"), method_getImplementation(m), method_getTypeEncoding(m));
        class_replaceMethod(cls, NSSelectorFromString(@"showDetailView"), (IMP)WCZZShowDetailView, method_getTypeEncoding(m));
    }

    m = class_getInstanceMethod(cls, NSSelectorFromString(@"OnQueryRedEnvelopesDetailRequest:Error:"));
    if (m && !class_getInstanceMethod(cls, NSSelectorFromString(@"wczz_orig_OnQueryRedEnvelopesDetailRequest:Error:"))) {
        class_addMethod(cls, NSSelectorFromString(@"wczz_orig_OnQueryRedEnvelopesDetailRequest:Error:"), method_getImplementation(m), method_getTypeEncoding(m));
        class_replaceMethod(cls, NSSelectorFromString(@"OnQueryRedEnvelopesDetailRequest:Error:"), (IMP)WCZZOnQueryRedDetail, method_getTypeEncoding(m));
    }

    m = class_getInstanceMethod(cls, NSSelectorFromString(@"closeAnimationWindowAndShowDetailView:"));
    if (m && !class_getInstanceMethod(cls, NSSelectorFromString(@"wczz_orig_closeAnimationWindowAndShowDetailView:"))) {
        class_addMethod(cls, NSSelectorFromString(@"wczz_orig_closeAnimationWindowAndShowDetailView:"), method_getImplementation(m), method_getTypeEncoding(m));
        class_replaceMethod(cls, NSSelectorFromString(@"closeAnimationWindowAndShowDetailView:"), (IMP)WCZZCloseRedDetail, method_getTypeEncoding(m));
    }
}

static void WCZZApplyRedDetailForLogic(id self, id data) {
    if (!WCZZPluginEnabled() || !WCZZBool(WCZZRedDetailKey, YES)) return;
    id info = WCZZDetailInfoFromLogic(self);
    if (!info) info = WCZZValue(data, @"m_oWCRedEnvelopesDetailInfo");
    if (!info) return;
    id view = WCZZValue(self, @"redEnvelopesDetailView");
    if ([view isKindOfClass:[UIView class]]) WCZZApplyRedDetail(view, info);
}

static void WCZZShowDetailView(id self, SEL _cmd) {
    ((void (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"wczz_orig_showDetailView"));
    dispatch_async(dispatch_get_main_queue(), ^{ WCZZApplyRedDetailForLogic(self, nil); });
}

static void WCZZOnQueryRedDetail(id self, SEL _cmd, id data, id error) {
    ((void (*)(id, SEL, id, id))objc_msgSend)(self, NSSelectorFromString(@"wczz_orig_OnQueryRedEnvelopesDetailRequest:Error:"), data, error);
    dispatch_async(dispatch_get_main_queue(), ^{ WCZZApplyRedDetailForLogic(self, data); });
}

static void WCZZCloseRedDetail(id self, SEL _cmd, id data) {
    ((void (*)(id, SEL, id))objc_msgSend)(self, NSSelectorFromString(@"wczz_orig_closeAnimationWindowAndShowDetailView:"), data);
    dispatch_async(dispatch_get_main_queue(), ^{ WCZZApplyRedDetailForLogic(self, data); });
}

static void WCZZRegisterPluginManager(void) {
    Class mgrClass = objc_getClass("WCPluginsMgr");
    if (!mgrClass) return;
    SEL shared = NSSelectorFromString(@"sharedInstance");
    SEL regController = NSSelectorFromString(@"registerControllerWithTitle:version:controller:");
    SEL regSwitch = NSSelectorFromString(@"registerSwitchWithTitle:key:");
    if (![mgrClass respondsToSelector:shared]) return;
    id mgr = ((id (*)(id, SEL))objc_msgSend)(mgrClass, shared);
    if (!mgr) return;
    if ([mgr respondsToSelector:regController]) {
        ((void (*)(id, SEL, id, id, id))objc_msgSend)(mgr, regController, @"wczz", @"1.0-0", @"WCZZSettingsViewController");
    }
    if ([mgr respondsToSelector:regSwitch]) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(mgr, regSwitch, @"启用 wczz", WCZZPluginEnabledKey);
    }
}

%ctor {
    WCZZInstallRedDetailHooks();
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:WCZZPluginEnabledKey] == nil) [d setBool:YES forKey:WCZZPluginEnabledKey];
    if ([d objectForKey:WCZZGroupEnabledKey] == nil) [d setBool:YES forKey:WCZZGroupEnabledKey];
    if ([d objectForKey:WCZZGroupTopKey] == nil) [d setBool:YES forKey:WCZZGroupTopKey];
    if ([d objectForKey:WCZZRedDetailKey] == nil) [d setBool:YES forKey:WCZZRedDetailKey];
    if ([d objectForKey:WCZZCommonRoomsKey] == nil) [d setObject:@[] forKey:WCZZCommonRoomsKey];
    [d synchronize];
    dispatch_async(dispatch_get_main_queue(), ^{ WCZZRegisterPluginManager(); });
}

#pragma mark - Settings entry
%hook NewSettingViewController
- (void)viewDidLoad {
    %orig;
    UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithTitle:@"wczz" style:UIBarButtonItemStylePlain target:self action:@selector(wczzOpenSettings)];
    self.navigationItem.rightBarButtonItem = item;
}
%new
- (void)wczzOpenSettings { [self.navigationController pushViewController:[WCZZSettingsViewController new] animated:YES]; }
%end
