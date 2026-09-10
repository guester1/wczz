# GitHub Actions build

This project is intended to be built with Theos on macOS/Xcode via GitHub Actions.

The workflow:
1. checks out the source;
2. installs the current Theos tree;
3. runs `make clean` and a release build;
4. verifies that `wczz.dylib` was produced;
5. prints its SHA-256 and uploads it as the `wczz-dylib` artifact.

The project uses Theos' rootless scheme. Theos documents that rootless packaging uses `/var/jb` and the package architecture `iphoneos-arm64`.

Important: a successful CI build proves compilation/linking only. Runtime behavior still needs to be tested in the target WeChat build on a compatible jailbroken device.
