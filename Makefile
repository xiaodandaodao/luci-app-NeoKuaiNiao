#
# Copyright (C) 2026 NeoKuaiNiao
#
# This is free software, licensed under the MIT License.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-neokuainiao
PKG_VERSION:=1.2.2
PKG_RELEASE:=1
PKG_MAINTAINER:=xiaodandaodao
PKG_LICENSE:=MIT

LUCI_TITLE:=NeoKuaiNiao - 迅雷快鸟宽带提速守护
LUCI_DESCRIPTION:=迅雷快鸟提速守护：页面内账号密码+图形验证码登录（或凭证导入），查带宽 → 按需提速 → 心跳保活 → 掉速自动重试。
LUCI_DEPENDS:=+luci-base +rpcd +uclient-fetch +openssl-util
LUCI_PKGARCH:=all

define Package/luci-app-neokuainiao/conffiles
/etc/config/neokuainiao
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
$(eval $(call BuildPackage,luci-app-neokuainiao))
