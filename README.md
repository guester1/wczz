# wczz 1.0-0

独立的 WeChat tweak，只实现两个目标功能：

- **群助手**：收纳普通群聊、群助手入口、置顶、常用群、一键已读。
- **红包详情**：在红包详情页显示总金额、总人数、已领取人数、已领取金额。

## 独立性

wczz **不依赖 MiYou 运行时，也不依赖 WCRefine/WCR**。
MiYou 3.9-5 只用于静态行为/字符串证据；WeChat.zip 只用于当前微信类和方法适配。
所有开关、常用群名单和运行状态均由 wczz 自己保存。

## 群助手

主列表适配集中在当前微信 `NewMainFrameViewController` 的逻辑/表格路径：

- `logicGetCountForSection:`
- `logicGetCellDataAtIndexPath:`
- `logicGetSessionAtIndexPath:`
- `tableView:cellForRowAtIndexPath:`
- `tableView:didSelectRowAtIndexPath:`

正常微信行通过原始 session index 映射后继续交给微信自己的实现；群助手入口使用独立 cell，避免依赖 MiYou 的 FakeCell 实现。

群聊来源直接读取 `MMNewSessionMgr` 的 session 列表。常用群不进入收纳；取消常用群后重新归入收纳。

### 一键已读

一键已读只对当前群助手快照调用微信自己的：

`MMNewSessionMgr -> ChangeSessionUnReadCount:to:0`

不会在按钮回调里强制调用 `reloadSessions`，避免在群助手页面展示期间重新进入主列表 rebuild 路径导致闪退。

右上角菜单只有：

- 一键已读
- 管理常用群
- 取消

**没有“清空聊天记录”或“删除所有消息”。**

## 设置

插件管理器只注册 `WCZZSettingsViewController` 页面，不注册独立插件管理器开关，也不添加微信原生设置入口。

设置页：

1. 启用 wczz
2. 开启群助手
3. 置顶群助手
4. 红包详情
5. 常用群

## Build

```bash
make clean
make package
```

Target: iOS 15+, rootless, arm64/arm64e。

## 编译前审计

本版本已针对上一版出现的 `id.navigationController` 编译错误做了静态修正，并避免使用不存在的 `indexPathOfSessionUserName:` selector；原始 session index 由 wczz 自己扫描 `m_arrFilteredSession` 得到。

同时移除了会主动触发 `reloadSessions` 的旧一键已读路径和 `logicUpdateSession` / `onSessionRebuildEnd` reload 逻辑。
