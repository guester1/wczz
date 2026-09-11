# wczz 1.0-0

Independent WeChat tweak implementing the requested group helper and red-envelope detail features.

## Important fix in this revision
The previous build installed Logos hooks during dylib initialization. On some WeChat startup paths the target classes are not registered yet, so `MSHookMessageEx` received a nil class and the tweak loaded but the features had no effect. This revision puts the WeChat hooks in explicit Logos groups and initializes them only after the target classes exist, retrying until both hooks and plugin registration are ready.

Main-list behavior remains at the table-data boundary, with session lookup through `m_mainFrameLogicController` / `getSessionInfoAtIndexPath:`. One-click read uses `MMNewSessionMgr` / `ChangeSessionUnReadCount:to:` with unread count 0.
