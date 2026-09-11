TARGET := iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = WeChat

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = wczz

wczz_FILES = Tweak.xm
wczz_CFLAGS = -fobjc-arc -Wno-unicode-whitespace

include $(THEOS_MAKE_PATH)/tweak.mk
