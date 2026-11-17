#!/bin/bash
# Builds the ArchPrt guest on an aarch64 Linux host (CI: ubuntu-24.04-arm) with sudo.
# Output in $1 (default ./out): Image, initramfs.img, arch.img (raw ext4, no partition table).
set -euxo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out=$(realpath -m "${1:-out}")
work=$(mktemp -d)
root=$work/root
mkdir -p "$out" "$root"

curl -fL --retry 5 -o "$work/alarm.tgz" http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz
sudo bsdtar -xpf "$work/alarm.tgz" -C "$root"
sudo cp -a "$here/files/." "$root/"
sudo chown -R root:root "$root/etc/systemd" "$root/usr/local/bin" "$root/root"
sudo cp "$here/setup.sh" "$root/setup.sh"

# pacman needs / to be a mount point; DNS through the host for the build only.
sudo mount --bind "$root" "$root"
for d in proc sys dev dev/pts; do sudo mount --bind "/$d" "$root/$d"; done
sudo mv "$root/etc/resolv.conf" "$work/resolv.conf"
sudo cp -L /etc/resolv.conf "$root/etc/resolv.conf"
trap 'sudo umount -R -l "$root" || true' EXIT

sudo chroot "$root" /bin/bash /setup.sh

sudo rm "$root/setup.sh" "$root/etc/resolv.conf"
sudo mv "$work/resolv.conf" "$root/etc/resolv.conf"
sudo umount -R -l "$root"
trap - EXIT

sudo cp "$root/boot/Image" "$out/Image"
sudo cp "$root/boot/initramfs-linux.img" "$out/initramfs.img"

# Tight image; the app makes the file 16 GB sparse and archprt-grow.service fills it.
mb=$(sudo du -sm "$root" | cut -f1)
rm -f "$out/arch.img"
truncate -s $((mb * 125 / 100 + 256))M "$out/arch.img"
sudo mkfs.ext4 -q -L archroot -m 0 -d "$root" "$out/arch.img"
sudo e2fsck -fy "$out/arch.img" || [ $? -le 1 ]  # 1 = fixed something
sudo chown "$(id -u):$(id -g)" "$out"/*
ls -lh "$out"
