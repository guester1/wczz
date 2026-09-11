#import "WeChatCompat.h"
#import <objc/message.h>
#import <objc/runtime.h>

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
    if (!logic) return @[];
    // m_arrFilteredSession is the list NewMainFrameViewController is actually
    // consuming. Prefer it so our row mapping stays identical to WeChat's
    // current ordering/search/filter state. Fall back to the front-session
    // cache only while that array is unavailable during startup/rebuild.
    id a = WCZZValue(logic, @"m_arrFilteredSession");
    id front = WCZZValue(logic, @"m_frontSessionArray");
    if (![a isKindOfClass:[NSArray class]] ||
        ([a count] == 0 && [front isKindOfClass:[NSArray class]] && [front count] > 0)) {
        a = front;
    }
    return [a isKindOfClass:[NSArray class]] ? a : @[];
}
static NSArray *WCZZFoldedSessionsFromLogic(id logic) {
    NSArray *source = WCZZSessionsFromLogic(logic);
    NSMutableArray *out = [NSMutableArray array];
    for (id s in source) if (WCZZShouldFoldSession(s)) [out addObject:s];
    return out;
}
static NSArray *WCZZFilteredVisibleSessionsFromLogic(id logic) {
    NSArray *source = WCZZSessionsFromLogic(logic);
    if (!WCZZPluginEnabled() || !WCZZBool(WCZZGroupEnabledKey, YES)) return source;
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:source.count];
    for (id s in source) if (!WCZZShouldFoldSession(s)) [out addObject:s];
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
@implementation WCZZCommonRoomsViewController
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = @"常用群"; self.tableView.tableFooterView = [UIView new];
    self.selected = [NSMutableSet setWithArray:WCZZCommonRooms()];
    NSMutableArray *groups = [NSMutableArray array];

    // Do not depend on the main-list controller here.  The common-group
    // editor is also reachable while the main list is being rebuilt, and
    // querying that controller from viewDidLoad can deadlock on some builds.
    Class ctxClass = objc_getClass("MMContext");
    Class mgrClass = objc_getClass("MMNewSessionMgr");
    SEL currentSel = NSSelectorFromString(@"currentContext");
    SEL getService = NSSelectorFromString(@"getService:");
    SEL getList = NSSelectorFromString(@"GetSessionInfoList");
    id ctx = (ctxClass && [ctxClass respondsToSelector:currentSel]) ? ((id (*)(id,SEL))objc_msgSend)(ctxClass,currentSel) : nil;
    id center = WCZZValue(ctx, @"serviceCenter");
    id mgr = (center && mgrClass && [center respondsToSelector:getService]) ? ((id (*)(id,SEL,Class))objc_msgSend)(center,getService,mgrClass) : nil;
    id src = (mgr && [mgr respondsToSelector:getList]) ? ((id (*)(id,SEL))objc_msgSend)(mgr,getList) : nil;
    if ([src isKindOfClass:[NSArray class]]) {
        for (id s in (NSArray *)src) {
            id contact = WCZZContact(s);
            NSString *username = WCZZUsername(s);
            if (contact && username.length && WCZZIsChatRoomContact(contact)) [groups addObject:s];
        }
    }
    // Fallback only if the session service did not expose its list.
    if (!groups.count) {
        id logic = WCZZValue(self.mainController, @"m_mainFrameLogicController");
        NSArray *fallback = WCZZSessionsFromLogic(logic);
        for (id s in fallback) if (WCZZIsChatRoomContact(WCZZContact(s)) && WCZZUsername(s).length) [groups addObject:s];
    }
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
    WCZZSetCommonRooms(self.selected.allObjects);
    [tv reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
    // Apply the selection immediately to the main list.  This is our own
    // state change; no MiYou/WCRefine state is involved.
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
    if (cell.accessoryView == sw) {
        [sw removeTarget:nil action:NULL forControlEvents:UIControlEventValueChanged];
        [sw addTarget:self action:@selector(wczzSwitch:) forControlEvents:UIControlEventValueChanged];
    }
    return cell;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    // Also support tapping the whole switch row, not just the UISwitch.
    // This makes the master switch reliable with the plugin manager's cell reuse.
    if (ip.row <= 3) {
        NSString *key = nil;
        if (ip.row == 0) key = WCZZPluginEnabledKey;
        else if (ip.row == 1) key = WCZZGroupEnabledKey;
        else if (ip.row == 2) key = WCZZGroupTopKey;
        else if (ip.row == 3) key = WCZZRedDetailKey;
        if (key) {
            WCZZSetBool(key, !WCZZBool(key, YES));
            [tv reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
            WCZZRequestMainListReload();
        }
        return;
    }
    if (ip.row != 4) return;
    WCZZCommonRoomsViewController *vc = [WCZZCommonRoomsViewController new];
    // The common-room editor reads MMNewSessionMgr directly; it does not need the main list controller.
    vc.mainController = nil;
    [self.navigationController pushViewController:vc animated:YES];
}
- (void)wczzSwitch:(UISwitch *)sw { if (sw.tag == 99) WCZZSetBool(WCZZPluginEnabledKey, sw.on); else if (sw.tag == 100) WCZZSetBool(WCZZGroupEnabledKey, sw.on); else if (sw.tag == 101) WCZZSetBool(WCZZGroupTopKey, sw.on); else if (sw.tag == 102) WCZZSetBool(WCZZRedDetailKey, sw.on); WCZZRequestMainListReload(); }
@end

#pragma mark - Main list integration

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

static NSArray *WCZZVisibleMainSessions(id logic) {
    return WCZZFilteredVisibleSessionsFromLogic(logic);
}

static id WCZZCellDataForSession(id logic, id session) {
    NSString *username = WCZZUsername(session);
    if (!logic || !username.length) return nil;
    SEL byName = NSSelectorFromString(@"getCellDataByUsrName:");
    if ([logic respondsToSelector:byName]) {
        id data = ((id (*)(id, SEL, id))objc_msgSend)(logic, byName, username);
        if (data) return data;
    }
    return nil;
}

static id WCZZMakeGroupHelperCellData(NSUInteger groupCount) {
    Class dataClass = objc_getClass("FakeMainFrameCellData");
    if (!dataClass) return nil;
    id data = [dataClass new];
    WCZZSetObjectProperty(data, NSSelectorFromString(@"setUserName:"), WCZZGroupUserName);
    WCZZSetObjectProperty(data, NSSelectorFromString(@"setTextForNameLabel:"), @"群助手");
    WCZZSetObjectProperty(data, NSSelectorFromString(@"setTextForMessageLabel:"), [NSString stringWithFormat:@"%lu 个群聊", (unsigned long)groupCount]);
    WCZZSetObjectProperty(data, NSSelectorFromString(@"setTextForTimeLabel:"), @"");
    WCZZSetBoolProperty(data, NSSelectorFromString(@"setBTopCell:"), WCZZBool(WCZZGroupTopKey, YES));
    WCZZSetBoolProperty(data, NSSelectorFromString(@"setBNormalCell:"), YES);
    return data;
}

static void WCZZOpenGroupHelperFrom(id presenter) {
    if (![presenter isKindOfClass:[UIViewController class]]) return;
    UINavigationController *nav = [presenter isKindOfClass:[UINavigationController class]] ? (UINavigationController *)presenter : presenter.navigationController;
    if (!nav) return;
    WCZZGroupHelperViewController *vc = [WCZZGroupHelperViewController new];
    vc.mainController = presenter;
    [nav pushViewController:vc animated:YES];
}

%hook NewMainFrameViewController

- (long long)logicGetCountForSection:(long long)section {
    long long original = %orig(section);
    if (section != 0 || !WCZZPluginEnabled() || !WCZZBool(WCZZGroupEnabledKey, YES)) return original;

    id logic = WCZZValue(self, @"m_mainFrameLogicController");
    NSArray *source = WCZZSessionsFromLogic(logic);
    if (!source.count) return original;

    NSUInteger groupCount = WCZZFoldedSessionsFromLogic(logic).count;
    if (!groupCount) return original;

    // Preserve WeChat's own count when our session snapshot is not the same
    // size. This prevents search/rebuild states from producing bad indexes.
    if ((long long)source.count != original && original > 0) {
        return original - MIN((NSUInteger)original, groupCount) + 1;
    }
    return (long long)(source.count - groupCount + 1);
}

- (id)logicGetCellDataAtIndexPath:(id)indexPath {
    if (!WCZZPluginEnabled() || !WCZZBool(WCZZGroupEnabledKey, YES) ||
        ![indexPath respondsToSelector:@selector(section)] || [indexPath section] != 0) {
        return %orig(indexPath);
    }

    id logic = WCZZValue(self, @"m_mainFrameLogicController");
    NSArray *source = WCZZSessionsFromLogic(logic);
    NSArray *visible = WCZZVisibleMainSessions(logic);
    NSUInteger groupCount = WCZZFoldedSessionsFromLogic(logic).count;
    if (!groupCount || !source.count) return %orig(indexPath);

    NSUInteger row = [indexPath respondsToSelector:@selector(row)] ? (NSUInteger)[indexPath row] : NSUIntegerMax;
    BOOL top = WCZZBool(WCZZGroupTopKey, YES);
    BOOL helperRow = (top && row == 0) || (!top && row == visible.count);
    if (helperRow) return WCZZMakeGroupHelperCellData(groupCount) ?: %orig(indexPath);

    NSUInteger visibleIndex = top ? (row ? row - 1 : NSUIntegerMax) : row;
    if (visibleIndex >= visible.count) return %orig(indexPath);

    id session = visible[visibleIndex];
    NSString *username = WCZZUsername(session);
    if (username.length) {
        SEL indexSel = NSSelectorFromString(@"indexPathOfSessionUserName:");
        if ([logic respondsToSelector:indexSel]) {
            id originalIndexPath = ((id (*)(id,SEL,id))objc_msgSend)(logic, indexSel, username);
            if (originalIndexPath) return %orig(originalIndexPath);
        }
        id data = WCZZCellDataForSession(logic, session);
        if (data) return data;
    }
    return %orig(indexPath);
}

- (id)logicGetSessionAtIndexPath:(id)indexPath {
    if (!WCZZPluginEnabled() || !WCZZBool(WCZZGroupEnabledKey, YES) ||
        ![indexPath respondsToSelector:@selector(section)] || [indexPath section] != 0) {
        return %orig(indexPath);
    }

    id logic = WCZZValue(self, @"m_mainFrameLogicController");
    NSArray *source = WCZZSessionsFromLogic(logic);
    NSArray *visible = WCZZVisibleMainSessions(logic);
    NSUInteger groupCount = WCZZFoldedSessionsFromLogic(logic).count;
    if (!groupCount || !source.count) return %orig(indexPath);

    NSUInteger row = [indexPath respondsToSelector:@selector(row)] ? (NSUInteger)[indexPath row] : NSUIntegerMax;
    BOOL top = WCZZBool(WCZZGroupTopKey, YES);
    BOOL helperRow = (top && row == 0) || (!top && row == visible.count);
    if (helperRow) return nil;

    NSUInteger visibleIndex = top ? (row ? row - 1 : NSUIntegerMax) : row;
    if (visibleIndex >= visible.count) return nil;

    id session = visible[visibleIndex];
    NSString *username = WCZZUsername(session);
    SEL indexSel = NSSelectorFromString(@"indexPathOfSessionUserName:");
    if (username.length && [logic respondsToSelector:indexSel]) {
        id originalIndexPath = ((id (*)(id,SEL,id))objc_msgSend)(logic, indexSel, username);
        if (originalIndexPath) return %orig(originalIndexPath);
    }
    return session;
}

- (void)tableView:(id)tableView didSelectRowAtIndexPath:(id)indexPath {
    if (WCZZPluginEnabled() && WCZZBool(WCZZGroupEnabledKey, YES) &&
        [indexPath respondsToSelector:@selector(section)] && [indexPath section] == 0) {
        id logic = WCZZValue(self, @"m_mainFrameLogicController");
        NSArray *visible = WCZZVisibleMainSessions(logic);
        NSUInteger groupCount = WCZZFoldedSessionsFromLogic(logic).count;
        if (groupCount) {
            NSUInteger row = [indexPath respondsToSelector:@selector(row)] ? (NSUInteger)[indexPath row] : NSUIntegerMax;
            BOOL top = WCZZBool(WCZZGroupTopKey, YES);
            BOOL isHelper = (top && row == 0) || (!top && row == visible.count);
            if (isHelper) {
                [tableView deselectRowAtIndexPath:indexPath animated:YES];
                WCZZOpenGroupHelperFrom(self);
                return;
            }

            NSUInteger visibleIndex = top ? (row ? row - 1 : NSUIntegerMax) : row;
            if (visibleIndex < visible.count) {
                [tableView deselectRowAtIndexPath:indexPath animated:YES];
                id session = visible[visibleIndex];
                SEL open = NSSelectorFromString(@"onLogicOpenSession:");
                if ([self respondsToSelector:open]) {
                    ((void (*)(id,SEL,id))objc_msgSend)(self, open, session);
                    return;
                }
            }
        }
    }
    %orig(tableView, indexPath);
}

%end

#pragma mark - Red detail

static void WCZZApplyRedDetailToViewController(id vc, id info) {
    if (!WCZZPluginEnabled() || !WCZZBool(WCZZRedDetailKey, YES) || !vc || !info) return;
    long long totalAmount = [WCZZValue(info, @"m_lTotalAmount") longLongValue];
    long long totalNum = [WCZZValue(info, @"m_lTotalNum") longLongValue];
    long long recNum = [WCZZValue(info, @"m_lRecNum") longLongValue];
    long long recAmount = [WCZZValue(info, @"m_lRecAmount") longLongValue];
    if (totalAmount <= 0 && totalNum <= 0 && recNum <= 0 && recAmount <= 0) return;

    UILabel *label = WCZZValue(vc, @"m_receivedInfoLable");
    if (![label isKindOfClass:[UILabel class]]) return;

    NSString *text = [NSString stringWithFormat:@"共 %.2f 元 · %lld 人 · 已领取 %lld 人 / %.2f 元",
                      totalAmount / 100.0, totalNum, recNum, recAmount / 100.0];
    label.text = text;
}

%hook WCRedEnvelopesRedEnvelopesDetailViewController
- (void)refreshViewWithData:(id)data {
    %orig(data);
    if (!WCZZPluginEnabled() || !WCZZBool(WCZZRedDetailKey, YES)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        WCZZApplyRedDetailToViewController(self, data);
    });
}
%end

static BOOL WCZZPluginManagerRegistered = NO;

static void WCZZRegisterPluginManager(void) {
    if (WCZZPluginManagerRegistered) return;
    Class mgrClass = objc_getClass("WCPluginsMgr");
    if (!mgrClass) return;
    SEL shared = NSSelectorFromString(@"sharedInstance");
    SEL regController = NSSelectorFromString(@"registerControllerWithTitle:version:controller:");
    if (![mgrClass respondsToSelector:shared]) return;
    id mgr = ((id (*)(id, SEL))objc_msgSend)(mgrClass, shared);
    if (!mgr) return;
    if ([mgr respondsToSelector:regController]) {
        ((void (*)(id, SEL, id, id, id))objc_msgSend)(mgr, regController, @"wczz", @"1.0-0", @"WCZZSettingsViewController");
        WCZZPluginManagerRegistered = YES;
    }
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
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ WCZZRegisterPluginManager(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ WCZZRegisterPluginManager(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ WCZZRegisterPluginManager(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ WCZZRegisterPluginManager(); });
    });
}
