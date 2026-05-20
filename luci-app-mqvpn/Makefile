#
# LuCI support for mqvpn
#

include $(TOPDIR)/rules.mk

PKG_VERSION:=0.5.0
PKG_RELEASE:=1

LUCI_TITLE:=LuCI Interface to MQVPN
LUCI_DEPENDS:=+mqvpn
LUCI_PKGARCH:=all
PKG_LICENSE:=GPLv3

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
