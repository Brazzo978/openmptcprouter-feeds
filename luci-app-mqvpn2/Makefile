#
# LuCI support for experimental mqvpn2
#

include $(TOPDIR)/rules.mk

PKG_VERSION:=0.14.0
PKG_RELEASE:=1

LUCI_TITLE:=LuCI Interface to MQVPN2
LUCI_DEPENDS:=+mqvpn2
LUCI_PKGARCH:=all
PKG_LICENSE:=Apache-2.0

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
