#import "WeChatCompat.h"
#import <objc/message.h>
#import <objc/runtime.h>

#pragma mark - 配置存储

static NSString * const WCZZGroupEnabledKey = @"wczz.group.enabled";
static NSString * const WCZZGroupTopKey     = @"wczz.group.top";
static NSString * const WCZZCommonRoomsKey  = @"wczz.group.commonRooms";
static NSString * const WCZZRedDetailKey    = @"wczz.redDetail.enabled";
static NSString * const WCZZGroupUserName   = @"wczz_group_helper";

static BOOL WCZZBool(NSString *key, BOOL fallback) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    return v ? [v boolValue] : fallback;
}
static void WCZZSetBool(NSString *key, BOOL value) {
    [[NSUserDefaults standardUserDefaults] setBool:value forKey:key];
}
static NSArray *WCZZCommonRooms(void) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:WCZZCommonRoomsKey];
    return [v isKindOfClass:[NSArray class]] ? v : @[];
}
static void WCZZSetCommonRooms(NSArray *rooms) {
    [[NSUserDefaults standardUserDefaults] setObject:rooms ?: @[] forKey:WCZZCommonRoomsKey];
}

#pragma mark - 安全取值（全部 try/catch）

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
    if (!WCZZBool(WCZZGroupEnabledKey, YES)) return NO;
    NSString *username = WCZZUsername(session);
    return username.length && WCZZIsChatRoomContact(WCZZContact(session)) && !WCZZIsCommonRoom(username);
}

#pragma mark - 会话数据源（★ 全部快照 copy，绝不操作活数组）

static NSArray *WCZZSessionsFromLogic(id logic) {
    if (!logic) return @[];
    NSArray *arr = nil;
    arr = WCZZValue(logic, @"m_filterSessionList");       // 8.0.5x+
    if (![arr isKindOfClass:[NSArray class]]) arr = WCZZValue(logic, @"m_normalSessions");
    if (![arr isKindOfClass:[NSArray class]]) arr = WCZZValue(logic, @"m_arrFilteredSession"); // 旧版
    if (![arr isKindOfClass:[NSArray class]]) arr = WCZZValue(logic, @"m_frontSessionArray");
    return [arr isKindOfClass:[NSArray class]] ? arr : @[];
}
static NSArray *WCZZFoldedSessionsFromLogic(id logic) {
    NSArray *source = [WCZZSessionsFromLogic(logic) copy];   // ★ 崩溃修复点1：快照
    NSMutableArray *out = [NSMutableArray array];
    for (id s in source) if (WCZZShouldFoldSession(s)) [out addObject:s];
    return out;
}
static NSArray *WCZZFilteredVisibleSessions(id logic) {
    NSArray *a = [WCZZSessionsFromLogic(logic) copy];
    if (!WCZZBool(WCZZGroupEnabledKey, YES)) return a;
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:a.count];
    for (id s in a) if (!WCZZShouldFoldSession(s)) [out addObject:s];
    return out;
}

#pragma mark - 主线程刷新

static void WCZZRequestMainListReload(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        Class cls = objc_getClass("NewMainFrameViewController");
        if (!cls) return;
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            NSMutableArray *stack = [NSMutableArray array];
            if (window.rootViewController) [stack addObject:window.rootViewController];
            while (stack.count) {
                UIViewController *cur = stack.lastObject;
                [stack removeLastObject];
                if ([cur isKindOfClass:cls]) {
                    SEL reload = NSSelectorFromString(@"reloadSessions");
                    if ([cur respondsToSelector:reload])
                        ((void(*)(id,SEL))objc_msgSend)(cur, reload);
                    return;
                }
                if (cur.presentedViewController) [stack addObject:cur.presentedViewController];
                for (UIViewController *child in cur.childViewControllers) [stack addObject:child];
            }
        }
    });
}

#pragma mark - ★ 一键已读（崩溃修复核心：三级降级，绝不裸发 selector）

static void WCZZMarkAllFoldedSessionsRead(id logic) {
    // 1. 快照（崩溃修复点1：MiYou 直接在活数组的枚举 block 里发消息，8.0.78 下必崩）
    NSArray *folded = WCZZFoldedSessionsFromLogic(logic);
    if (!folded.count) return;

    // 2. 定位会话管理器（多候选类名）
    id sessionMgr = nil;
    for (NSString *clsName in @[@"CMainSessionMgr", @"MainSessionMgr", @"MMMainSessionMgr"]) {
        Class c = objc_getClass(clsName.UTF8String);
        if (!c) continue;
        for (NSString *selName in @[@"sharedInstance", @"getInstance"]) {
            SEL s = NSSelectorFromString(selName);
            if ([c respondsToSelector:s]) {
                sessionMgr = ((id (*)(id,SEL))objc_msgSend)(c, s);
                break;
            }
        }
        if (sessionMgr) break;
    }

    // 3. 逐个清零 —— 第一级：管理器接口（★ 崩溃修复点2：respondsToSelector 保护）
    static NSArray *changeSels = nil;
    if (!changeSels) changeSels = @[
        @"ChangeSessionUnReadCount:to:",
        @"ChangeSessionUnReadCount:To:",
        @"OnChangeSessionUnReadCount:to:",
    ];
    SEL foundSel = nil;
    for (NSString *n in changeSels) {
        SEL s = NSSelectorFromString(n);
        if (sessionMgr && [sessionMgr respondsToSelector:s]) { foundSel = s; break; }
    }

    for (id s in folded) {
        NSString *username = WCZZUsername(s);
        if (!username.length) continue;

        if (foundSel) {
            ((void (*)(id,SEL,id,unsigned int))objc_msgSend)(sessionMgr, foundSel, username, 0);
            continue;
        }
        // 第二级：直接 KVC 置零（try/catch，永不崩）
        @try {
            [s setValue:@0 forKey:@"m_uUnReadCount"];
            [s setValue:@0 forKey:@"m_uUnRead2"];
        } @catch (__unused NSException *e) {}
    }

    // 4. 主线程统一刷新一次（避免连续 reload 竞态）
    dispatch_async(dispatch_get_main_queue(), ^{
        for (NSString *n in @[@"rebuildMainSessions", @"updateMainSessionListNotify:"]) {
            SEL s = NSSelectorFromString(n);
            if (logic && [logic respondsToSelector:s]) {
                if ([n hasSuffix:@":"])
                    ((void (*)(id,SEL,id))objc_msgSend)(logic, s, nil);
                else
                    ((void (*)(id,SEL))objc_msgSend)(logic, s);
            }
        }
        WCZZRequestMainListReload();
    });
}
// 注意：★★★ 完全不使用 DeleteAllSession / 清空记录类接口（MiYou 原版的高危调用，已彻底移除）★★★

#pragma mark - 群助手列表页（加号菜单只保留两项）

@interface WCZZCommonRoomsViewController : UITableViewController
@property(nonatomic,weak) id mainController;
@property(nonatomic,retain) NSArray *groups;
@property(nonatomic,retain) NSMutableSet *selected;
@end
@implementation WCZZCommonRoomsViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"管理常用群";
    self.tableView.tableFooterView = [UIView new];
    self.selected = [NSMutableSet setWithArray:WCZZCommonRooms()];
    id logic = WCZZValue(self.mainController, @"m_mainFrameLogicController");
    NSMutableArray *groups = [NSMutableArray array];
    for (id s in WCZZSessionsFromLogic(logic)) {
        if (WCZZIsChatRoomContact(WCZZContact(s)) && WCZZUsername(s).length) [groups addObject:s];
    }
    self.groups = groups;
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section { return (NSInteger)self.groups.count; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *ID = @"wczz.common.room";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:ID];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:ID];
    id s = self.groups[ip.row];
    cell.textLabel.text = WCZZContactDisplayName(WCZZContact(s));
    cell.accessoryType = [self.selected containsObject:WCZZUsername(s)] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    NSString *u = WCZZUsername(self.groups[ip.row]);
    if (!u.length) return;
    if ([self.selected containsObject:u]) [self.selected removeObject:u]; else [self.selected addObject:u];
    WCZZSetCommonRooms(self.selected.allObjects);
    [tv reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
    WCZZRequestMainListReload();
}
@end

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
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(wczzOnPlus:)];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.sessions = WCZZFoldedSessionsFromLogic(WCZZValue(self.mainController, @"m_mainFrameLogicController"));
    [self.tableView reloadData];
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section { return (NSInteger)self.sessions.count; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *ID = @"wczz.group.session";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:ID];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:ID];
    id s = self.sessions[ip.row];
    cell.textLabel.text = WCZZContactDisplayName(WCZZContact(s));
    NSUInteger unread = [WCZZValue(s, @"m_uUnReadCount") unsignedIntegerValue];
    cell.detailTextLabel.text = unread ? [NSString stringWithFormat:@"%lu 条未读", (unsigned long)unread] : @"";
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    id s = self.sessions[ip.row];
    SEL sel = NSSelectorFromString(@"onLogicOpenSession:");
    if ([self.mainController respondsToSelector:sel])
        ((void(*)(id,SEL,id))objc_msgSend)(self.mainController, sel, s);
}
// ★ 菜单：只保留「一键已读」「管理常用群」，MiYou 的「清空聊天记录/删除所有消息」已永久移除
- (void)wczzOnPlus:(id)sender {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:nil message:nil
                                                      preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"一键已读" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        WCZZMarkAllFoldedSessionsRead(WCZZValue(self.mainController, @"m_mainFrameLogicController"));
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"管理常用群" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        WCZZCommonRoomsViewController *vc = [WCZZCommonRoomsViewController new];
        vc.mainController = self.mainController;
        [self.navigationController pushViewController:vc animated:YES];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController && sender)
        sheet.popoverPresentationController.barButtonItem = sender;
    [self presentViewController:sheet animated:YES completion:nil];
}
@end

#pragma mark - 设置页

@interface WCZZSettingsViewController : UITableViewController @end
@implementation WCZZSettingsViewController
- (void)viewDidLoad { [super viewDidLoad]; self.title = @"wczz"; self.tableView.tableFooterView = [UIView new]; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section { return 4; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *ID = @"wczz.setting";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:ID];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:ID];
    cell.accessoryView = nil; cell.accessoryType = UITableViewCellAccessoryNone;
    UISwitch *sw = [UISwitch new];
    if (ip.row == 0) { cell.textLabel.text = @"开启群助手"; sw.on = WCZZBool(WCZZGroupEnabledKey, YES); sw.tag = 100; }
    else if (ip.row == 1) { cell.textLabel.text = @"置顶群助手"; sw.on = WCZZBool(WCZZGroupTopKey, YES); sw.tag = 101; }
    else if (ip.row == 2) { cell.textLabel.text = @"常用群"; cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; return cell; }
    else { cell.textLabel.text = @"红包详情"; sw.on = WCZZBool(WCZZRedDetailKey, YES); sw.tag = 102; }
    cell.accessoryView = sw;
    [sw addTarget:self action:@selector(wczzSwitch:) forControlEvents:UIControlEventValueChanged];
    return cell;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.row != 2) return;
    WCZZCommonRoomsViewController *vc = [WCZZCommonRoomsViewController new];
    for (UIViewController *c in self.navigationController.viewControllers) {
        if ([NSStringFromClass(c.class) isEqualToString:@"NewMainFrameViewController"]) { vc.mainController = c; break; }
    }
    [self.navigationController pushViewController:vc animated:YES];
}
- (void)wczzSwitch:(UISwitch *)sw {
    if (sw.tag == 100) WCZZSetBool(WCZZGroupEnabledKey, sw.on);
    else if (sw.tag == 101) WCZZSetBool(WCZZGroupTopKey, sw.on);
    else WCZZSetBool(WCZZRedDetailKey, sw.on);
    WCZZRequestMainListReload();
}
@end

#pragma mark - 红包详情

static id WCZZFindDetailInfoInObject(id object, NSUInteger depth) {
    if (!object || depth > 2) return nil;
    Class cls = object_getClass(object);
    const char *cn = cls ? class_getName(cls) : "";
    if (strstr(cn, "WCRedEnvelopesDetailInfo")) return object;
    id direct = WCZZValue(object, @"m_oWCRedEnvelopesDetailInfo");
    if (direct) return direct;
    if (depth == 2) return nil;
    for (Class c = cls; c && c != [NSObject class]; c = class_getSuperclass(c)) {
        unsigned int count = 0; Ivar *ivars = class_copyIvarList(c, &count);
        for (unsigned int i = 0; i < count; i++) {
            Ivar iv = ivars[i];
            const char *type = ivar_getTypeEncoding(iv);
            if (!type || type[0] != '@') continue;
            id child = object_getIvar(object, iv);
            id found = WCZZFindDetailInfoInObject(child, depth + 1);
            if (found) { free(ivars); return found; }
        }
        free(ivars);
    }
    return nil;
}
static void WCZZApplyRedDetail(id vc, id info) {
    if (!WCZZBool(WCZZRedDetailKey, YES) || !vc || !info) return;
    long long totalAmount = [WCZZValue(info, @"m_lTotalAmount") longLongValue];
    long long totalNum    = [WCZZValue(info, @"m_lTotalNum") longLongValue];
    long long recNum      = [WCZZValue(info, @"m_lRecNum") longLongValue];
    long long recAmount   = [WCZZValue(info, @"m_lRecAmount") longLongValue];
    if (totalAmount <= 0 && totalNum <= 0 && recNum <= 0 && recAmount <= 0) return;
    NSString *text = [NSString stringWithFormat:@"共 %.2f 元 · %lld 人 · 已领取 %lld 人 / %.2f 元",
                      totalAmount/100.0, totalNum, recNum, recAmount/100.0];
    id label = WCZZValue(vc, @"m_receivedInfoLable");
    if ([label isKindOfClass:[UILabel class]]) label.text = text;
}
static void WCZZApplyRedDetailForLogic(id self_, id data) {
    if (!WCZZBool(WCZZRedDetailKey, YES)) return;
    id info = WCZZFindDetailInfoInObject(self_, 0);
    if (!info && data) info = WCZZFindDetailInfoInObject(data, 0);
    if (!info) return;
    id view = WCZZValue(self_, @"redEnvelopesDetailView");
    if ([view isKindOfClass:[UIView class]]) WCZZApplyRedDetail(view, info);
}

static void WCZZShowDetailView(id self_, SEL _cmd) {
    ((void (*)(id, SEL))objc_msgSend)(self_, NSSelectorFromString(@"wczz_orig_showDetailView"));
    dispatch_async(dispatch_get_main_queue(), ^{ WCZZApplyRedDetailForLogic(self_, nil); });
}
static void WCZZOnQueryRedDetail(id self_, SEL _cmd, id data, id error) {
    ((void (*)(id, SEL, id, id))objc_msgSend)(self_, NSSelectorFromString(@"wczz_orig_OnQueryRedEnvelopesDetailRequest:Error:"), data, error);
    dispatch_async(dispatch_get_main_queue(), ^{ WCZZApplyRedDetailForLogic(self_, data); });
}
static void WCZZCloseRedDetail(id self_, SEL _cmd, id data) {
    ((void (*)(id, SEL, id))objc_msgSend)(self_, NSSelectorFromString(@"wczz_orig_closeAnimationWindowAndShowDetailView:"), data);
    dispatch_async(dispatch_get_main_queue(), ^{ WCZZApplyRedDetailForLogic(self_, data); });
}
static void WCZZInstallRedDetailHooks(void) {
    Class cls = objc_getClass("WCRedEnvelopesReceiveControlLogic");
    if (!cls) return;
    struct { const char *orig; const char *bak; IMP imp; } hooks[] = {
        { "showDetailView", "wczz_orig_showDetailView", (IMP)WCZZShowDetailView },
        { "OnQueryRedEnvelopesDetailRequest:Error:", "wczz_orig_OnQueryRedEnvelopesDetailRequest:Error:", (IMP)WCZZOnQueryRedDetail },
        { "closeAnimationWindowAndShowDetailView:", "wczz_orig_closeAnimationWindowAndShowDetailView:", (IMP)WCZZCloseRedDetail },
    };
    for (int i = 0; i < 3; i++) {
        Method m = class_getInstanceMethod(cls, NSSelectorFromString(hooks[i].orig));
        if (m && !class_getInstanceMethod(cls, NSSelectorFromString(hooks[i].bak))) {
            class_addMethod(cls, NSSelectorFromString(hooks[i].bak), method_getImplementation(m), method_getTypeEncoding(m));
            class_replaceMethod(cls, NSSelectorFromString(hooks[i].orig), hooks[i].imp, method_getTypeEncoding(m));
        }
    }
}

#pragma mark - 主列表 Hook（新旧双套 API）

%hook MainFrameLogicController

- (unsigned long long)getFilteredSessionCount {
    unsigned long long original = %orig;
    if (!WCZZBool(WCZZGroupEnabledKey, YES)) return original;
    return (unsigned long long)[WCZZFilteredVisibleSessions(self) count];
}
- (id)getFilteredSessionInfo:(unsigned int)index {
    if (WCZZBool(WCZZGroupEnabledKey, YES)) {
        NSArray *visible = WCZZFilteredVisibleSessions(self);
        if (index < visible.count) return visible[index];
        return nil;
    }
    return %orig(index);
}
- (long long)getFakeCellCount {
    long long original = %orig;
    if (!WCZZBool(WCZZGroupEnabledKey, YES)) return original;
    return WCZZFoldedSessionsFromLogic(self).count ? original + 1 : original;
}
- (id)getFakeCellData:(unsigned int)index {
    id original = %orig(index);
    if (!WCZZBool(WCZZGroupEnabledKey, YES)) return original;
    NSArray *groups = WCZZFoldedSessionsFromLogic(self);
    if (!groups.count) return original;
    long long originalCount = [self getFakeCellCount] - 1;
    if ((long long)index < originalCount) return original;
    Class dataClass = objc_getClass("FakeMainFrameCellData");
    if (!dataClass) return original;
    id d = [dataClass new];
    NSUInteger unread = 0;
    for (id s in groups) unread += [WCZZValue(s, @"m_uUnReadCount") unsignedIntegerValue];
    if ([d respondsToSelector:@selector(setUserName:)]) [d setUserName:WCZZGroupUserName];
    if ([d respondsToSelector:@selector(setTextForNameLabel:)]) [d setTextForNameLabel:@"群消息"];
    if ([d respondsToSelector:@selector(setTextForMessageLabel:)])
        [d setTextForMessageLabel:[NSString stringWithFormat:@"%lu 个群聊%@", (unsigned long)groups.count,
                                  unread ? [NSString stringWithFormat:@" · %lu 条未读", (unsigned long)unread] : @""]];
    if ([d respondsToSelector:@selector(setTextForTimeLabel:)]) [d setTextForTimeLabel:@""];
    if ([d respondsToSelector:@selector(setBTopCell:)]) [d setBTopCell:WCZZBool(WCZZGroupTopKey, YES)];
    if ([d respondsToSelector:@selector(setBNormalCell:)]) [d setBNormalCell:YES];
    return d;
}
- (void)onDidSelectCellAt:(id)indexPath {
    if (WCZZBool(WCZZGroupEnabledKey, YES)) {
        NSArray *groups = WCZZFoldedSessionsFromLogic(self);
        if (groups.count) {
            NSUInteger row = [indexPath respondsToSelector:@selector(row)] ? (NSUInteger)[indexPath row] : NSUIntegerMax;
            if (row == (NSUInteger)([self getFakeCellCount] - 1)) {
                UIViewController *presenter = nil;
                id delegate = WCZZValue(self, @"m_delegate");
                if ([delegate isKindOfClass:[UIViewController class]]) presenter = delegate;
                if (!presenter) {
                    UIViewController *r = UIApplication.sharedApplication.keyWindow.rootViewController;
                    while (r.presentedViewController) r = r.presentedViewController;
                    presenter = r;
                }
                if (presenter) {
                    WCZZGroupHelperViewController *vc = [WCZZGroupHelperViewController new];
                    vc.mainController = presenter;
                    [presenter.navigationController pushViewController:vc animated:YES];
                }
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
    if (WCZZShouldFoldSession(session)) dispatch_async(dispatch_get_main_queue(), ^{
        SEL s = NSSelectorFromString(@"reloadSessions");
        if ([self respondsToSelector:s]) ((void(*)(id,SEL))objc_msgSend)(self, s);
    });
}
%end

#pragma mark - 设置入口

%hook NewSettingViewController
- (void)viewDidLoad {
    %orig;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"wczz" style:UIBarButtonItemStylePlain
               target:self action:@selector(wczzOpenSettings)];
}
%new
- (void)wczzOpenSettings {
    [self.navigationController pushViewController:[WCZZSettingsViewController new] animated:YES];
}
%end

#pragma mark - 构造

%ctor {
    WCZZInstallRedDetailHooks();
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:WCZZGroupEnabledKey] == nil) [d setBool:YES forKey:WCZZGroupEnabledKey];
    if ([d objectForKey:WCZZGroupTopKey] == nil) [d setBool:YES forKey:WCZZGroupTopKey];
    if ([d objectForKey:WCZZRedDetailKey] == nil) [d setBool:YES forKey:WCZZRedDetailKey];
    if ([d objectForKey:WCZZCommonRoomsKey] == nil) [d setObject:@[] forKey:WCZZCommonRoomsKey];
    [d synchronize];
}
