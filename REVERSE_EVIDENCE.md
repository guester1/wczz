# Reverse-engineering evidence

The implementation is based on the supplied MiYou 3.9-5 rootless binary and the supplied current WeChat headers. WCRefine is not used.

Confirmed MiYou evidence:
- GroupTool contains RoomList/BrandList/FriendList/sessionList/filterSessionList/sessionDataList and related setters.
- GroupTool exposes createSessionWithUserName:nickName:showRedDot:readAsRedDot:.
- MiYou references FakeMainFrameCellData and FakeMainFrameCell/FakeMainFrameItemView updateContentView paths.
- MiYou settings contain settingOpenRoomEnable:, settingIsHelperTop:, settingIconType and showFilterVC.
- MiYou red-detail code reads m_oWCRedEnvelopesDetailInfo and m_lTotalAmount/m_lTotalNum/m_lRecNum/m_lRecAmount; total amount is converted from cents by dividing by 100.
- MiYou calls startReceiveRedEnvelopesLogic:Data: on a service returned by LMUtils getService:.

Important limitation:
The supplied binary is stripped/obfuscated. Exact original source and every runtime insertion point cannot be recovered statically. The code therefore uses the strongest matching current-WeChat APIs and dynamic runtime checks rather than pretending an unverified hook is exact.
