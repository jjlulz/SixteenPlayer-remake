export ARCHS = arm64 arm64e
export TARGET = iphone:clang:latest:12.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SixteenPlayer
SixteenPlayer_FILES = Tweak.xm
SixteenPlayer_CFLAGS = -fobjc-arc
SixteenPlayer_FRAMEWORKS = UIKit QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
