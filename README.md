# wczz 1.0-0

独立的 WeChat tweak，只实现两个目标功能：

- 群助手：收纳普通群聊、群助手入口、置顶、常用群、一键已读。
- 红包详情：在红包详情页显示总金额/总人数/已领取人数/已领取金额。

## 独立性

wczz 不依赖 MiYou 运行时，也不依赖 WCRefine/WCR。MiYou 3.9-5 仅作为行为/字符串证据来源；WeChat.zip 仅用于当前微信类和方法适配。

## 插件管理器

只注册一个 `WCZZSettingsViewController` 控制器入口，不注册插件管理器独立开关，也不修改微信原生设置入口。

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

## Important

本源码没有在真实设备上完成运行时验证。编译通过不等于特定微信版本一定命中所有运行时路径；v6 将主列表适配集中在 `NewMainFrameViewController` 的 `logicGetCountForSection:` / `logicGetCellDataAtIndexPath:` / `logicGetSessionAtIndexPath:` / `tableView:didSelectRowAtIndexPath:`，避免之前同时修改多个内部 session count/index API 导致的行号错位。
