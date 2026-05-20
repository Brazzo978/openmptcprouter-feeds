#
# OpenWrt package for mqvpn
#

include $(TOPDIR)/rules.mk

PKG_NAME:=mqvpn
PKG_VERSION:=0.5.0
PKG_RELEASE:=1

PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/mp0rta/mqvpn.git
PKG_SOURCE_VERSION:=b23a4ae4e9ea90f5f0118f8f23b4de385fbc1fdf
PKG_SOURCE_SUBMODULES:=
PKG_SOURCE:=$(PKG_NAME)-$(PKG_VERSION)-$(PKG_SOURCE_VERSION).tar.gz
PKG_MIRROR_HASH:=skip
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)

PKG_BUILD_PARALLEL:=1
PKG_BUILD_FLAGS:=no-mips16

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/cmake.mk

define Package/mqvpn
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=VPN
  TITLE:=Multipath QUIC VPN over MASQUE CONNECT-IP
  URL:=https://github.com/mp0rta/mqvpn
  DEPENDS:=+kmod-tun +libevent2 +libpthread +libstdcpp +boringssl +ip-full
endef

define Package/mqvpn/description
  mqvpn is a multipath QUIC VPN using MASQUE CONNECT-IP and QUIC DATAGRAMs.
endef

define Package/mqvpn/conffiles
/etc/config/mqvpn
endef

TARGET_CFLAGS += -I$(STAGING_DIR)/usr/include/boringssl
TARGET_LDFLAGS += -L$(STAGING_DIR)/usr/lib/boringssl -lstdc++

CMAKE_OPTIONS += \
	-DBUILD_TESTING=OFF \
	-DCMAKE_SKIP_RPATH=TRUE \
	-DSSL_TYPE=boringssl \
	-DSSL_DYNAMIC=ON \
	-DSSL_INC_PATH=$(STAGING_DIR)/usr/include/boringssl \
	-DSSL_LIB_PATH="$(STAGING_DIR)/usr/lib/boringssl/libssl.so;$(STAGING_DIR)/usr/lib/boringssl/libcrypto.so" \
	-DSSL_LIB=$(STAGING_DIR)/usr/lib/boringssl/libssl.so \
	-DCRYPTO_LIB=$(STAGING_DIR)/usr/lib/boringssl/libcrypto.so \
	-DBORINGSSL_BUILD_DIR=$(STAGING_DIR)/usr/lib/boringssl \
	-DXQC_ENABLE_BBR2=ON \
	-DXQC_ENABLE_FEC=ON \
	-DXQC_ENABLE_XOR=ON

define Package/mqvpn/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/mqvpn $(1)/usr/sbin/mqvpn
	$(INSTALL_DIR) $(1)/usr/lib
	ln -sf boringssl/libssl.so $(1)/usr/lib/libssl.so
	ln -sf boringssl/libcrypto.so $(1)/usr/lib/libcrypto.so
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/mqvpn $(1)/etc/config/mqvpn
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/mqvpn $(1)/etc/init.d/mqvpn
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/etc/uci-defaults/4100-mqvpn $(1)/etc/uci-defaults/4100-mqvpn
endef

$(eval $(call BuildPackage,mqvpn))
