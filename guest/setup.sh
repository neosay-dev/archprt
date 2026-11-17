#!/bin/bash
# Runs inside the Arch Linux ARM chroot (see build.sh): a light, console-first Arch for ArchPrt.
set -euxo pipefail

pacman-key --init
pacman-key --populate archlinuxarm
sed -i 's/^#Color/Color/; s/^#ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf
pacman -Syu --noconfirm
pacman -S --noconfirm --needed zram-generator fastfetch

# Light: no man/docs/translations/firmware now or on later installs.
# The kernel stays pinned: ArchPrt boots the kernel it copied next to the disk, so its modules must not change.
sed -i '/^\[options\]/a NoExtract = usr/share/man/* usr/share/doc/* usr/share/info/* usr/share/gtk-doc/* usr/lib/firmware/*\nNoExtract = usr/share/locale/* !usr/share/locale/locale.alias\nIgnorePkg = linux-aarch64 linux-aarch64-headers' /etc/pacman.conf
rm -rf /usr/share/man/* /usr/share/doc/* /usr/share/info/* /usr/share/gtk-doc/* /usr/lib/firmware/*
find /usr/share/locale -mindepth 1 -maxdepth 1 ! -name locale.alias -exec rm -rf {} +

# initramfs that finds a virtio disk without autodetect; no fallback image.
sed -i 's/^MODULES=.*/MODULES=(virtio_pci virtio_blk virtio_console virtio_net ext4)/; s/^HOOKS=.*/HOOKS=(base udev modconf block filesystems fsck)/' /etc/mkinitcpio.conf
sed -i "s/^PRESETS=.*/PRESETS=('default')/" /etc/mkinitcpio.d/linux-aarch64.preset
rm -f /boot/initramfs-linux-fallback.img
mkinitcpio -p linux-aarch64

echo archprt > /etc/hostname
printf '127.0.0.1 localhost\n::1 localhost\n127.0.1.1 archprt\n' > /etc/hosts
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
echo 'LANG=C.UTF-8' > /etc/locale.conf
userdel -r alarm || true
systemctl disable sshd || true
systemctl mask serial-getty@ttyAMA0.service  # ttyAMA0 is the boot.log file on the iOS side
systemctl enable systemd-networkd systemd-resolved archprt-resize archprt-grow

pacman -Scc --noconfirm
rm -rf /var/cache/pacman/pkg/* /var/log/journal/* /root/.bash_history
