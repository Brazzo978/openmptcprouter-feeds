include $(TOPDIR)/rules.mk

PKG_NAME:=omr-profiles
PKG_VERSION:=1
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

define Package/omr-profiles
  SECTION:=net
  CATEGORY:=Network
  TITLE:=OpenMPTCProuter safe connection profiles
  PKGARCH:=all
  DEPENDS:=+lua +luci-base +luci-compat +luci-lib-jsonc +luci-lib-nixio +libuci-lua +rpcd +coreutils-timeout +flock +mptcp +mqvpn +openmptcprouter +omr-api-paths
endef

define Package/omr-profiles/conffiles
/etc/omr-profiles/profiles.json
endef

define Build/Compile
endef

define Package/omr-profiles/install
	$(INSTALL_DIR) $(1)/etc/omr-profiles $(1)/etc/init.d
	$(INSTALL_DIR) $(1)/lib/upgrade/keep.d
	$(INSTALL_DIR) $(1)/usr/lib/lua/omr $(1)/usr/libexec/rpcd $(1)/usr/libexec/omr-profiles
	$(INSTALL_CONF) ./files/etc/omr-profiles/profiles.json $(1)/etc/omr-profiles/profiles.json
	chmod 0700 $(1)/etc/omr-profiles
	chmod 0600 $(1)/etc/omr-profiles/profiles.json
	$(INSTALL_BIN) ./files/etc/init.d/omr-profiles $(1)/etc/init.d/omr-profiles
	$(INSTALL_DATA) ./files/lib/upgrade/keep.d/omr-profiles $(1)/lib/upgrade/keep.d/omr-profiles
	$(INSTALL_DATA) ./files/usr/lib/lua/omr/*.lua $(1)/usr/lib/lua/omr/
	$(INSTALL_BIN) ./files/usr/libexec/rpcd/omr.profiles $(1)/usr/libexec/rpcd/omr.profiles
	$(INSTALL_BIN) ./files/usr/libexec/omr-profiles/* $(1)/usr/libexec/omr-profiles/
endef

$(eval $(call BuildPackage,omr-profiles))
