#
# Copyright (C) 2026 Yannick Chabanois (Ycarus) for OpenMPTCProuter
#
# This is free software, licensed under the GNU General Public License v2.
# See /LICENSE for more information.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=bpftune
PKG_VERSION:=0.4.2
PKG_RELEASE:=1

PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/oracle/bpftune.git
PKG_SOURCE_VERSION:=0.4-2
PKG_MIRROR_HASH:=skip

PKG_MAINTAINER:=Yannick Chabanois <contact@openmptcprouter.com>
PKG_LICENSE:=GPL-2.0-only WITH Linux-syscall-note
PKG_LICENSE_FILES:=LICENSE.txt

PKG_BUILD_PARALLEL:=
PKG_INSTALL:=1
PKG_BUILD_DEPENDS:=bpftool/host

include $(INCLUDE_DIR)/package.mk

define Package/bpftune
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=BPF-based auto-tuning for Linux systems
  URL:=https://github.com/oracle/bpftune
  DEPENDS:=+libbpf +libcap +libnl +kmod-sched-bpf @KERNEL_BPF_EVENTS @KERNEL_DEBUG_INFO_BTF
  DEPENDS+=+PACKAGE_bpftune:bpftool
endef

define Package/bpftune/description
  bpftune uses BPF to auto-tune Linux system parameters.
  It provides lightweight, always-on auto-tuning of system behaviour
  by using BPF observability features to continuously monitor and
  adjust system parameters like TCP buffer sizes, congestion control,
  neighbour tables, and more.
endef

TARGET_CFLAGS += -I$(STAGING_DIR)/usr/include/libnl3
TARGET_LDFLAGS += -lbpf -lcap -lnl-3 -lnl-route-3 -ldl -lm -lrt -lcap

MAKE_FLAGS += \
	V=1 \
	CC="$(TARGET_CC)" \
	CFLAGS="$(TARGET_CFLAGS) -fPIC -std=gnu99 -D_POSIX_C_SOURCE=200809L -I$(PKG_BUILD_DIR)/include -I$(PKG_BUILD_DIR)/src -I$(STAGING_DIR)/usr/include -I$(STAGING_DIR)/usr/include/libnl3 -I$(PKG_BUILD_DIR)/include/uapi -I$(LINUX_DIR)/tools/include" \
	LDFLAGS="$(TARGET_LDFLAGS) -L$(PKG_BUILD_DIR)/src" \
	BPF_CFLAGS="-g -fno-stack-protector -Wall -I$(STAGING_DIR)/usr/include -I$(PKG_BUILD_DIR)/include -I$(PKG_BUILD_DIR)/src" \
	BPF_INCLUDE="$(STAGING_DIR)/usr/include" \
	NL_INCLUDE="$(STAGING_DIR)/usr/include/libnl3" \
	CLANG="clang" \
	LLC="llc" \
	BPFTOOL="$(STAGING_DIR_HOST)/usr/sbin/bpftool" \
	GCC_BPF="" \
	OPATH="" \
    prefix=/usr \
    sbindir=/usr/sbin \
    libdir=/usr/lib

define Build/Configure
	# bpftune uses a simple Makefile, no configure needed
endef

# Only src is needed by the router package. The upstream top-level targets
# also build man pages and tests, requiring host rst2man and unrelated tools.
define Build/Compile
	+$(MAKE_VARS) $(MAKE) -C $(PKG_BUILD_DIR)/src \
	$(MAKE_FLAGS) \
	all
endef

define Build/Install
	+$(MAKE_VARS) $(MAKE) -C $(PKG_BUILD_DIR)/src \
	$(MAKE_FLAGS) \
	DESTDIR="$(PKG_INSTALL_DIR)" \
	install
endef

define Package/bpftune/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/sbin/bpftune $(1)/usr/sbin/
	$(INSTALL_DIR) $(1)/usr/lib/bpftune
	$(CP) $(PKG_BUILD_DIR)/src/libbpftune.so* $(1)/usr/lib/
	$(CP) $(PKG_BUILD_DIR)/src/*.so $(1)/usr/lib/bpftune/
	$(CP) ./files/* $(1)/
endef

define Package/bpftune/conffiles
/etc/config/bpftune
endef

$(eval $(call BuildPackage,bpftune))