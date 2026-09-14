# wczz v1.0-32 / v61-no-miyou

基于 v60 继续修正群助手收纳逻辑。

本版重点：
1. 非常用 `@chatroom` 继续从主会话逻辑列表中过滤，只保留在群助手。
2. 常用群不收纳，继续显示在微信主页。
3. 群助手插入在第一个正常可见会话之后（置顶开启时）。
4. 增加对已折叠群 username 的硬过滤：`indexPathOfSessionUserName:` 不再把已收纳群解析回主页位置。
5. Debug 开启时记录最多前 12 个被收纳群 username，便于确认实际过滤对象。
6. 群助手继续使用真实折叠群作为内部 backing session，避免 nil session 导致闪退。
7. 不加入手势，不依赖 miyou，不修改红包逻辑。

注意：当前环境没有用户的 Theos/iOS SDK，因此没有声称已经实际 `make package` 编译通过；这里完成的是源码静态检查和逻辑修正。
