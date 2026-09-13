# wczz 1.0-32

Independent WeChat 8.0.75 tweak.

## 1.0-27 changes
- Main session filtering moved to NewMainFrameViewController logicGetCountForSection / logicGetSessionAtIndexPath / logicGetCellDataAtIndexPath / handleSelectIndexPath, which is the table-facing data boundary in WeChat 8.0.75.
- Removed the previous MainFrameLogicController logical-row hook path to avoid a hook that can be installed successfully but never be queried by the main table.
- Main session list is explicitly reloaded after hook installation and on main VC appearance/session rebuild.
- Only usernames ending in @chatroom are candidates; common groups stay in the normal list.
- Group helper uses native MMBaseSessionTableViewCell when available.
- Red-envelope hooks now cover both receive initializers and the base showDetailView path, and retry locating the detail label after view creation.
- No WeChat native foldSession/foldSessionByNames calls.


## 1.0-27 修正
- 主列表过滤恢复到 WeChat 8.0.75 实际使用的 MainFrameLogicController 数据边界。
- 仅过滤 `@chatroom` 且不在常用群白名单中的会话。
- 群助手行通过 FakeMainFrameCellData 接入微信原生会话列表。
- 红包统计改为独立顶部覆盖 UILabel，不修改微信原有的 `m_receivedInfoLable`，因此不会覆盖“谁发的红包”和金额。


## 1.0-27 修正
- 修复 WeChat 8.0.75 中 getSessionInfoAtIndexPath: 返回 nil 导致群助手永远无法识别群聊的问题。现在依次从 session info、cell data 的 userName、MMNewSessionMgr 的 GetSessionInfoList 恢复会话用户名。
- 增加 getSessionBaseInfoAtIndexPath: 的同一行映射。
- 红包四行统计保持独立顶部 UILabel，不再修改微信原生发红包人/金额内容。统计位置上移到红色顶部区域，并增加高度确保四行完整显示。
