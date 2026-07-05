TARGET = iphone:clang:latest:14.0
ARCHS = arm64 arm64e

# Active build: sideload dylib only. Prior privileged-install and main-binary
# surgery experiments are not part of the maintained build path.
LIBRARY_NAME = AccDemoArcaea

AccDemoArcaea_FILES = Tweak.x
AccDemoArcaea_FILES += fishhook.c
AccDemoArcaea_FILES += WQSuspendView/SuspendView/SuspendView/WQSuspendView.m
AccDemoArcaea_FILES += $(wildcard WHToast/WHToast/*.m)

AccDemoArcaea_CFLAGS  += -fobjc-arc
AccDemoArcaea_CFLAGS += -I./WQSuspendView/SuspendView -I./WHToast -I./include

AccDemoArcaea_LIBRARIES = substrate
AccDemoArcaea_LOGOSFLAGS = -c generator=MobileSubstrate
AccDemoArcaea_LDFLAGS = -Xlinker -not_for_dyld_shared_cache

ADDITIONAL_CFLAGS += -Wno-error=unused-variable -Wno-error=unused-function
ADDITIONAL_CFLAGS += -Wno-error=deprecated-declarations
ADDITIONAL_CFLAGS += -include Prefix.pch

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/library.mk

.PHONY: sideload package-sideload

sideload:
	$(MAKE)

package-sideload:
	$(MAKE) package
