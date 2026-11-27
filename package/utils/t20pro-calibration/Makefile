# SPDX-License-Identifier: GPL-2.0-only

include $(TOPDIR)/rules.mk

PKG_NAME:=t20pro-calibration
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

define Package/t20pro-calibration
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=TCL T20 Pro factory wireless calibration
  DEPENDS:=@TARGET_realtek_rtl960x +libexpat
endef

define Build/Compile
	$(TARGET_CC) $(TARGET_CPPFLAGS) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) \
		-o $(PKG_BUILD_DIR)/t20pro-calibration $(PKG_BUILD_DIR)/calibration.c -lexpat
endef

define Package/t20pro-calibration/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/t20pro-calibration $(1)/usr/bin/
endef

$(eval $(call BuildPackage,t20pro-calibration))
