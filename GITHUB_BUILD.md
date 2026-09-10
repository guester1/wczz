# GitHub Actions build

This project is intended to be built by GitHub Actions on `macos-latest` so the Xcode toolchain can produce the arm64e-compatible iOS tweak. The workflow is at `.github/workflows/build.yml`.

On GitHub: **Actions → Build wczz dylib → Run workflow**.

The successful run uploads `wczz.dylib` as the `wczz-dylib` artifact.

The project uses Theos Rootless (`THEOS_PACKAGE_SCHEME=rootless`) and iOS 15.0 as the deployment target. Theos documents that Rootless uses `/var/jb`, `@rpath`, and the `iphoneos-arm64` package architecture, and notes that GitHub Actions is a supported way to obtain the macOS/Xcode toolchain for arm64e builds.

This workflow builds the source; it does not claim that the tweak has been tested on a real jailbroken device. Runtime validation still requires the target WeChat build and device.
