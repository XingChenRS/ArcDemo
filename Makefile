TARGET = iphone:clang:latest:14.0
ARCHS = arm64 arm64e

# 构建变体: make          → Sideload (默认)
#           make trollstore → TrollStore (+ graft slot 判定 classifier 替换)
ARC_TROLLSTORE ?= 0

LIBRARY_NAME = AccDemoArcaea

AccDemoArcaea_FILES = Tweak.x
AccDemoArcaea_FILES += fishhook.c
AccDemoArcaea_FILES += WQSuspendView/SuspendView/SuspendView/WQSuspendView.m
AccDemoArcaea_FILES += $(wildcard WHToast/WHToast/*.m)

ifeq ($(ARC_TROLLSTORE),1)
AccDemoArcaea_FILES += JudgeWindow.c
AccDemoArcaea_CFLAGS += -DARC_TROLLSTORE=1
else
AccDemoArcaea_CFLAGS += -DARC_TROLLSTORE=0
endif

AccDemoArcaea_CFLAGS  += -fobjc-arc
AccDemoArcaea_CFLAGS += -I./WQSuspendView/SuspendView -I./WHToast -I./include

AccDemoArcaea_LIBRARIES = substrate
AccDemoArcaea_LOGOSFLAGS = -c generator=MobileSubstrate
AccDemoArcaea_LDFLAGS = -Xlinker -not_for_dyld_shared_cache

ADDITIONAL_CFLAGS += -Wno-error=unused-variable -Wno-error=unused-function -include Prefix.pch

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/library.mk

.PHONY: sideload trollstore package-sideload package-trollstore

sideload:
	$(MAKE) ARC_TROLLSTORE=0

trollstore:
	$(MAKE) ARC_TROLLSTORE=1

package-sideload:
	$(MAKE) package ARC_TROLLSTORE=0

package-trollstore:
	$(MAKE) package ARC_TROLLSTORE=1
