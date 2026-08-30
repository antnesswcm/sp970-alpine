#!/bin/sh -e

CHROOT=${CHROOT=$(pwd)/rootfs}

# Rootfs sizing:
#   所有镜像都收缩到最小（~200MB），快刷。
#   开机由 expand-rootfs.start 自动扩成满分区（仅"初次刷机启动"一次，标记 /etc/first-boot.done
#   由链路末尾 zz-first-boot-done.start 统一写入；mmcblk0p14 = 3643358 blocks * 1024 = 3730798592）。
#   取消 debug/release 大小区别——用户刷机体验更好，耗时更少。
ROOTFS_SIZE=1610612736   # 1.5G 临时大小，resize2fs -M 会收缩到最小

#package rootfs
rm -f rootfs.raw boot.raw
mkdir -p files mnt

# create boot
truncate -s 67108864 boot.raw
mkfs.ext2 boot.raw
mount boot.raw mnt
tar xf alpine_rootfs.tgz -C mnt ./boot --exclude='./boot/linux.efi' --strip-components=2
umount mnt

# create root img
truncate -s $ROOTFS_SIZE rootfs.raw
mkfs.ext4 rootfs.raw
mount rootfs.raw mnt
tar xpf alpine_rootfs.tgz -C mnt --exclude='./boot/*' --exclude='./root/*' --exclude='./dev/*'

umount mnt

# shrink rootfs to minimum size for fast flashing
# 开机由 expand-rootfs.start 自动扩成满分区（仅首次启动一次，标记 /etc/first-boot.done，日志 /var/log/expand-rootfs.log）
# tar 解包后 fs 未检查，resize2fs 要求先 e2fsck
e2fsck -fy rootfs.raw
resize2fs -M rootfs.raw

# create sparse android images
img2simg rootfs.raw files/alpine_rootfs.bin
img2simg boot.raw files/boot.bin
