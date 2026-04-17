# MT7902 WiFi + Bluetooth Fix — Arch / Garuda Linux

> ⚠️ **THIS WAS VIBE CODED.**
> Before running anything on your machine, **read the script carefully** and make sure you understand what it does. This was written to fix a very specific problem on one specific laptop. It worked for me. It might break yours. You have been warned.

---

## The Problem

If you installed Arch Linux, Garuda, or any Arch-based distro on a laptop with a **MediaTek MT7902 WiFi 7** chip, you probably have no WiFi and no Bluetooth out of the box.

This happened to me on an **ASUS VivoBook** and I couldn't find a single person who had fixed it on Arch. There's a great fix for Ubuntu by [VashuTheGreat](https://github.com/VashuTheGreat/mt7902-fix) but nothing for Arch-based systems, so here we are.

**Why it doesn't work:**
- The MT7902 PCI ID (`14c3:7902`) is missing from the `mt7921e` driver table in mainline Linux
- The MT7902 Bluetooth USB ID (`13d3:3579`) is missing from the `btusb` device table
- The MT7902 chip ID (`0x7902`) is missing from the `btmtk` firmware dispatch switch

All three need to be patched and compiled for things to work.

---

## Hardware This Was Tested On

| Component | Details |
|-----------|---------|
| Laptop | ASUS VivoBook |
| Distro | Garuda Linux (KDE) |
| Kernel | 6.19.11-zen1-1-zen |
| WiFi chip | MediaTek MT7902 (`14c3:7902`) |
| Bluetooth | IMC Networks `13d3:3579` |

**It may work on other Arch-based distros and other laptops with the same chip. It may not. Read the script.**

---

## Prerequisites

- Arch-based distro (Garuda, Manjaro, EndeavourOS, vanilla Arch, etc.)
- **Secure Boot must be disabled** — go into BIOS (F2 on ASUS), Security → Secure Boot → Disabled
- Internet access during the script — it downloads ~130MB of kernel source
- If your laptop has no ethernet port (like mine), use **Android USB tethering**: plug in your phone, enable tethering in Settings, Linux will see it as a wired connection

---

## What the Script Does

1. Detects your kernel package and installs headers + dependencies via `pacman`
2. Installs `linux-firmware` which includes the MT7902 WiFi firmware blobs
3. Downloads additional MT7902 firmware files directly from the kernel firmware repo
4. Clones [jetm/mediatek-mt7927-dkms](https://github.com/jetm/mediatek-mt7927-dkms) which provides the patched mt76 driver source
5. Downloads the required Linux kernel source tarball (~130MB, used to build the driver)
6. **Patches `btusb.c`** — adds USB ID `13d3:3579` to the device table so the driver binds to the BT chip
7. **Patches `btmtk.c`** — adds `case 0x7902:` to the firmware dispatch switch so the chip is recognized
8. Builds everything via DKMS (meaning it survives kernel updates)
9. Loads modules in the correct order
10. Writes autoload configs and regenerates initramfs

---

## Usage

```bash
# Clone or download the script, then:
sudo bash mt7902_fix_v2.sh
```

After it completes, reboot:
```bash
sudo reboot
```

After reboot verify:
```bash
ip link                 # should show wlo1 or wlp2s0
bluetoothctl show       # should show a controller
```

---

## The KDE / rfkill Issue

If you're on a KDE-based distro and Bluetooth powers on but keeps getting soft-blocked, make sure this line is uncommented in `/etc/bluetooth/main.conf`:

```
AutoEnable=true
```

KDE saves the bluetooth power state and can fight with bluetoothd on boot. Setting `AutoEnable=true` tells bluetoothd to always power on the adapter regardless of what KDE thinks the state should be.

---

## Credits

This is an Arch/Garuda adaptation of work done by others. I just ported it, hit a wall, and figured it out the hard way over two days.

- **[VashuTheGreat/mt7902-fix](https://github.com/VashuTheGreat/mt7902-fix)** — The original Ubuntu fix that identified the root cause and the patching strategy. Without this I would have had no idea where to start.
- **[jetm/mediatek-mt7927-dkms](https://github.com/jetm/mediatek-mt7927-dkms)** — The DKMS package that does the heavy lifting of building the patched mt76 and bluetooth drivers.
- **[linux-firmware](https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git)** — Official firmware blobs.

---

## License

MIT — same as the original. Do whatever you want with it, just don't blame me if it breaks your machine. Read the script first.
