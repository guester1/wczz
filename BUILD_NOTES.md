# Build notes

- Target: WeChat (`com.tencent.xin` / executable `WeChat`)
- Package: `com.wczz`
- Version: `1.0-0`
- Scheme: Theos rootless
- Deployment target: iOS 15.0+
- Architectures: arm64 + arm64e
- No WCRefine dependency or WCRefine API is used.

## What was corrected in this revision

1. Added `WeChatCompat.h` with compile-time declarations for the four private WeChat classes referenced by Logos. This prevents the generated Logos Objective-C source from referring to undeclared private class types.
2. Added `<string.h>` because the source calls `strstr`.
3. Removed the extra `onMainSessionReload` hook; the current source only needs the confirmed `onSessionRebuildEnd` hook for refresh notification.
4. Kept every parameterized `%orig(...)` on its own statement, avoiding the Logos parser issue that caused the previous `Invalid argument structure in %orig` failure.
5. The GitHub workflow checks the actual generated `wczz.dylib` before uploading it.
