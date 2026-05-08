TARGET = iphone:clang:latest:14.0
ARCHS = arm64 arm64e

# 该 dylib 是以 sideload / LC_LOAD_DYLIB 注入 IPA 的方式运行于非越狱设备。
# 不需要貌 bundle filter（那是 MobileSubstrate 加载器专用）。

LIBRARY_NAME = AccDemoArcaea

AccDemoArcaea_FILES = Tweak.x
AccDemoArcaea_FILES += WQSuspendView/SuspendView/SuspendView/WQSuspendView.m
AccDemoArcaea_FILES += $(wildcard WHToast/WHToast/*.m)

AccDemoArcaea_CFLAGS  = -fobjc-arc
AccDemoArcaea_CFLAGS += -I./WQSuspendView/SuspendView -I./WHToast -I./include

# Logos 还是依赖 substrate ABI。sideload 环境下需与 ElleKit 配合
# （libellekit.dylib 同路径放到 IPA）提供 MSHookXxx 符号。
AccDemoArcaea_LIBRARIES = substrate
AccDemoArcaea_LOGOSFLAGS = -c generator=MobileSubstrate

# Dobby 静态库
AccDemoArcaea_LDFLAGS  = -L./libs -ldobby

ADDITIONAL_CFLAGS += -Wno-error=unused-variable -Wno-error=unused-function -include Prefix.pch

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/library.mk
