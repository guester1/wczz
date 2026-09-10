# Reverse-engineering evidence

## MiYou source of behavior

The implementation is based on static analysis of the supplied `微信助手_3.9-5_无根.deb`. No WCRefine code/API is used.

### GroupTool

Confirmed in MiYou metadata: `GroupTool` stores and filters room/session lists and exposes group-helper configuration state. Relevant methods include `filterRoomList`, `filterSessionList`, `setSessionList:`, `setFilterSessionList:`, `isOpenRoomEnable`, `isOpenRoomHelper`, `setIsOpenRoomHelper:`, and related list accessors.

MiYou settings metadata also confirms group-helper controls for enabling the feature, pinning it, choosing common groups, and choosing the helper icon.

### Session construction

MiYou's `createSessionWithUserName:nickName:showRedDot:readAsRedDot:` path constructs session information and associates a last message/read-count state. The supplied current WeChat headers expose the corresponding `MMSessionInfo` fields (`m_nsUserName`, `m_uUnReadCount`, `m_bShowUnReadAsRedDot`, `m_contact`, `m_msgWrap`).

### Current WeChat adaptation

The supplied current WeChat headers expose:

- `MainFrameLogicController` fake-cell APIs (`getFakeCellCount`, `getFakeCellData:`) and filtered-session APIs.
- `FakeMainFrameCellData` with username/name/message/top properties.
- `CContact +IsChatRoomContact:`.
- `NewMainFrameViewController` session navigation/reload methods.

The tweak uses these current APIs dynamically rather than assuming the old MiYou binary's private addresses are valid in the current WeChat.

## Red-envelope detail

MiYou references `m_oWCRedEnvelopesDetailInfo` and reads:

- `m_lTotalAmount`
- `m_lTotalNum`
- `m_lRecNum`
- `m_lRecAmount`

The amount values are treated as fen/cents and divided by 100. The current WeChat headers expose the same detail-info object through the red-envelope receive/detail flow.

## Confidence boundaries

The supplied binary is compiled code, not original source. Exact original source cannot be recovered byte-for-byte. The group-list behavior and red-detail data fields are evidence-based; the exact original UI hook and grouping implementation are not fully recoverable from the available metadata, so this project uses a current-WeChat adaptation.
