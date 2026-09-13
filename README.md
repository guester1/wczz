# wczz 1.0-33

Independent WeChat 8.0.75 group assistant tweak.

## Group Assistant behavior
- Only usernames ending with `@chatroom` are eligible for folding. Friends and other non-group sessions are never folded.
- Groups in the “常用群” whitelist remain in the normal WeChat session list.
- Other group chats are removed from the normal homepage data boundary and represented by exactly one “群助手” row.
- “群助手” uses the native `MMBaseSessionTableViewCell`/`MMBaseSessionCellData` path, with a blue envelope icon, total unread count, latest folded-group message, and latest time.
- Opening “群助手” shows only the folded groups, using native WeChat session cells and sorted by latest message time.
- Opening a group from the assistant calls the original WeChat session-opening path.
- The main-list helper data is not returned through `MainFrameLogicController`’s normal cell-data boundary, avoiding a `MMBaseSessionCellData`/`MainFrameCellData` type mismatch.

## 1.0-33 fixes
- Resolve sessions by exact username through `MMNewSessionMgr GetSessionByUserName:` before using positional fallback, reducing row-index misclassification.
- Keep the folding predicate strict: `@chatroom` + not in common-group whitelist.
- Select the newest folded group for the helper row preview instead of the first folded row.
- Remove an existing native `[N条]` prefix before adding the aggregate unread count, preventing duplicated counts such as `[653条] [446条] ...`.
- Keep native helper-cell rendering isolated to the table-cell boundary; logical cell-data APIs return `nil` for the synthetic helper row.
- Preserve native group cells inside the assistant page.

## Compatibility
- Target: WeChat 8.0.75
- Minimum iOS: 15.0
- Architectures: arm64 / arm64e
