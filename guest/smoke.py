#!/usr/bin/env python3
"""Boots the built guest with the app's QEMU arguments (minus iOS-only bits) and checks
autologin, the resize handshake, networking and pacman. Usage: smoke.py <out dir>"""
import os, re, shutil, socket, subprocess, sys, tempfile, time

out = os.path.abspath(sys.argv[1])
tmp = tempfile.mkdtemp()
disk = os.path.join(tmp, "arch.img")
shutil.copy(os.path.join(out, "arch.img"), disk)
os.truncate(disk, 16 << 30)  # same as the app
con, rsz = os.path.join(tmp, "c"), os.path.join(tmp, "r")

qemu = subprocess.Popen([
    "qemu-system-aarch64", "-M", "virt", "-cpu", "max,pauth=off",
    "-accel", "tcg,thread=multi,tb-size=256", "-smp", "4", "-m", "1024",
    "-nodefaults", "-no-user-config", "-display", "none", "-monitor", "none",
    "-kernel", os.path.join(out, "Image"), "-initrd", os.path.join(out, "initramfs.img"),
    "-append", "root=/dev/vda rw rootwait console=ttyAMA0 console=hvc0 loglevel=3 systemd.show_status=auto",
    "-serial", "file:" + os.path.join(out, "boot.log"),
    "-device", "virtio-serial-pci",
    "-chardev", f"socket,id=con,path={con},server=on,wait=off", "-device", "virtconsole,chardev=con",
    "-chardev", f"socket,id=rsz,path={rsz},server=on,wait=off",
    "-device", "virtserialport,chardev=rsz,name=dev.archprt.resize",
    "-drive", f"if=none,id=disk,format=raw,cache=writeback,aio=threads,discard=unmap,file={disk}",
    "-device", "virtio-blk-pci,drive=disk",
    "-netdev", "user,id=net", "-device", "virtio-net-pci,netdev=net,romfile=",
    "-device", "virtio-rng-pci",
])

def connect(path):
    for _ in range(300):
        try:
            s = socket.socket(socket.AF_UNIX); s.connect(path); return s
        except OSError:
            time.sleep(0.1)
    raise SystemExit(f"no socket {path}")

c, r = connect(con), connect(rsz)
buf = b""

def expect(pattern, timeout):
    global buf
    end = time.time() + timeout
    c.settimeout(1)
    while time.time() < end:
        if m := re.search(pattern, buf): buf = buf[m.end():]; return m
        try:
            data = c.recv(65536)
        except socket.timeout:
            continue
        if not data: break
        sys.stdout.write(data.decode(errors="replace")); sys.stdout.flush()
        buf += data
    raise SystemExit(f"\nFAIL: no {pattern!r} in {timeout}s")

def run(cmd, timeout=120):
    c.sendall(cmd.encode() + b"; echo __RC=$?\n")
    return int(expect(rb"__RC=(\d+)", timeout).group(1))

try:
    expect(rb"\x1b\[0m [#$] ", 900)  # end of the PS1 from files/root/.bash_profile
    r.settimeout(120)
    assert r.recv(16).startswith(b"?"), "no resize handshake"
    r.sendall(b"40 100\n")
    time.sleep(1)
    assert run("test \"$(stty size)\" = '40 100'") == 0, "resize not applied"
    assert run("systemctl is-system-running --wait >/dev/null; ! systemctl --failed --no-legend --plain | grep .", 600) == 0, "failed units"
    assert run("df -h / | tail -1; test $(df -BG --output=size / | tail -1 | tr -dc 0-9) -ge 15", 300) == 0, "rootfs not grown"
    assert run("pacman -Sy --noconfirm && pacman -Si bash >/dev/null", 600) == 0, "network/pacman"
    print("\nSMOKE OK")
finally:
    qemu.kill()
