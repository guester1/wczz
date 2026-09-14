# wczz 1.0-32 / v60-no-miyou

Target: WeChat iOS 8.0.75.

This revision is based on v59-no-miyou and specifically fixes the issues seen in the 2026-09-14 test:

1. Main list still folds non-common `@chatroom` sessions into one `群助手` row.
2. Common groups remain visible on the main list.
3. With `群助手置顶` enabled, the helper row is inserted after the first visible session, matching the supplied reference screenshot (`大号` first, then `群助手`).
4. The helper row no longer returns a synthetic/nil session object. Internal WeChat session lookups use the first folded real group as a backing session, preventing the selection crash.
5. Opening a folded backing session from the main list is redirected to `群助手`; when already inside `群消息`, normal session opening is allowed.
6. If WeChat cannot provide a native `MMBaseSessionCellData` template for the helper row, the tweak creates an `MMBaseSessionCellData` instance directly and fills its fields instead of returning nil.
7. Helper-page groups remain sorted by latest-message time descending.
8. No gesture recognizers and no miyou integration.

Build with the original Theos environment:

```sh
make clean
make package
```
