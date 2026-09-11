#import "WeChatCompat.h"
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

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
static NSArray *WCZZCommonRooms(void) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:WCZZCommonRoomsKey];
    return [v isKindOfClass:[NSArray class]] ? v : @[];
}
static void WCZZSetCommonRooms(NSArray *rooms) {
    [[NSUserDefaults standardUserDefaults] setObject:rooms ?: @[] forKey:WCZZCommonRoomsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}
static BOOL WCZZEnabled(void) { return WCZZBool(WCZZPluginEnabledKey, YES); }
static id WCZZValue(id obj, NSString *key) { if (!obj) return nil; @try { return [obj valueForKey:key]; } @catch (...) { return nil; } }
static NSString *WCZZUsername(id session) { id v=WCZZValue(session,@"m_nsUserName"); return [v isKindOfClass:[NSString class]]?v:nil; }
static id WCZZContact(id session) { return WCZZValue(session,@"m_contact"); }
static BOOL WCZZIsChatRoom(id contact) {
    if (!contact) return NO;
    Class c=objc_getClass("CContact"); SEL s=NSSelectorFromString(@"IsChatRoomContact:");
    if (c && [c respondsToSelector:s]) { @try { if (((BOOL(*)(id,SEL,id))objc_msgSend)(c,s,contact)) return YES; } @catch (...) {} }
    NSString *u=WCZZValue(contact,@"m_nsUsrName");
    return [u isKindOfClass:[NSString class]] && [u hasSuffix:@"@chatroom"];
}
static BOOL WCZZShouldFold(id session) {
    if (!WCZZEnabled() || !WCZZBool(WCZZGroupEnabledKey,YES)) return NO;
    NSString *u=WCZZUsername(session); id c=WCZZContact(session);
    if (!u.length) return NO;
    return WCZZIsChatRoom(c) && ![WCZZCommonRooms() containsObject:u];
}
static NSString *WCZZDisplayName(id contact) {
    SEL s=NSSelectorFromString(@"getContactDisplayName");
    if (contact && [contact respondsToSelector:s]) { @try { id n=((id(*)(id,SEL))objc_msgSend)(contact,s); if ([n isKindOfClass:[NSString class]]&&n.length) return n; } @catch (...) {} }
    id n=WCZZValue(contact,@"m_nsNickName"); return ([n isKindOfClass:[NSString class]]&&n.length)?n:@"群聊";
}

static NSArray *WCZZSessionList(void) {
    Class ctx=objc_getClass("MMContext"), mgrClass=objc_getClass("MMNewSessionMgr");
    SEL cur=NSSelectorFromString(@"currentContext"), gs=NSSelectorFromString(@"getService:"), gl=NSSelectorFromString(@"GetSessionInfoList");
    if (!ctx||!mgrClass||![ctx respondsToSelector:cur]) return @[];
    id context=((id(*)(id,SEL))objc_msgSend)(ctx,cur); id center=WCZZValue(context,@"serviceCenter");
    if (!center||![center respondsToSelector:gs]) return @[];
    id mgr=((id(*)(id,SEL,Class))objc_msgSend)(center,gs,mgrClass);
    if (!mgr||![mgr respondsToSelector:gl]) return @[];
    id list=((id(*)(id,SEL))objc_msgSend)(mgr,gl);
    return [list isKindOfClass:[NSArray class]]?list:@[];
}
static void WCZZClearUnreadName(NSString *u) {
    if (!u.length) return;
    Class ctx=objc_getClass("MMContext"), mgrClass=objc_getClass("MMNewSessionMgr");
    SEL cur=NSSelectorFromString(@"currentContext"), gs=NSSelectorFromString(@"getService:"), cl=NSSelectorFromString(@"ChangeSessionUnReadCount:to:");
    if (!ctx||!mgrClass||![ctx respondsToSelector:cur]) return;
    id context=((id(*)(id,SEL))objc_msgSend)(ctx,cur); id center=WCZZValue(context,@"serviceCenter");
    id mgr=(center&&[center respondsToSelector:gs])?((id(*)(id,SEL,Class))objc_msgSend)(center,gs,mgrClass):nil;
    if (mgr&&[mgr respondsToSelector:cl]) { @try { ((void(*)(id,SEL,id,unsigned int))objc_msgSend)(mgr,cl,u,0U); } @catch (...) {} }
}

#pragma mark - Group helper UI
@class WCZZCommonRoomsViewController;
static void WCZZReloadMainList(void);

@interface WCZZGroupHelperViewController : UITableViewController
@property(nonatomic,weak) id mainController;
@property(nonatomic,strong) NSArray *sessions;
@end
@implementation WCZZGroupHelperViewController
- (void)viewDidLoad { [super viewDidLoad]; self.title=@"群助手"; self.tableView.tableFooterView=[UIView new]; self.tableView.rowHeight=60; self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(wczzMore)]; }
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; NSMutableArray *a=[NSMutableArray array]; for(id s in WCZZSessionList()) if(WCZZShouldFold(s)) [a addObject:s]; self.sessions=a; [self.tableView reloadData]; }
- (void)wczzMore {
    UIAlertController *a=[UIAlertController alertControllerWithTitle:nil message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:@"一键已读" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *x){ NSArray *ss=[self.sessions copy]; for(id s in ss) WCZZClearUnreadName(WCZZUsername(s)); [self viewWillAppear:NO]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"管理常用群" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *x){ WCZZCommonRoomsViewController *v=[WCZZCommonRoomsViewController new]; [self.navigationController pushViewController:v animated:YES]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return s==0?(NSInteger)self.sessions.count:0; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip { static NSString *I=@"wczz.g"; UITableViewCell *c=[tv dequeueReusableCellWithIdentifier:I]; if(!c)c=[[UITableViewCell alloc]initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:I]; if(ip.row<self.sessions.count){id s=self.sessions[ip.row]; c.textLabel.text=WCZZDisplayName(WCZZContact(s)); unsigned long n=[WCZZValue(s,@"m_uUnReadCount") unsignedLongValue]; c.detailTextLabel.text=n?[NSString stringWithFormat:@"%lu 条未读",n]:@""; c.accessoryType=UITableViewCellAccessoryDisclosureIndicator;} return c; }
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip { [tv deselectRowAtIndexPath:ip animated:YES]; if(ip.row>=self.sessions.count)return; id s=self.sessions[ip.row]; id vc=self.mainController; SEL open=NSSelectorFromString(@"onLogicOpenSession:"); if(vc&&[vc respondsToSelector:open]) { @try { ((void(*)(id,SEL,id))objc_msgSend)(vc,open,s); } @catch (...) {} } }
@end

@interface WCZZCommonRoomsViewController : UITableViewController
@property(nonatomic,strong) NSArray *groups;
@property(nonatomic,strong) NSMutableSet *selected;
@end
@implementation WCZZCommonRoomsViewController
- (void)viewDidLoad { [super viewDidLoad]; self.title=@"常用群"; self.tableView.tableFooterView=[UIView new]; self.selected=[NSMutableSet setWithArray:WCZZCommonRooms()]; NSMutableArray *a=[NSMutableArray array]; for(id s in WCZZSessionList()){NSString *u=WCZZUsername(s); if(u.length&&WCZZIsChatRoom(WCZZContact(s))) [a addObject:s];} self.groups=a; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s{return s==0?(NSInteger)self.groups.count:0;}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip { static NSString *I=@"wczz.c"; UITableViewCell *c=[tv dequeueReusableCellWithIdentifier:I]; if(!c)c=[[UITableViewCell alloc]initWithStyle:UITableViewCellStyleDefault reuseIdentifier:I]; if(ip.row<self.groups.count){id s=self.groups[ip.row];NSString *u=WCZZUsername(s);c.textLabel.text=WCZZDisplayName(WCZZContact(s));c.accessoryType=[self.selected containsObject:u]?UITableViewCellAccessoryCheckmark:UITableViewCellAccessoryNone;}return c; }
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip { if(ip.row>=self.groups.count)return;NSString *u=WCZZUsername(self.groups[ip.row]);if(!u.length)return;if([self.selected containsObject:u])[self.selected removeObject:u];else[self.selected addObject:u];WCZZSetCommonRooms(self.selected.allObjects);[tv reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];WCZZReloadMainList(); }
@end

#pragma mark - Settings
@interface WCZZSettingsViewController : UITableViewController @end
@implementation WCZZSettingsViewController
- (instancetype)init:(id)__unused model{return [super initWithStyle:UITableViewStyleGrouped];}
- (void)viewDidLoad{[super viewDidLoad];self.title=@"wczz";self.tableView.tableFooterView=[UIView new];}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s{return s==0?5:0;}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip{static NSString *I=@"wczz.s";UITableViewCell*c=[tv dequeueReusableCellWithIdentifier:I];if(!c)c=[[UITableViewCell alloc]initWithStyle:UITableViewCellStyleDefault reuseIdentifier:I];c.accessoryView=nil;c.accessoryType=UITableViewCellAccessoryNone;if(ip.row<=3){UISwitch*w=[UISwitch new];w.tag=99+ip.row;w.on=ip.row==0?WCZZEnabled():ip.row==1?WCZZBool(WCZZGroupEnabledKey,YES):ip.row==2?WCZZBool(WCZZGroupTopKey,YES):WCZZBool(WCZZRedDetailKey,YES);[w addTarget:self action:@selector(wczzSwitch:) forControlEvents:UIControlEventValueChanged];c.accessoryView=w;c.textLabel.text=ip.row==0?@"启用 wczz":ip.row==1?@"开启群助手":ip.row==2?@"置顶群助手":@"红包详情";}else{c.textLabel.text=@"常用群";c.accessoryType=UITableViewCellAccessoryDisclosureIndicator;}return c;}
- (void)wczzSwitch:(UISwitch*)w{if(w.tag==99)WCZZSetBool(WCZZPluginEnabledKey,w.on);else if(w.tag==100)WCZZSetBool(WCZZGroupEnabledKey,w.on);else if(w.tag==101)WCZZSetBool(WCZZGroupTopKey,w.on);else if(w.tag==102)WCZZSetBool(WCZZRedDetailKey,w.on);WCZZReloadMainList();}
- (void)tableView:(UITableView*)tv didSelectRowAtIndexPath:(NSIndexPath*)ip{[tv deselectRowAtIndexPath:ip animated:YES];if(ip.row<=3){UISwitch*w=(UISwitch*)[tv cellForRowAtIndexPath:ip].accessoryView;if([w isKindOfClass:[UISwitch class]]){[w setOn:!w.on animated:YES];[self wczzSwitch:w];}}else if(ip.row==4){[self.navigationController pushViewController:[WCZZCommonRoomsViewController new] animated:YES];}}
@end

#pragma mark - Runtime hook installer
static IMP WCZZOrigLogicCount;
static IMP WCZZOrigLogicCell;
static IMP WCZZOrigLogicSession;
static IMP WCZZOrigSelect;
static IMP WCZZOrigReload;
static IMP WCZZOrigRedRefresh;
static IMP WCZZOrigRedAppear;
static BOOL WCZZHooksInstalled=NO;
static BOOL WCZZRedHooksInstalled=NO;

static id WCZZLogic(id vc){return WCZZValue(vc,@"m_mainFrameLogicController");}
static id WCZZCallOrigSession(id self, NSIndexPath *ip){ return WCZZOrigLogicSession?((id(*)(id,SEL,id))WCZZOrigLogicSession)(self,NSSelectorFromString(@"logicGetSessionAtIndexPath:"),ip):nil; }
static id WCZZCallOrigCell(id self, NSIndexPath *ip){ return WCZZOrigLogicCell?((id(*)(id,SEL,id))WCZZOrigLogicCell)(self,NSSelectorFromString(@"logicGetCellDataAtIndexPath:"),ip):nil; }
static long long WCZZOriginalLogicCount(id self,long long sec){ return WCZZOrigLogicCount?((long long(*)(id,SEL,long long))WCZZOrigLogicCount)(self,NSSelectorFromString(@"logicGetCountForSection:"),sec):0; }
static NSArray *WCZZVisibleOriginalRows(id self,long long originalCount){ NSMutableArray *rows=[NSMutableArray array]; for(NSInteger i=0;i<originalCount;i++){NSIndexPath*ip=[NSIndexPath indexPathForRow:i inSection:0];id s=WCZZCallOrigSession(self,ip);if(!WCZZShouldFold(s))[rows addObject:@(i)];}return rows; }
static BOOL WCZZIsHelperRow(id self,NSIndexPath *ip,NSArray *rows){if(!ip||ip.section!=0||!WCZZEnabled()||!WCZZBool(WCZZGroupEnabledKey,YES)||rows.count==0)return NO;BOOL top=WCZZBool(WCZZGroupTopKey,YES);return (top&&ip.row==0)||(!top&&ip.row==rows.count);}

static long long WCZZNewLogicCount(id self,SEL _cmd,long long sec){long long original=WCZZOriginalLogicCount(self,sec);if(sec!=0||!WCZZEnabled()||!WCZZBool(WCZZGroupEnabledKey,YES)||original<=0)return original;NSArray*rows=WCZZVisibleOriginalRows(self,original);if(rows.count==(NSUInteger)original)return original;return (long long)rows.count+1;}
static id WCZZNewLogicSession(id self,SEL _cmd,id obj){NSIndexPath*ip=(NSIndexPath*)obj;if(![ip isKindOfClass:[NSIndexPath class]]||ip.section!=0||!WCZZEnabled()||!WCZZBool(WCZZGroupEnabledKey,YES))return WCZZCallOrigSession(self,ip);long long original=WCZZOriginalLogicCount(self,0);NSArray*rows=WCZZVisibleOriginalRows(self,original);if(WCZZIsHelperRow(self,ip,rows))return nil;NSUInteger vi=WCZZBool(WCZZGroupTopKey,YES)?(ip.row?ip.row-1:NSUIntegerMax):ip.row;if(vi>=rows.count)return WCZZCallOrigSession(self,ip);NSIndexPath*orig=[NSIndexPath indexPathForRow:[rows[vi] integerValue] inSection:0];return WCZZCallOrigSession(self,orig);}
static id WCZZNewLogicCell(id self,SEL _cmd,id obj){NSIndexPath*ip=(NSIndexPath*)obj;if(![ip isKindOfClass:[NSIndexPath class]]||ip.section!=0||!WCZZEnabled()||!WCZZBool(WCZZGroupEnabledKey,YES))return WCZZCallOrigCell(self,ip);long long original=WCZZOriginalLogicCount(self,0);NSArray*rows=WCZZVisibleOriginalRows(self,original);if(WCZZIsHelperRow(self,ip,rows)){Class c=objc_getClass("FakeMainFrameCellData");if(!c)return nil;id fake=((id(*)(id,SEL))objc_msgSend)(c,NSSelectorFromString(@"alloc"));fake=((id(*)(id,SEL))objc_msgSend)(fake,NSSelectorFromString(@"init"));if([fake respondsToSelector:NSSelectorFromString(@"setUserName:")])((void(*)(id,SEL,id))objc_msgSend)(fake,NSSelectorFromString(@"setUserName:"),WCZZGroupUserName);if([fake respondsToSelector:NSSelectorFromString(@"setTextForNameLabel:")])((void(*)(id,SEL,id))objc_msgSend)(fake,NSSelectorFromString(@"setTextForNameLabel:"),@"群助手");if([fake respondsToSelector:NSSelectorFromString(@"setTextForMessageLabel:")])((void(*)(id,SEL,id))objc_msgSend)(fake,NSSelectorFromString(@"setTextForMessageLabel:"),[NSString stringWithFormat:@"%lu 个群聊",(unsigned long)(original-(long long)rows.count)]);if([fake respondsToSelector:NSSelectorFromString(@"setTextForTimeLabel:")])((void(*)(id,SEL,id))objc_msgSend)(fake,NSSelectorFromString(@"setTextForTimeLabel:"),@"");if([fake respondsToSelector:NSSelectorFromString(@"setBTopCell:")])((void(*)(id,SEL,BOOL))objc_msgSend)(fake,NSSelectorFromString(@"setBTopCell:"),WCZZBool(WCZZGroupTopKey,YES));if([fake respondsToSelector:NSSelectorFromString(@"setBNormalCell:")])((void(*)(id,SEL,BOOL))objc_msgSend)(fake,NSSelectorFromString(@"setBNormalCell:"),!WCZZBool(WCZZGroupTopKey,YES));return fake;}NSUInteger vi=WCZZBool(WCZZGroupTopKey,YES)?(ip.row?ip.row-1:NSUIntegerMax):ip.row;if(vi>=rows.count)return WCZZCallOrigCell(self,ip);NSIndexPath*orig=[NSIndexPath indexPathForRow:[rows[vi] integerValue] inSection:0];return WCZZCallOrigCell(self,orig);}
static void WCZZNewSelect(id self,SEL _cmd,id table,id obj){NSIndexPath*ip=(NSIndexPath*)obj;if([ip isKindOfClass:[NSIndexPath class]]&&ip.section==0&&WCZZEnabled()&&WCZZBool(WCZZGroupEnabledKey,YES)){long long original=WCZZOriginalLogicCount(self,0);NSArray*rows=WCZZVisibleOriginalRows(self,original);if(WCZZIsHelperRow(self,ip,rows)){[(UITableView*)table deselectRowAtIndexPath:ip animated:YES];WCZZGroupHelperViewController*v=[WCZZGroupHelperViewController new];v.mainController=self;[self.navigationController pushViewController:v animated:YES];return;}}if(WCZZOrigSelect)((void(*)(id,SEL,id,id))WCZZOrigSelect)(self,_cmd,table,obj);}

static void WCZZInstallOne(Class cls,SEL sel,IMP repl,IMP *orig){
    if(!cls||!sel||!repl||!orig||*orig)return;
    Method m=class_getInstanceMethod(cls,sel);
    if(!m)return;
    Class super=class_getSuperclass(cls);
    Method sm=super?class_getInstanceMethod(super,sel):NULL;
    if(sm==m){
        const char *types=method_getTypeEncoding(m);
        if(!class_addMethod(cls,sel,repl,types))return;
        m=class_getInstanceMethod(cls,sel);
    }
    *orig=method_getImplementation(m);
    method_setImplementation(m,repl);
}
static void WCZZInstallHooks(void){
    Class c=objc_getClass("NewMainFrameViewController");
    Class r=objc_getClass("WCRedEnvelopesRedEnvelopesDetailViewController");
    if(!WCZZHooksInstalled&&c){
        WCZZInstallOne(c,NSSelectorFromString(@"logicGetCountForSection:"),(IMP)WCZZNewLogicCount,&WCZZOrigLogicCount);
        WCZZInstallOne(c,NSSelectorFromString(@"logicGetCellDataAtIndexPath:"),(IMP)WCZZNewLogicCell,&WCZZOrigLogicCell);
        WCZZInstallOne(c,NSSelectorFromString(@"logicGetSessionAtIndexPath:"),(IMP)WCZZNewLogicSession,&WCZZOrigLogicSession);
        WCZZInstallOne(c,NSSelectorFromString(@"tableView:didSelectRowAtIndexPath:"),(IMP)WCZZNewSelect,&WCZZOrigSelect);
        if(WCZZOrigLogicCount&&WCZZOrigLogicCell&&WCZZOrigLogicSession&&WCZZOrigSelect)WCZZHooksInstalled=YES;
    }
    if(!WCZZRedHooksInstalled&&r){
        WCZZInstallOne(r,NSSelectorFromString(@"refreshViewWithData:"),(IMP)WCZZRedRefresh,&WCZZOrigRedRefresh);
        WCZZInstallOne(r,NSSelectorFromString(@"viewDidAppear:"),(IMP)WCZZRedAppear,&WCZZOrigRedAppear);
        if(WCZZOrigRedRefresh&&WCZZOrigRedAppear)WCZZRedHooksInstalled=YES;
    }
}

static void WCZZReloadMainList(void){dispatch_async(dispatch_get_main_queue(),^{Class c=objc_getClass("NewMainFrameViewController");if(!c)return;for(UIWindowScene*scene in UIApplication.sharedApplication.connectedScenes){if(scene.activationState==UISceneActivationStateUnattached)continue;for(UIWindow*w in scene.windows){UIViewController*root=w.rootViewController;if(!root)continue;NSMutableArray*stack=[NSMutableArray arrayWithObject:root];while(stack.count){UIViewController*v=stack.lastObject;[stack removeLastObject];if([v isKindOfClass:c]){SEL s=NSSelectorFromString(@"reloadSessions");if([v respondsToSelector:s])@try{((void(*)(id,SEL))objc_msgSend)(v,s);} @catch(...){}return;}if(v.presentedViewController)[stack addObject:v.presentedViewController];for(UIViewController*x in v.childViewControllers)[stack addObject:x];if(v.navigationController&&v.navigationController!=v)[stack addObject:v.navigationController];}}}});}

#pragma mark - Red detail (current WeChat)
static void WCZZApplyRed(id vc){if(!WCZZEnabled()||!WCZZBool(WCZZRedDetailKey,YES)||!vc)return;id info=WCZZValue(vc,@"m_oWCRedEnvelopesDetailInfo");id label=WCZZValue(vc,@"m_receivedInfoLable");if(!info||![label isKindOfClass:[UILabel class]])return;long long a=[WCZZValue(info,@"m_lTotalAmount") longLongValue],n=[WCZZValue(info,@"m_lTotalNum") longLongValue],rn=[WCZZValue(info,@"m_lRecNum") longLongValue],ra=[WCZZValue(info,@"m_lRecAmount") longLongValue];if(a<=0&&n<=0&&rn<=0&&ra<=0)return;((UILabel*)label).text=[NSString stringWithFormat:@"共 %.2f 元 · %lld 人 · 已领取 %lld 人 / %.2f 元",a/100.0,n,rn,ra/100.0];}
static void WCZZRedRefresh(id self,SEL _cmd,id data){if(WCZZOrigRedRefresh)((void(*)(id,SEL,id))WCZZOrigRedRefresh)(self,_cmd,data);dispatch_async(dispatch_get_main_queue(),^{WCZZApplyRed(self);});}
static void WCZZRedAppear(id self,SEL _cmd,BOOL animated){if(WCZZOrigRedAppear)((void(*)(id,SEL,BOOL))WCZZOrigRedAppear)(self,_cmd,animated);dispatch_async(dispatch_get_main_queue(),^{WCZZApplyRed(self);dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.35*NSEC_PER_SEC)),dispatch_get_main_queue(),^{WCZZApplyRed(self);});});}

#pragma mark - Plugin manager
static BOOL WCZZRegistered=NO;static void WCZZRegister(void){if(WCZZRegistered)return;Class c=objc_getClass("WCPluginsMgr");SEL s=NSSelectorFromString(@"sharedInstance"),r=NSSelectorFromString(@"registerControllerWithTitle:version:controller:");if(!c||![c respondsToSelector:s])return;id m=((id(*)(id,SEL))objc_msgSend)(c,s);if(!m||![m respondsToSelector:r])return;((void(*)(id,SEL,id,id,id))objc_msgSend)(m,r,@"wczz",@"1.0-0",@"WCZZSettingsViewController");WCZZRegistered=YES;}

%ctor { @autoreleasepool { NSUserDefaults*d=[NSUserDefaults standardUserDefaults];if([d objectForKey:WCZZPluginEnabledKey]==nil)[d setBool:YES forKey:WCZZPluginEnabledKey];if([d objectForKey:WCZZGroupEnabledKey]==nil)[d setBool:YES forKey:WCZZGroupEnabledKey];if([d objectForKey:WCZZGroupTopKey]==nil)[d setBool:YES forKey:WCZZGroupTopKey];if([d objectForKey:WCZZRedDetailKey]==nil)[d setBool:YES forKey:WCZZRedDetailKey];if([d objectForKey:WCZZCommonRoomsKey]==nil)[d setObject:@[] forKey:WCZZCommonRoomsKey];[d synchronize];dispatch_async(dispatch_get_main_queue(),^{WCZZRegister();WCZZInstallHooks();for(double t=0.5;t<=10;t+=0.5)dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(t*NSEC_PER_SEC)),dispatch_get_main_queue(),^{WCZZRegister();WCZZInstallHooks();});});}}
