export ARCHS = arm64
export TARGET = iphone:clang:latest:15.0
export THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = PddDump
PddDump_FILES = Tweak.x
PddDump_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
PddDump_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk

# 编译说明:
#   Theos rootless 工程,iOS 15.0+ (Dopamine / palera1n(rootless))
#   产物输出到 packages/PddDump_*.deb
#   运行截图手动兜底依赖系统通知,无额外依赖
