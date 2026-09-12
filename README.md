# wczz v1.0-5

Independent implementation for WeChat 8.0.75.

## Design

- Does not reuse Miyou's folding implementation.
- Uses WeChat 8.0.75's native session-folding engine as the row/index/cell engine.
- Only usernames ending in `@chatroom` are eligible for wczz folding.
- Friends and every non-group session are explicitly kept out of wczz folding.
- Common groups remain in the normal session list.
- Non-common groups are folded into a single native fake-cell entry named `群助手`.
- The helper entry is controlled through the native fake-cell `bTopCell` flag.
- Tapping `群助手` opens the independent group list.
- Tapping a collected group opens the original WeChat session through `onLogicOpenSession:`.
- Settings are registered through `WCPluginsMgr` when available.
- Red-envelope detail summary remains independent of the group-list implementation.

## Main-list strategy

v1.0-5 intentionally does **not** replace `UITableView` row counts or cells.
It hooks:

- `MMNewSessionMgr shouldFoldSession:`
- `MainFrameLogicController fold/get-fake-cell lifecycle`
- `NewMainFrameViewController onLogicOpenSession:`

This lets WeChat itself keep ownership of row counts, index paths, cell creation,
selection, and reload behavior.
