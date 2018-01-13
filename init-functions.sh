#!/bin/sh
#
# Hybris adaptation bootstrapping initramfs init functions.
#
# Copyright (c) 2014 Jolla Oy
#
# This program is free software; you can redistribute it and/or modify it under
# the terms of the GNU General Public License version 2 as published by the
# Free Software Foundation.
#
# Authors:
#   - Tom Swindell <t.swindell@rubyx.co.uk>
#   - David Greaves <david@dgreaves.com>
#

# This script is sourced by the init-script


# Get options from kernel command line
get_opt() {
	for param in $(cat /proc/cmdline); do
		echo "$param" | grep "^$1=*" | cut -d'=' -f2
	done
}

# Minimal mounts for initrd or pre-init debug session
do_mount_devprocsys() {
	echo "########################## mounting devprocsys"
	mkdir /dev
	mount -t devtmpfs devtmpfs /dev
	# telnetd needs /dev/pts/ entries
	mkdir /dev/pts
	mount -t devpts devpts /dev/pts

	mkdir /proc
	mkdir /sys
	mount -t sysfs sysfs /sys
	mount -t proc proc /proc
}

do_hotplug_scan() {
	echo /sbin/mdev >/proc/sys/kernel/hotplug
	mdev -s
	# There is no way to know when all hotplug events have been processed :(
	sleep 2
}

bootsplash() {
	if [ x$BOOTLOGO = x1 ]; then
		zcat /bootsplash.gz >/dev/fb0
	fi
}

mount_stowaways() {
	echo "########################## mounting stowaways"
	if [ ! -z $DATA_PARTITION ]; then
		data_subdir="$(get_opt data_subdir)"

		mkdir /data
		mkdir /target

		mount $DATA_PARTITION /data

		if [ -f /data/rootfs.img ]; then
			mount /data/rootfs.img /target
		else
			if [ ! -z $SYSTEM_PARTITION ]; then
				# Mount the system partition as root filesystem
				mount $SYSTEM_PARTITION /target

				# Refuse to boot android if installed on system partition
				if [ -f /target/build.prop ]; then
					echo "Refusing to boot android, install a Halium compatible rootfs first!" >>/diagnosis.log
				fi
			fi
		fi

		mkdir -p /target/data # in new fs
		mount --bind /data/${data_subdir} /target/data
	else
		echo "Failed to mount /target, device node '$DATA_PARTITION' not found!" >>/diagnosis.log
	fi
	mount
}

umount_stowaways() {
	if [ ! -z $DATA_PARTITION ]; then
		umount /target/data
		umount /target
		umount /data
	fi
}

# Sugar for accessing usb config
write() {
	echo -n "$2" >"$1"
}

inject_loop() {
	INJ_DIR=/init-ctl
	INJ_STDIN=$INJ_DIR/stdin

	mkdir $INJ_DIR
	mkfifo $INJ_STDIN
	echo "This entire directory is for debugging init - it can safely be removed" >$INJ_DIR/README

	echo "########################## Beginning inject loop"
	while :; do
		while read IN; do
			if [ "$IN" = "continue" ]; then break 2; fi
			$IN
		done <$INJ_STDIN
	done
	rm -rf $INJ_DIR # Clean up if we exited nicely
	echo "########################## inject loop done"
}

# This sets up the USB with whatever USB_FUNCTIONS are set to
usb_setup() {
	write $ANDROID_USB/enable 0
	write $ANDROID_USB/functions ""
	write $ANDROID_USB/enable 1
	usleep 500000 # 0.5 delay to attempt to remove rndis function
	write $ANDROID_USB/enable 0
	write $ANDROID_USB/idVendor 18D1
	write $ANDROID_USB/idProduct D001
	write $ANDROID_USB/iManufacturer "Mer Boat Loader"
	write $ANDROID_USB/iProduct "$CUSTOMPRODUCT"
	write $ANDROID_USB/iSerial "$1"
	write $ANDROID_USB/functions $USB_FUNCTIONS
	write $ANDROID_USB/enable 1
}
# This lets us communicate errors to host (if it needs disable/enable then that's a problem)
usb_info() {
	# make sure USB is settled
	echo "########################## usb_info: $1"
	sleep 1
	write $ANDROID_USB/iSerial "$1"
}

run_debug_session() {
	CUSTOMPRODUCT=$1
	echo "########################## Debug session : $1"
	usb_setup "Mer Debug setting up (DONE_SWITCH=$DONE_SWITCH)"

	USB_IFACE=notfound
	/sbin/ifconfig rndis0 $LOCAL_IP && USB_IFACE=rndis0
	if [ x$USB_IFACE = xnotfound ]; then
		/sbin/ifconfig usb0 $LOCAL_IP && USB_IFACE=usb0
	fi
	# Report for the logs
	/sbin/ifconfig -a

	# Unable to set up USB interface? Reboot.
	if [ x$USB_IFACE = xnotfound ]; then
		usb_info "Mer Debug: ERROR: could not setup USB as usb0 or rndis0"
		dmesg
		sleep 60 # plenty long enough to check usb on host
		reboot -f
	fi

	# Create /etc/udhcpd.conf file.
	echo "start 192.168.2.20" >/etc/udhcpd.conf
	echo "end 192.168.2.90" >>/etc/udhcpd.conf
	echo "lease_file /var/udhcpd.leases" >>/etc/udhcpd.conf
	echo "interface $USB_IFACE" >>/etc/udhcpd.conf
	echo "option subnet 255.255.255.0" >>/etc/udhcpd.conf

	# Be explicit about busybox so this works in a rootfs too
	echo "########################## starting dhcpd"
	$EXPLICIT_BUSYBOX udhcpd

	HALT_BOOT="${2:-y}"
	set_welcome_msg $HALT_BOOT

	if [ -z $DISABLE_TELNET ]; then
		# Non-blocking telnetd
		echo "########################## starting telnetd"
		# We run telnetd on different ports pre/post-switch_root This
		# avoids problems with an unterminated pre-switch_root telnetd
		# hogging the port
		$EXPLICIT_BUSYBOX telnetd -b ${LOCAL_IP}:${TELNET_DEBUG_PORT} -l /bin/sh

		# For some reason this does not work in rootfs
		usb_info "Mer Debug telnet on port $TELNET_DEBUG_PORT on $USB_IFACE $LOCAL_IP - also running udhcpd"
	fi

	if [ "$HALT_BOOT" = "y" ]; then
		# Some logging output
		ps -wlT
		ps -ef
		netstat -lnp
		cat /proc/mounts
		sync

		# Run command injection loop = can be exited via 'continue'
		inject_loop
	fi
}

# writes to /diagnosis.log if there's a problem
check_kernel_config() {
	echo "Checking kernel config"
	if [ ! -e /proc/config.gz ]; then
		echo "No /proc/config.gz. Enable CONFIG_IKCONFIG and CONFIG_IKCONFIG_PROC" >>/diagnosis.log
	else
		# Must be =y
		for x in CONFIG_CGROUPS CONFIG_AUTOFS4_FS CONFIG_DEVTMPFS_MOUNT CONFIG_DEVTMPFS CONFIG_UNIX CONFIG_INOTIFY_USER CONFIG_SYSVIPC CONFIG_NET CONFIG_PROC_FS CONFIG_SIGNALFD CONFIG_SYSFS CONFIG_TMPFS_POSIX_ACL CONFIG_VT; do
			zcat /proc/config.gz | grep -E "^$x=y\$" || echo "$x=y not found in /proc/config.gz" >>/diagnosis.log
		done
		# Must not be =y
		for x in CONFIG_ANDROID_LOW_MEMORY_KILLER CONFIG_DUMMY CONFIG_SYSFS_DEPRECATED; do
			zcat /proc/config.gz | grep -E "^$x=y\$" && echo "$x=y found in /proc/config.gz, must be disabled" >>/diagnosis.log
		done
	fi
}
