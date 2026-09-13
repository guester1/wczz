# wczz 1.0-13

Independent WeChat 8.0.75 tweak.

## 1.0-13 changes
- Main session filtering moved to NewMainFrameViewController logicGetCountForSection / logicGetSessionAtIndexPath / logicGetCellDataAtIndexPath / handleSelectIndexPath, which is the table-facing data boundary in WeChat 8.0.75.
- Removed the previous MainFrameLogicController logical-row hook path to avoid a hook that can be installed successfully but never be queried by the main table.
- Main session list is explicitly reloaded after hook installation and on main VC appearance/session rebuild.
- Only usernames ending in @chatroom are candidates; common groups stay in the normal list.
- Group helper uses native MMBaseSessionTableViewCell when available.
- Red-envelope hooks now cover both receive initializers and the base showDetailView path, and retry locating the detail label after view creation.
- No WeChat native foldSession/foldSessionByNames calls.
