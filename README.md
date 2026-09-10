# wczz 1.0-0

Standalone WeChat tweak implementing the two requested MiYou-derived functions:

- 群助手: fold non-common group sessions into a `群消息` entry, with a separate group list page and common-group whitelist.
- 红包详情: use the current WeChat red-envelope detail objects and confirmed amount/count fields to present the collected/total summary.

The project does **not** depend on WCRefine.

## Files

- `Tweak.xm` — implementation
- `WeChatCompat.h` — compile-time declarations for private WeChat classes
- `Makefile` — rootless Theos build
- `wczz.plist` — injection filter for `com.tencent.xin` / `WeChat`
- `control` — package metadata
- `.github/workflows/build.yml` — GitHub Actions build
- `REVERSE_EVIDENCE.md` — evidence and confidence notes

## Runtime caveat

The source can be checked for compile-time correctness and built in CI, but no one can honestly guarantee device runtime behavior without testing against the exact WeChat binary and jailbreak environment. The group-cell integration and red-detail presentation are adaptations to the supplied current WeChat headers; the MiYou binary does not expose original source code.
