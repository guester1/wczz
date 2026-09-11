# wczz 1.0-0 v14

独立实现群助手与红包详情。MiYou 仅作为行为逆向依据；运行时不加载、不链接、不读取 MiYou。WCR/WCRefine 不参与。

本版不依赖 Logos `%hook` 在 dylib 构造阶段立即找到微信类，而是主线程启动后重复检查并使用 Objective-C runtime `method_setImplementation` 安装 Hook，解决“设置页存在但功能全部不生效”的典型类尚未加载问题。

主列表使用当前 WeChat 明确存在的 `NewMainFrameViewController` 逻辑边界：`logicGetCountForSection:`, `logicGetCellDataAtIndexPath:`, `logicGetSessionAtIndexPath:`，并只在 `tableView:didSelectRowAtIndexPath:` 拦截虚拟群助手行。正常聊天交给微信原始逻辑。

群助手虚拟行使用微信 `FakeMainFrameCellData`。常用群来自 `MMNewSessionMgr`。一键已读只调用 `ChangeSessionUnReadCount:to:`，不 reload。菜单只有“一键已读 / 管理常用群 / 取消”，没有清空聊天记录或删除所有消息。

红包详情针对当前 WeChat `WCRedEnvelopesRedEnvelopesDetailViewController`，观察 `refreshViewWithData:` 与 `viewDidAppear:`，从 `m_oWCRedEnvelopesDetailInfo` 读取金额/人数。
