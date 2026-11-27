PART_NAME=firmware
REQUIRE_IMAGE_METADATA=1

RAMFS_COPY_BIN='ubicrc32 mktemp'

# The TP-Link bootloader gets its flash layout from "bootargs".
# Use this to our advantage, and:
#  1. Disable the second rootfs (usrimg2)
#  2. Extend the first rootfs (usrimg1) to include more space
#  3. Increase the baudrate to the expected 115200
tplink_sg2xxx_fix_mtdparts() {
	local args
	args="bootargs mtdparts=spi_flash:896K(boot),128K(env),6144K(sys)"
	args="$args,20480K(usrimg1@main),0K(usrimg2)"
	args="$args,4096K(usrappfs),1024K(para)\n"
	args="$args baudrate 115200"

	echo -e "$args" | fw_setenv --script -
}

# For boards that want an additional rootfs_data storage
realtek_remove_ubi_volume() {
	local ubidev ubivol

	ubidev="$(nand_find_ubi "$CI_UBIPART")"
	ubivol="$(nand_find_volume "$ubidev" "$1")"
	[ -z "$ubivol" ] || ubirmvol "/dev/$ubidev" -N "$1"
}

buffalo_wsr1500ax2s_crc32() {
	local crc

	crc="$(ubicrc32 "$1")" || return 1
	printf '%08x' $(( (crc ^ 0xffffffff) & 0xffffffff ))
}

# The bootloader restores the kernel and rootfs volumes from the second
# slot when they do not match the size and CRC variables. Prepare the
# new variables here and write them only after the volumes are flashed,
# so a failed flash leaves the old image and the old variables intact.
buffalo_wsr1500ax2s_prepare_slot0() {
	local tar_file="$1"
	local cmd board_dir kernel rootfs kernel_crc rootfs_crc

	cmd="$(identify_if_gzip "$tar_file")cat"
	board_dir="$($cmd < "$tar_file" | tar tf - | grep -m 1 '^sysupgrade-.*/$')"
	board_dir="${board_dir%/}"
	kernel="/tmp/wsr-kernel"
	rootfs="/tmp/wsr-rootfs"
	$cmd < "$tar_file" | tar xOf - "$board_dir/kernel" > "$kernel" || return 1
	$cmd < "$tar_file" | tar xOf - "$board_dir/root" > "$rootfs" || return 1
	kernel_crc="$(buffalo_wsr1500ax2s_crc32 "$kernel")" || return 1
	rootfs_crc="$(buffalo_wsr1500ax2s_crc32 "$rootfs")" || return 1

	realtek_remove_ubi_volume ubi_r1 || return 1

	printf 'kernel_sz %x\nkernel0_crc %s\nrootfs_sz %x\nrootfs0_crc %s\n' \
		"$(wc -c < "$kernel")" "$kernel_crc" \
		"$(wc -c < "$rootfs")" "$rootfs_crc" > /tmp/wsr-env || return 1
	printf 'sw_commit 0\nsw_tryactive 2\n' >> /tmp/wsr-env
	rm -f "$kernel" "$rootfs"
}

buffalo_wsr1500ax2s_do_upgrade() {
	CI_KERNPART="ubi_k0"
	CI_ROOTPART="ubi_r0"
	buffalo_wsr1500ax2s_prepare_slot0 "$1" || return 1

	sync
	nand_do_flash_file "$1" && fw_setenv --script /tmp/wsr-env && \
		nand_do_upgrade_success
	nand_do_upgrade_failed
}

t20pro_extract_upgrade() {
	local image="$1" dir="$2" size
	local archive=sysupgrade-t20pro

	tar -xOf "$image" "$archive/CONTROL" >/dev/null || return 1
	tar -xOf "$image" "$archive/kernel" > "$dir/kernel" || return 1
	tar -xOf "$image" "$archive/root" > "$dir/root" || return 1
	[ "$(get_magic_long "$dir/kernel")" = 27051956 ] || return 1
	[ "$(identify "$dir/root" cat)" = squashfs ] || return 1
	size=$(wc -c < "$dir/kernel")
	[ "$size" -gt 64 ] && [ "$size" -le 6291456 ] &&
		[ "$(wc -c < "$dir/root")" -le 16252928 ]
}

t20pro_flash_upgrade() {
	local dir="$1" ubi kernel root data volume mtd

	CI_UBIPART=ubi_device
	ubi=$(nand_find_ubi "$CI_UBIPART")
	[ -n "$ubi" ] || return 1
	mtd=$(cat "/sys/class/ubi/$ubi/mtd_num")
	[ "$(cat "/sys/class/mtd/mtd$mtd/offset")" = 1048576 ] || return 1
	[ "$(cat "/sys/class/mtd/mtd$mtd/size")" = 130547712 ] || return 1
	[ "$(cat "/sys/class/ubi/$ubi/ro_mode")" = 0 ] || return 1
	kernel=$(nand_find_volume "$ubi" ubi_k1)
	root=$(nand_find_volume "$ubi" ubi_r1)
	data=$(nand_find_volume "$ubi" rootfs_data)
	[ "$kernel" = "${ubi}_3" ] && [ "$root" = "${ubi}_4" ] || return 1
	for volume in "$kernel" "$root"; do
		[ "$(cat "/sys/class/ubi/$volume/type")" = dynamic ] || return 1
	done
	[ "$(wc -c < "$dir/kernel")" -le "$(cat "/sys/class/ubi/$kernel/data_bytes")" ] || return 1
	[ "$(wc -c < "$dir/root")" -le "$(cat "/sys/class/ubi/$root/data_bytes")" ] || return 1

	# Keep the OEM boot volume IDs unchanged. Never run UBI auto-format.
	nand_remove_ubiblock "$root" || return 1
	ubiupdatevol "/dev/$root" "$dir/root" || return 1
	# Reserve room for future system images and release the rest to the overlay.
	if [ "$(cat "/sys/class/ubi/$root/reserved_ebs")" -gt 128 ]; then
		ubirsvol "/dev/$ubi" -N ubi_r1 -s 16252928 || return 1
	fi
	if [ -n "$data" ]; then
		ubiupdatevol -t "/dev/$data" || return 1
	else
		ubimkvol "/dev/$ubi" -N rootfs_data -m || return 1
	fi
	ubiupdatevol "/dev/$kernel" "$dir/kernel"
}

t20pro_do_upgrade() {
	local dir

	dir=$(mktemp -d /tmp/t20pro-upgrade.XXXXXX) || {
		nand_do_upgrade_failed
		return 1
	}
	if t20pro_extract_upgrade "$1" "$dir" && t20pro_flash_upgrade "$dir"; then
		rm -r "$dir"
		nand_do_upgrade_success
	else
		rm -r "$dir"
		nand_do_upgrade_failed
	fi
}

platform_check_image() {
	local board=$(board_name) dir status

	case "$board" in
	draytek,g2282x)
		draytek_g2282x_set_part_name || return 1
		;;
	t20pro)
		dir=$(mktemp -d /tmp/t20pro-upgrade.XXXXXX) || return 1
		t20pro_extract_upgrade "$1" "$dir"
		status=$?
		rm -r "$dir"
		return "$status"
		;;
	esac

	return 0
}

# Active slot is a "bootpartition" variable in the SYSINFO mtd
# partition, not standard U-Boot env. Self-upgrades the active slot
# instead of flipping it.
draytek_g2282x_set_part_name() {
	local bootpart sysinfo
	sysinfo=$(find_mtd_part SYSINFO)
	bootpart=$(sed -n 's/.*bootpartition=\([01]\).*/\1/p' "${sysinfo:-/dev/null}")
	case "$bootpart" in
	0) PART_NAME="Kernel" ;;
	1) PART_NAME="Kernel2" ;;
	*)
		echo "draytek,g2282x: could not read bootpartition from SYSINFO" >&2
		return 1
		;;
	esac
}

platform_do_upgrade() {
	local board=$(board_name)

	case "$board" in
	t20pro)
		t20pro_do_upgrade "$1"
		;;
	buffalo,wsr-1500ax2s)
		buffalo_wsr1500ax2s_do_upgrade "$1"
		;;
	draytek,g2282x)
		draytek_g2282x_set_part_name || return 1
		default_do_upgrade "$1"
		;;
	linksys,lgs328c|\
	linksys,lgs328mpc-v2|\
	linksys,lgs352c)
		nand_do_upgrade "$1"
		;;
	plasmacloud,esx28|\
	plasmacloud,mcx3|\
	plasmacloud,psx8|\
	plasmacloud,psx10|\
	plasmacloud,psx28)
		PART_NAME="inactive"
		platform_do_upgrade_dualboot_plasmacloud "$1"
		;;
	tplink,festa-fs308g-v1|\
	tplink,sg2008p-v1|\
	tplink,sg2008p-v3|\
	tplink,sg2210p-v3)
		tplink_sg2xxx_fix_mtdparts
		default_do_upgrade "$1"
		;;
	zyxel,xgs1930-28hp|\
	zyxel,xgs2220-30hp|\
	zyxel,xmg1915-10e|\
	zyxel,xmg1915-10ep|\
	zyxel,xs1930-10|\
	zyxel,xs1930-12f|\
	zyxel,xs1930-12hp)
		PART_NAME="factory"
		default_do_upgrade "$1"
		;;
	*)
		default_do_upgrade "$1"
		;;
	esac
}
