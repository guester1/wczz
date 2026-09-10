# Build notes

Rootless build:

    export THEOS=/path/to/theos
    make clean
    make

For a release package, Theos can package the same target, but this project is intended to be consumed as the resulting `wczz.dylib` plus `wczz.plist`.

Theos rootless sets the install prefix/rpaths and package architecture automatically when `THEOS_PACKAGE_SCHEME=rootless` is enabled.
