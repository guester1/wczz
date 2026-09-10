# wczz 1.0-0

Independent reimplementation of the supplied MiYou 3.9-5 rootless WeChat tweak behavior, limited to Group Helper and Red Detail. WCRefine is not used.

## Build

Requires Theos + an iOS SDK. This repository is source-only; no prebuilt dylib is included.

    make clean
    make

The target is a rootless iPhoneOS dylib named `wczz.dylib`.

The supplied MiYou binary was used only for static behavioral reconstruction. The exact original source cannot be recovered byte-for-byte from a compiled/obfuscated binary.
