TARGET = iphone:clang:latest:14.0
ARCHS = arm64 arm64e

# Arcaea 进程名（CFBundleExecutable）
INSTALL_TARGET_PROCESSES = Arc-mobile

TWEAK_NAME = AccDemoArcaea

AccDemoArcaea_FILES = Tweak.x
AccDemoArcaea_CFLAGS = -fobjc-arc

AccDemoArcaea_FILES += WQSuspendView/SuspendView/SuspendView/WQSuspendView.m
AccDemoArcaea_CFLAGS += -I./WQSuspendView/SuspendView

AccDemoArcaea_FILES += $(wildcard WHToast/WHToast/*.m)
AccDemoArcaea_CFLAGS += -I./WHToast

# 阶段 A: 仍依赖 Substrate（适用于越狱 / TrollStore + ellekit）
# 阶段 B: 待替换为 fishhook + Dobby + ObjC swizzle 后可去掉 substrate
AccDemoArcaea_LIBRARIES = substrate
AccDemoArcaea_LOGOSFLAGS = -c generator=MobileSubstrate

# Dobby —— 用于 hook Arcaea 内部 C++ 函数（无符号、靠 base+offset）
# libdobby.a 由 CI 下载到 libs/，本地构建需自行放置（见 libs/README.md）
AccDemoArcaea_CFLAGS  += -I./include
AccDemoArcaea_LDFLAGS += -L./libs -ldobby

ADDITIONAL_CFLAGS += -Wno-error=unused-variable -Wno-error=unused-function -include Prefix.pch

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk