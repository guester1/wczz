#import "WeChatCompat.h"
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

// wczz 1.0-0
// Independent implementation. Runtime dependency: WeChat only.

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
static BOOL WCZZIsChatRoom(id contact, NSString *username) {
    // Do not require m_contact: some session states expose the username first.
    if ([username isKindOfClass:[NSString class]] && [username hasSuffix:@"@chatroom"]) return YES;
    if (!contact) return NO;
    Class c = objc_getClass("CContact");
    SEL s = NSSelectorFromString(@"IsChatRoomContact:");
    if (c && [c respondsToSelector:s]) {
        @try {
            if (((BOOL (*)(id, SEL, id))objc_msgSend)(c, s, contact)) return YES;
        } @catch (__unused NSException *e) {}
    }
    id u = WCZZValue(contact, @"m_nsUsrName");
    return [u isKindOfClass:[NSString class]] && [(NSString *)u hasSuffix:@"@chatroom"];
}
static BOOL WCZZIsCommonRoom(NSString *u) {
    return u.length > 0 && [WCZZCommonRooms() containsObject:u];
}
static BOOL WCZZShouldFold(id session) {
    if (!WCZZEnabled() || !WCZZBool(WCZZGroupEnabledKey, YES) || !session) return NO;
    NSString *u = WCZZUsername(session);
    if (!u.length) return NO;
    if (WCZZIsCommonRoom(u)) return NO;
    return WCZZIsChatRoom(WCZZContact(session), u);
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
        if (u.length && WCZZIsChatRoom(WCZZContact(session), u)) [groups addObject:session];
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

@interface WCZZSettingsViewController : UITableViewController @end
@implementation WCZZSettingsViewController
- (instancetype)init:(id)__unused model { return [super initWithStyle:UITableViewStyleGrouped]; }
- (void)viewDidLoad { [super viewDidLoad]; self.title = @"wczz"; self.tableView.tableFooterView = [UIView new]; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section { return section == 0 ? 5 : 0; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *ID = @"wczz.setting";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:ID];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:ID];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    if (ip.row <= 3) {
        UISwitch *sw = [UISwitch new];
        sw.tag = 99 + ip.row;
        if (ip.row == 0) sw.on = WCZZEnabled();
        else if (ip.row == 1) sw.on = WCZZBool(WCZZGroupEnabledKey, YES);
        else if (ip.row == 2) sw.on = WCZZBool(WCZZGroupTopKey, YES);
        else sw.on = WCZZBool(WCZZRedDetailKey, YES);
        [sw addTarget:self action:@selector(wczzSwitch:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        if (ip.row == 0) cell.textLabel.text = @"启用 wczz";
        else if (ip.row == 1) cell.textLabel.text = @"开启群助手";
        else if (ip.row == 2) cell.textLabel.text = @"置顶群助手";
        else cell.textLabel.text = @"红包详情";
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
    WCZZReloadMainList();
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.row <= 3) {
        UISwitch *sw = (UISwitch *)[(UITableViewCell *)[tv cellForRowAtIndexPath:ip] accessoryView];
        if ([sw isKindOfClass:[UISwitch class]]) {
            sw.on = !sw.on;
            [self wczzSwitch:sw];
        }
    } else if (ip.row == 4) {
        [self.navigationController pushViewController:[WCZZCommonRoomsViewController new] animated:YES];
    }
}
@end

#pragma mark - Main list integration

// We deliberately hook the actual UITableView data-source boundary. This is
// the most stable adaptation point for the current WeChat headers. The
// original table cell/session logic remains responsible for ordinary rows.

static const void *WCZZRowsCacheKey = &WCZZRowsCacheKey;
static const void *WCZZOriginalCountCacheKey = &WCZZOriginalCountCacheKey;
static NSArray *WCZZGetRowsCache(id self) { return objc_getAssociatedObject(self, WCZZRowsCacheKey); }
static void WCZZSetRowsCache(id self, NSArray *rows) { objc_setAssociatedObject(self, WCZZRowsCacheKey, rows ?: @[], OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
static long long WCZZGetCachedOriginalCount(id self) {
    NSNumber *n = objc_getAssociatedObject(self, WCZZOriginalCountCacheKey);
    return [n isKindOfClass:[NSNumber class]] ? n.longLongValue : -1;
}
static void WCZZSetCachedOriginalCount(id self, long long count) {
    objc_setAssociatedObject(self, WCZZOriginalCountCacheKey, @(count), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static id WCZZMainLogic(id self) { return WCZZValue(self, @"m_mainFrameLogicController"); }
static long long WCZZOriginalSessionCount(id self, long long section, long long fallback) {
    long long cached = WCZZGetCachedOriginalCount(self);
    if (cached >= 0) return cached;
    id logic = WCZZMainLogic(self);
    SEL sel = NSSelectorFromString(@"getSessionCountForSection:");
    if (logic && [logic respondsToSelector:sel]) {
        @try { return ((long long (*)(id, SEL, long long))objc_msgSend)(logic, sel, section); } @catch (__unused NSException *e) {}
    }
    return fallback;
}
static NSArray *WCZZBuildVisibleRows(id self, long long originalCount) {
    if (originalCount <= 0) return @[];
    id logic = WCZZMainLogic(self);
    SEL sel = NSSelectorFromString(@"getSessionInfoAtIndexPath:");
    if (!logic || ![logic respondsToSelector:sel]) return nil;
    NSMutableArray *rows = [NSMutableArray arrayWithCapacity:(NSUInteger)originalCount];
    for (NSInteger i = 0; i < originalCount; i++) {
        NSIndexPath *ip = [NSIndexPath indexPathForRow:i inSection:0];
        id session = nil;
        @try { session = ((id (*)(id, SEL, id))objc_msgSend)(logic, sel, ip); } @catch (__unused NSException *e) {}
        if (!WCZZShouldFold(session)) [rows addObject:@(i)];
    }
    return rows;
}
static BOOL WCZZHasFoldedRows(NSArray *rows, long long originalCount) {
    return [rows isKindOfClass:[NSArray class]] && originalCount > 0 && rows.count < (NSUInteger)originalCount;
}

%group WCZZMainHooks
%hook NewMainFrameViewController
- (long long)tableView:(id)tableView numberOfRowsInSection:(long long)section {
    long long original = %orig(tableView, section);
    if (section != 0 || !WCZZEnabled() || !WCZZBool(WCZZGroupEnabledKey, YES) || original <= 0) {
        if (section == 0) { WCZZSetRowsCache(self, nil); WCZZSetCachedOriginalCount(self, -1); }
        return original;
    }
    NSArray *rows = WCZZBuildVisibleRows(self, original);
    if (![rows isKindOfClass:[NSArray class]]) {
        WCZZSetRowsCache(self, nil);
        return original;
    }
    WCZZSetRowsCache(self, rows);
    WCZZSetCachedOriginalCount(self, original);
    if (rows.count == (NSUInteger)original) return original;
    return (long long)rows.count + 1;
}

- (id)tableView:(id)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSIndexPath *ip = [indexPath isKindOfClass:[NSIndexPath class]] ? (NSIndexPath *)indexPath : nil;
    if (!ip || ip.section != 0 || !WCZZEnabled() || !WCZZBool(WCZZGroupEnabledKey, YES)) {
        return %orig(tableView, indexPath);
    }
    NSArray *rows = WCZZGetRowsCache(self);
    long long original = WCZZOriginalSessionCount(self, 0, -1);
    if (![rows isKindOfClass:[NSArray class]] || rows.count == 0 || original <= 0) {
        rows = WCZZBuildVisibleRows(self, original);
        if ([rows isKindOfClass:[NSArray class]]) { WCZZSetRowsCache(self, rows); WCZZSetCachedOriginalCount(self, original); }
    }
    if (![rows isKindOfClass:[NSArray class]] || rows.count == 0 || !WCZZHasFoldedRows(rows, original)) return %orig(tableView, indexPath);
    BOOL top = WCZZBool(WCZZGroupTopKey, YES);
    NSInteger row = ip.row;
    BOOL helper = (top && row == 0) || (!top && row == (NSInteger)rows.count);
    if (helper) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"wczz.helper.fallback"];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"wczz.helper.fallback"];
        cell.textLabel.text = @"群助手";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu 个群聊", (unsigned long)(original - (long long)rows.count)];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }
    NSUInteger vi = top ? (row > 0 ? (NSUInteger)row - 1 : NSUIntegerMax) : (NSUInteger)row;
    if (vi >= rows.count) return %orig(tableView, indexPath);
    NSIndexPath *origIP = [NSIndexPath indexPathForRow:[rows[vi] integerValue] inSection:0];
    return %orig(tableView, origIP);
}

- (void)tableView:(id)tableView didSelectRowAtIndexPath:(id)indexPath {
    NSIndexPath *ip = [indexPath isKindOfClass:[NSIndexPath class]] ? (NSIndexPath *)indexPath : nil;
    if (ip && ip.section == 0 && WCZZEnabled() && WCZZBool(WCZZGroupEnabledKey, YES)) {
        NSArray *rows = WCZZGetRowsCache(self);
        long long original = WCZZOriginalSessionCount(self, 0, -1);
        if (![rows isKindOfClass:[NSArray class]] || original <= 0) {
            rows = WCZZBuildVisibleRows(self, original);
            if ([rows isKindOfClass:[NSArray class]]) WCZZSetRowsCache(self, rows);
        }
        if (WCZZHasFoldedRows(rows, original)) {
            BOOL top = WCZZBool(WCZZGroupTopKey, YES);
            NSInteger row = ip.row;
            BOOL helper = (top && row == 0) || (!top && row == (NSInteger)rows.count);
            if (helper) {
                [(UITableView *)tableView deselectRowAtIndexPath:indexPath animated:YES];
                WCZZGroupHelperViewController *vc = [WCZZGroupHelperViewController new];
                vc.mainController = self;
                UINavigationController *nav = self.navigationController;
                if (nav) [nav pushViewController:vc animated:YES];
                return;
            }
            NSUInteger vi = top ? (row > 0 ? (NSUInteger)row - 1 : NSUIntegerMax) : (NSUInteger)row;
            if (vi < rows.count) {
                NSIndexPath *origIP = [NSIndexPath indexPathForRow:[rows[vi] integerValue] inSection:0];
                %orig(tableView, origIP);
                return;
            }
        }
    }
    %orig(tableView, indexPath);
}
%end
%end

#pragma mark - Red detail

static void WCZZApplyRedDetail(id vc) {
    if (!WCZZEnabled() || !WCZZBool(WCZZRedDetailKey, YES) || !vc) return;
    id info = WCZZValue(vc, @"m_oWCRedEnvelopesDetailInfo");
    id labelObj = WCZZValue(vc, @"m_receivedInfoLable");
    if (!info || ![labelObj isKindOfClass:[UILabel class]]) return;
    long long totalAmount = [WCZZValue(info, @"m_lTotalAmount") longLongValue];
    long long totalNum = [WCZZValue(info, @"m_lTotalNum") longLongValue];
    long long recNum = [WCZZValue(info, @"m_lRecNum") longLongValue];
    long long recAmount = [WCZZValue(info, @"m_lRecAmount") longLongValue];
    if (totalAmount <= 0 && totalNum <= 0 && recNum <= 0 && recAmount <= 0) return;
    ((UILabel *)labelObj).text = [NSString stringWithFormat:@"共 %.2f 元 · %lld 人 · 已领取 %lld 人 / %.2f 元", totalAmount / 100.0, totalNum, recNum, recAmount / 100.0];
}

%group WCZZRedHooks
%hook WCRedEnvelopesRedEnvelopesDetailViewController
- (void)refreshViewWithData:(id)data {
    %orig(data);
    if (!WCZZEnabled() || !WCZZBool(WCZZRedDetailKey, YES)) return;
    dispatch_async(dispatch_get_main_queue(), ^{ WCZZApplyRedDetail(self); });
}
- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    if (!WCZZEnabled() || !WCZZBool(WCZZRedDetailKey, YES)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        WCZZApplyRedDetail(self);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ WCZZApplyRedDetail(self); });
    });
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
    ((void (*)(id, SEL, id, id, id))objc_msgSend)(mgr, reg, @"wczz", @"1.0-0", @"WCZZSettingsViewController");
    WCZZRegistered = YES;
}

static BOOL WCZZMainHooksStarted = NO;
static BOOL WCZZRedHooksStarted = NO;

static void WCZZInstallHooksWhenReady(void) {
    if (WCZZMainHooksStarted && WCZZRedHooksStarted) {
        WCZZRegisterPlugin();
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!WCZZMainHooksStarted && objc_getClass("NewMainFrameViewController")) {
            %init(WCZZMainHooks);
            WCZZMainHooksStarted = YES;
        }
        if (!WCZZRedHooksStarted && objc_getClass("WCRedEnvelopesRedEnvelopesDetailViewController")) {
            %init(WCZZRedHooks);
            WCZZRedHooksStarted = YES;
        }
        WCZZRegisterPlugin();
        if (!WCZZMainHooksStarted || !WCZZRedHooksStarted || !WCZZRegistered) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
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
        [d synchronize];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            WCZZInstallHooksWhenReady();
        });
    }
}
