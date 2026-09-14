# wczz v59-no-miyou

Base: wczz 1.0-32 / v55, WeChat iOS 8.0.75.

This version is intended to be tested with the `miyou` tweak removed.

Changes focused on the broken 群助手 logical-session path:
- Keep @chatroom folding and main-list unread-count sorting.
- Keep folded original row numbers unchanged.
- Keep 群助手 native MMBaseSessionTableViewCell / MMBaseSessionCellData rendering path.
- Provide a synthetic `MMBaseSessionInfo` for the `wczz_group_helper` row instead of returning nil.
- Map `wczz_group_helper` in `indexPathOfSessionUserName:` and `indexInAllVisibleSessions:`.
- Return the helper session info from `logicGetSessionAtIndexPath:`.
- Prefer exact username lookup before positional fallback when resolving service sessions.
- No gesture recognizers are used.
- No miyou integration is included.

The source is kept as a Theos Logos `Tweak.xm` project. Logos `%hook/%orig` syntax follows Theos' documented syntax.
