#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

#pragma mark - wczz 1.0-0

static NSString * const WCZZGroupEnabledKey = @"wczz.group.enabled";
static NSString * const WCZZGroupTopKey = @"wczz.group.top";
static NSString * const WCZZCommonRoomsKey = @"wczz.group.commonRooms";
static NSString * const WCZZRedDetailKey = @"wczz.redDetail.enabled";
static NSString * const WCZZGroupUserName = @"wczz_group_helper";

static BOOL WCZZBool(NSString *key, BOOL fallback) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    return v ? [v boolValue] : fallback;
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
    if (!WCZZBool(WCZZGroupEnabledKey, YES)) return NO;
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
    id a = WCZZValue(logic, @"m_arrFilteredSession");
    if (![a isKindOfClass:[NSArray class]]) a = WCZZValue(logic, @"m_frontSessionArray");
    if (![a isKindOfClass:[NSArray class]]) return @[];
    if (!WCZZBool(WCZZGroupEnabledKey, YES)) return a;
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:[a count]];
    for (id s in a) if (!WCZZShouldFoldSession(s)) [out addObject:s];
    return out;
}

#pragma mark - Group helper page

@interface WCZZGroupHelperViewController : UITableViewController
@property(nonatomic,weak) id mainController;
@property(nonatomic,retain) NSArray *sessions;
@end
@implementation WCZZGroupHelperViewController
- (void)viewDidLoad { [super viewDidLoad]; self.title = @"群消息"; self.tableView.tableFooterView = [UIView new]; self.tableView.rowHeight = 60.0; }
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
    [[NSNotificationCenter defaultCenter] postNotificationName:@"wczz.settings.changed" object:nil];
}
@end

#pragma mark - Settings
@interface WCZZSettingsViewController : UITableViewController @end
@implementation WCZZSettingsViewController
- (void)viewDidLoad { [super viewDidLoad]; self.title = @"wczz"; self.tableView.tableFooterView = [UIView new]; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section { return 4; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *ID = @"wczz.setting"; UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:ID];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:ID];
    UISwitch *sw = [UISwitch new]; cell.accessoryView = nil; cell.accessoryType = UITableViewCellAccessoryNone;
    if (ip.row == 0) { cell.textLabel.text = @"开启群助手"; sw.on = WCZZBool(WCZZGroupEnabledKey, YES); sw.tag = 100; cell.accessoryView = sw; }
    else if (ip.row == 1) { cell.textLabel.text = @"置顶群助手"; sw.on = WCZZBool(WCZZGroupTopKey, YES); sw.tag = 101; cell.accessoryView = sw; }
    else if (ip.row == 2) { cell.textLabel.text = @"常用群"; cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; }
    else { cell.textLabel.text = @"红包详情"; sw.on = WCZZBool(WCZZRedDetailKey, YES); sw.tag = 102; cell.accessoryView = sw; }
    if (cell.accessoryView == sw) [sw addTarget:self action:@selector(wczzSwitch:) forControlEvents:UIControlEventValueChanged]; return cell;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES]; if (ip.row != 2) return;
    WCZZCommonRoomsViewController *vc = [WCZZCommonRoomsViewController new]; UIViewController *root = self.navigationController.viewControllers.firstObject;
    vc.mainController = [root isKindOfClass:objc_getClass("NewMainFrameViewController")] ? root : nil; [self.navigationController pushViewController:vc animated:YES];
}
- (void)wczzSwitch:(UISwitch *)sw { if (sw.tag == 100) WCZZSetBool(WCZZGroupEnabledKey, sw.on); else if (sw.tag == 101) WCZZSetBool(WCZZGroupTopKey, sw.on); else if (sw.tag == 102) WCZZSetBool(WCZZRedDetailKey, sw.on); [[NSNotificationCenter defaultCenter] postNotificationName:@"wczz.settings.changed" object:nil]; }
@end

#pragma mark - Main list / MiYou fake-cell path

%hook MainFrameLogicController

- (unsigned long long)getFilteredSessionCount {
    unsigned long long original = %orig;
    if (!WCZZBool(WCZZGroupEnabledKey, YES)) return original;
    NSArray *a = WCZZValue(self, @"m_arrFilteredSession");
    if (![a isKindOfClass:[NSArray class]]) return original;
    return (unsigned long long)[WCZZFilteredVisibleSessions(self) count];
}

- (id)getFilteredSessionInfo:(unsigned int)index {
    if (WCZZBool(WCZZGroupEnabledKey, YES)) {
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
    id data = [dataClass new];
    if ([data respondsToSelector:@selector(setUserName:)]) [data setUserName:WCZZGroupUserName];
    if ([data respondsToSelector:@selector(setTextForNameLabel:)]) [data setTextForNameLabel:@"群消息"];
    if ([data respondsToSelector:@selector(setTextForMessageLabel:)]) [data setTextForMessageLabel:[NSString stringWithFormat:@"%lu 个群聊", (unsigned long)groups.count]];
    if ([data respondsToSelector:@selector(setTextForTimeLabel:)]) [data setTextForTimeLabel:@""];
    if ([data respondsToSelector:@selector(setBTopCell:)]) [data setBTopCell:WCZZBool(WCZZGroupTopKey, YES)];
    if ([data respondsToSelector:@selector(setBNormalCell:)]) [data setBNormalCell:YES];
    return data;
}

- (void)onDidSelectCellAt:(id)indexPath {
    if (WCZZBool(WCZZGroupEnabledKey, YES)) {
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

- (void)onSessionRebuildEnd { %orig; dispatch_async(dispatch_get_main_queue(), ^{ [[NSNotificationCenter defaultCenter] postNotificationName:@"wczz.session.changed" object:nil]; }); }
- (void)onMainSessionReload { %orig; dispatch_async(dispatch_get_main_queue(), ^{ [[NSNotificationCenter defaultCenter] postNotificationName:@"wczz.session.changed" object:nil]; }); }
%end

%hook NewMainFrameViewController
- (void)logicUpdateSession:(id)session {
    %orig(session);
    if (WCZZShouldFoldSession(session)) dispatch_async(dispatch_get_main_queue(), ^{ SEL s = NSSelectorFromString(@"reloadSessions"); if ([self respondsToSelector:s]) ((void(*)(id,SEL))objc_msgSend)(self,s); });
}
%end

#pragma mark - Red detail

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
            Ivar iv = ivars[i]; const char *type = ivar_getTypeEncoding(iv);
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
    long long totalNum = [WCZZValue(info, @"m_lTotalNum") longLongValue];
    long long recNum = [WCZZValue(info, @"m_lRecNum") longLongValue];
    long long recAmount = [WCZZValue(info, @"m_lRecAmount") longLongValue];
    if (totalAmount <= 0 && totalNum <= 0 && recNum <= 0 && recAmount <= 0) return;
    NSString *text = [NSString stringWithFormat:@"共 %.2f 元 · %lld 人 · 已领取 %lld 人 / %.2f 元", totalAmount / 100.0, totalNum, recNum, recAmount / 100.0];
    UILabel *label = WCZZValue(vc, @"m_receivedInfoLable");
    if ([label isKindOfClass:[UILabel class]]) label.text = text;
}

%hook WCRedEnvelopesReceiveControlLogic
- (void)showDetailView { %orig; if (!WCZZBool(WCZZRedDetailKey, YES)) return; dispatch_async(dispatch_get_main_queue(), ^{ id view = WCZZValue(self, @"redEnvelopesDetailView"); id info = WCZZFindDetailInfoInObject(self, 0); if (info && [view isKindOfClass:[UIView class]]) WCZZApplyRedDetail(view, info); }); }
- (void)OnQueryRedEnvelopesDetailRequest:(id)arg1 Error:(id)arg2 { %orig(arg1,arg2); if (!WCZZBool(WCZZRedDetailKey, YES)) return; dispatch_async(dispatch_get_main_queue(), ^{ id info = WCZZFindDetailInfoInObject(self,0); if (!info) info = WCZZFindDetailInfoInObject(arg1,0); if (info) { id view = WCZZValue(self,@"redEnvelopesDetailView"); if ([view isKindOfClass:[UIView class]]) WCZZApplyRedDetail(view,info); } }); }
- (void)closeAnimationWindowAndShowDetailView:(id)arg1 { %orig(arg1); if (!WCZZBool(WCZZRedDetailKey, YES)) return; dispatch_async(dispatch_get_main_queue(), ^{ id info = WCZZFindDetailInfoInObject(self,0); if (!info) info = WCZZFindDetailInfoInObject(arg1,0); id view = WCZZValue(self,@"redEnvelopesDetailView"); if (info && [view isKindOfClass:[UIView class]]) WCZZApplyRedDetail(view,info); }); }
%end

%ctor {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:WCZZGroupEnabledKey] == nil) [d setBool:YES forKey:WCZZGroupEnabledKey];
    if ([d objectForKey:WCZZGroupTopKey] == nil) [d setBool:YES forKey:WCZZGroupTopKey];
    if ([d objectForKey:WCZZRedDetailKey] == nil) [d setBool:YES forKey:WCZZRedDetailKey];
    if ([d objectForKey:WCZZCommonRoomsKey] == nil) [d setObject:@[] forKey:WCZZCommonRoomsKey];
    [d synchronize];
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
