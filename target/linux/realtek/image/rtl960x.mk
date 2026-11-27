# SPDX-License-Identifier: GPL-2.0-only

define Device/bt-pon_bt-g711ax
  SOC := rtl9607
  DEVICE_VENDOR := BT-PON
  DEVICE_MODEL := BT-G711AX
  KERNEL_SIZE := 10m
  IMAGE_SIZE := 25m
  $(Device/kernel-lzma)
  IMAGE/sysupgrade.bin := append-rootfs | pad-rootfs | sysupgrade-tar rootfs=$$$$@ | append-metadata
endef
TARGET_DEVICES += bt-pon_bt-g711ax

define Device/buffalo_wsr-1500ax2s
  SOC := rtl8198d
  DEVICE_VENDOR := Buffalo
  DEVICE_MODEL := WSR-1500AX2S
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_SIZE := 6144k
  $(Device/kernel-lzma)
  KERNEL := $$(KERNEL) | check-size $$(KERNEL_SIZE)
  IMAGE/sysupgrade.bin := append-rootfs | pad-rootfs | sysupgrade-tar rootfs=$$$$@ | append-metadata
endef
TARGET_DEVICES += buffalo_wsr-1500ax2s

define Device/t20pro
  SOC := rtl8198d
  DEVICE_VENDOR := TCL
  DEVICE_MODEL := T20 Pro
  DEVICE_PACKAGES := kmod-rtw89-8852ae wpad-mbedtls iw luci ubi-utils t20pro-calibration \
	dropbear dnsmasq firewall4 nftables odhcp6c odhcpd-ipv6only ppp ppp-mod-pppoe \
	kmod-nft-offload kmod-gpio-button-hotplug apk-mbedtls
  KERNEL_SIZE := 6144k
  $(Device/kernel-lzma)
  KERNEL := $$(KERNEL) | check-size $$(KERNEL_SIZE)
  IMAGE/sysupgrade.bin := append-rootfs | check-size 15872k | \
	sysupgrade-tar rootfs=$$$$@ | append-metadata
endef
TARGET_DEVICES += t20pro
