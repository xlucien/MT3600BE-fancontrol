#
# LuCI 风扇温控插件 —— GL.iNet GL-MT3600BE (MediaTek Filogic)
#
# 在 OpenWrt / ImmortalWrt SDK 中编译：
#   make package/luci-app-fancontrol/compile V=s
#
# 也可以直接把 root/ 目录下的文件拷到路由器对应路径后用：
#   /etc/init.d/fancontrol enable && /etc/init.d/fancontrol start
#
include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-fancontrol
PKG_VERSION:=3.19
PKG_RELEASE:=1

PKG_LICENSE:=MIT
PKG_MAINTAINER:=Louis

LUCI_TITLE:=Fan Control for GL.iNet GL-MT3600BE
LUCI_DESCRIPTION:=PWM fan control with auto/curve/manual modes, night quiet window, \
	thermal guard with hysteresis, and time-scaled soft ramp. \
	ucode controller + template, LuCI theme chrome included; no Lua required.
LUCI_DEPENDS:=+luci-base
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# 老版本 SDK 用这一行
# include $(INCLUDE_DIR)/package.mk
