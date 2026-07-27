#
# Experimental MQVPN2 package: current upstream datagram engine, isolated
# from the stable mqvpn package used by the v0.62.14 line.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=mqvpn2
PKG_VERSION:=0.14.0
PKG_RELEASE:=2

PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/mp0rta/mqvpn.git
PKG_SOURCE_VERSION:=535100137ad1931ab07d5ec4787f23744349b3e6
PKG_SOURCE_SUBMODULES:=third_party/xquic
PKG_SOURCE:=mqvpn-$(PKG_VERSION)-$(PKG_SOURCE_VERSION).tar.gz
PKG_MIRROR_HASH:=skip
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)

PKG_BUILD_PARALLEL:=1
PKG_BUILD_FLAGS:=no-mips16

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/cmake.mk

define Package/mqvpn2
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=VPN
  TITLE:=MQVPN2 experimental UDP/ICMP multipath VPN
  URL:=https://github.com/mp0rta/mqvpn
  DEPENDS:=+mqvpn +kmod-tun +libevent2 +libpthread +libstdcpp +boringssl +ip-full
endef

define Package/mqvpn2/description
  Isolated MQVPN 0.14 datagram build for UDP/ICMP aggregation testing.
  The hybrid TCP/lwIP lane is disabled.
endef

define Package/mqvpn2/conffiles
/etc/config/mqvpn2
endef

TARGET_CFLAGS += -I$(STAGING_DIR)/usr/include/boringssl
TARGET_LDFLAGS += -L$(STAGING_DIR)/usr/lib/boringssl -lstdc++

CMAKE_OPTIONS += \
	-DBUILD_TESTING=OFF \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_SKIP_RPATH=TRUE \
	-DMQVPN_ENABLE_HYBRID_TCP_LANE=OFF \
	-DMQVPN_ENABLE_HYBRID_TCP_EGRESS=OFF \
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

define Package/mqvpn2/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/mqvpn $(1)/usr/sbin/mqvpn2
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/mqvpn2 $(1)/etc/config/mqvpn2
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/mqvpn2 $(1)/etc/init.d/mqvpn2
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/etc/uci-defaults/4200-mqvpn2 $(1)/etc/uci-defaults/4200-mqvpn2
endef

$(eval $(call BuildPackage,mqvpn2))
