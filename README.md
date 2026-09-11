# wczz 1.0-0

Rootless Theos tweak for WeChat 8.0.78-era headers.

## Included behavior
- MiYou-derived group helper concept: chat-room sessions are folded into a synthetic “群消息” row while configured “常用群” remain in the main list.
- Group helper page with only two `+` actions: `一键已读` and `管理常用群`.
- One-click read uses the current WeChat `MMContext -> MMServiceCenter -> MMNewSessionMgr -> ChangeSessionUnReadCount:to:` path rather than MiYou's obsolete/private selector.
- MiYou-derived red-detail enhancement adapted to current `WCRedEnvelopesReceiveControlLogic` and `WCRedEnvelopesDetailInfo` fields.
- Plugin-manager registration via `WCPluginsMgr`, including a master enable switch.
- No message-clear or delete actions are registered in the group-helper menu.

## Important
The source is a behavioral reimplementation based on static analysis of the supplied MiYou binary and adaptation to the supplied WeChat headers. It is not byte-for-byte recovered original source.

The supplied crash log's crashing frame was in `MiYou.dylib` (`addIMBehaviorContactOp:contactOpType:`); `wczz.dylib` was absent from that process's loaded-image list, so that crash cannot be attributed to wczz.

## Build
Install Theos and run:

```sh
make clean package FINALPACKAGE=1
```

Rootless packaging is selected by `THEOS_PACKAGE_SCHEME=rootless` in the Makefile.


## v2 排查修复
- 强化主会话列表来源：优先使用 `getLastFrontSessionArray`。
- 增加当前微信会话列表相关入口的兼容 Hook，避免只 Hook filtered/fake cell 导致群助手不进入实际列表数据路径。
- 插件管理只注册 `wczz` 设置控制器，不注册独立总开关。
- 不再向微信原生设置页添加右上角入口。
- 增加启动日志 `[wczz] loaded into WeChat`，便于确认 dylib 是否真正注入。
