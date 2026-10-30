include $(TOPDIR)/rules.mk

PKG_NAME:=omr-api-paths
PKG_VERSION:=1
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

define Package/omr-api-paths
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Shared resilient OMR VPS API transport
  PKGARCH:=all
  DEPENDS:=+curl +jsonfilter
endef

define Package/omr-api-paths/description
  Parallel WAN reachability selection and serialized VPS administration requests.
endef

define Build/Compile
endef

define Package/omr-api-paths/install
	$(INSTALL_DIR) $(1)/usr/share/omr
	$(INSTALL_DATA) ./files/api-paths.sh $(1)/usr/share/omr/api-paths.sh
endef

$(eval $(call BuildPackage,omr-api-paths))
