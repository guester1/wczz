# wczz 1.0-0

Rootless iOS jailbreak tweak for WeChat 8.0.78-era headers.

Features:
- Group Helper: non-common chatrooms are folded into a synthetic Group Helper row; common groups remain in the normal WeChat chat list.
- Group Helper opens a list of the folded groups.
- One-click read clears unread counts through MMNewSessionMgr::ChangeSessionUnReadCount:to:.
- Group Helper top toggle.
- Group Helper avatar selection setting (the renderer may use WeChat's fake-cell handling).
- Red-envelope detail header: total amount, total count, remaining count, remaining amount.

Implementation notes:
- Main-list folding is hooked at MainFrameLogicController session/cell-data level.
- FakeMainFrameCellData is used for the synthetic Group Helper row.
- Red-envelope data is read from WCRedEnvelopesControlData.m_oWCRedEnvelopesDetailInfo passed to refreshViewWithData:.
- No runtime dependency on other tweaks.
