#!/bin/bash
# ============================================================
# MT7902 WiFi + Bluetooth Fix — Arch / Garuda Linux
# Tested on: ASUS VivoBook, Garuda Linux, kernel 6.19-zen
#
# What this fixes:
#   WiFi  — MT7902 PCI ID missing from mt7921e driver
#   BT    — USB ID 13d3:3579 missing from btusb device table
#           chip ID 0x7902 missing from btmtk firmware dispatch
#           rfkill soft-blocking bluetooth on KDE at boot
#
# Usage: sudo bash mt7902_fix_final.sh
# ============================================================

set -euo pipefail

# ── Colors ───────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

LOGFILE="/tmp/mt7902_fix_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOGFILE") 2>&1

log()    { echo -e "${GREEN}[✓]${NC} $1"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1"; }
error()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info()   { echo -e "${BLUE}[i]${NC} $1"; }
header() { echo -e "\n${BOLD}${CYAN}════════════════════════════════════════${NC}\n${BOLD}${CYAN}  $1${NC}\n${BOLD}${CYAN}════════════════════════════════════════${NC}"; }

# ── Root check ───────────────────────────────────────────────
[[ $EUID -ne 0 ]] && { echo -e "${RED}Run as root: sudo bash mt7902_fix_final.sh${NC}"; exit 1; }

clear
echo -e "${BOLD}${CYAN}"
cat << 'BANNER'
  __  __ _____ ___  ___ ____    _____ _____  __
 |  \/  |_   _|__ \/ _ \__ \  |  ___|_ _\ \/ /
 | |\/| | | |    ) | (_) | ) | | |_   | | \  /
 | |  | | | |   / / \__, |/ /  |  _|  | | /  \
 |_|  |_| |_|  /_/    /_//_/   |_|   |___/_/\_\

   WiFi + Bluetooth Fix for Garuda / Arch Linux
   MediaTek MT7902 — Final Version
BANNER
echo -e "${NC}"
echo -e " Log: ${LOGFILE}\n"

# ════════════════════════════════════════════════════════════
# STEP 0 — Detect system
# ════════════════════════════════════════════════════════════
header "STEP 0: System Detection"

KERNEL=$(uname -r)
info "Kernel  : $KERNEL"

# Auto-detect kernel package (zen, hardened, lts, vanilla)
KERNEL_PKG=""
for pkg in linux-zen linux-hardened linux-lts linux; do
  if pacman -Q "$pkg" &>/dev/null; then
    KERNEL_PKG="$pkg"
    break
  fi
done
[[ -z "$KERNEL_PKG" ]] && error "Could not detect kernel package. Install linux-zen-headers manually."
info "Kernel pkg : $KERNEL_PKG"

# Check hardware is present
lspci -nn 2>/dev/null | grep -q "14c3:7902" \
  && log "MT7902 WiFi detected (PCI 14c3:7902)" \
  || warn "MT7902 WiFi NOT detected via lspci"

lsusb 2>/dev/null | grep -q "13d3:3579" \
  && log "MT7902 Bluetooth detected (USB 13d3:3579)" \
  || warn "MT7902 Bluetooth NOT detected via lsusb"

# Check what's currently working
WIFI_WORKING=false
BT_WORKING=false

ip link show 2>/dev/null | grep -qE "wlo[0-9]|wlp[0-9]" && WIFI_WORKING=true
bluetoothctl show 2>/dev/null | grep -q "Controller"     && BT_WORKING=true

echo ""
info "WiFi      : $([ "$WIFI_WORKING" = true ] && echo -e "${GREEN}WORKING${NC}" || echo -e "${RED}NOT WORKING${NC}")"
info "Bluetooth : $([ "$BT_WORKING"   = true ] && echo -e "${GREEN}WORKING${NC}" || echo -e "${RED}NOT WORKING${NC}")"
echo ""

if [[ "$WIFI_WORKING" = true && "$BT_WORKING" = true ]]; then
  log "Everything is already working!"
  exit 0
fi

sleep 1

# ════════════════════════════════════════════════════════════
# STEP 1 — Install dependencies
# ════════════════════════════════════════════════════════════
header "STEP 1: Installing Dependencies"

pacman -Syu --noconfirm --needed \
  dkms \
  base-devel \
  "${KERNEL_PKG}-headers" \
  linux-firmware \
  curl \
  python \
  zstd \
  git \
  kmod \
  openssl

log "Dependencies installed!"

# ════════════════════════════════════════════════════════════
# STEP 2 — Secure Boot check
# ════════════════════════════════════════════════════════════
header "STEP 2: Secure Boot Check"

SB_ENABLED=false
if command -v mokutil &>/dev/null; then
  mokutil --sb-state 2>/dev/null | grep -qi "enabled" && SB_ENABLED=true
elif [[ -f /sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c ]]; then
  SB_VAL=$(od -An -t u1 /sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c \
    2>/dev/null | awk '{print $NF}')
  [[ "$SB_VAL" == "1" ]] && SB_ENABLED=true
fi

if [[ "$SB_ENABLED" = true ]]; then
  echo ""
  warn "Secure Boot is ENABLED — this will block unsigned kernel modules."
  warn "Disable it in BIOS: F2 on boot → Security → Secure Boot → Disabled"
  warn "Then re-run this script."
  exit 1
fi

log "Secure Boot is disabled — OK!"

# ════════════════════════════════════════════════════════════
# STEP 3 — Download firmware blobs
# ════════════════════════════════════════════════════════════
header "STEP 3: MT7902 Firmware Files"

FW_BASE="https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/mediatek"
FW_DIR="/lib/firmware/mediatek"
mkdir -p "$FW_DIR" /usr/lib/firmware/mediatek

download_fw() {
  local name="$1"
  if [[ ! -f "${FW_DIR}/${name}" ]]; then
    info "Downloading ${name}..."
    curl -L --silent --fail -o "${FW_DIR}/${name}" "${FW_BASE}/${name}" \
      && log "${name} downloaded!" \
      || warn "Could not download ${name} — may already be in linux-firmware"
  else
    log "${name} already present"
  fi
  cp -f "${FW_DIR}/${name}" "/usr/lib/firmware/mediatek/${name}" 2>/dev/null || true
}

download_fw "WIFI_RAM_CODE_MT7902_1.bin"
download_fw "WIFI_MT7902_patch_mcu_1_1_hdr.bin"
download_fw "BT_RAM_CODE_MT7902_1_1_hdr.bin"

# ════════════════════════════════════════════════════════════
# STEP 4 — Clone and prepare DKMS repo
# ════════════════════════════════════════════════════════════
header "STEP 4: MediaTek MT7927 DKMS"

WORKDIR="/opt/mt7902_fix"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

if [[ -d "mediatek-mt7927-dkms/.git" ]]; then
  info "Repo already cloned — pulling latest..."
  cd mediatek-mt7927-dkms
  git pull 2>/dev/null || true
  cd ..
else
  info "Cloning jetm/mediatek-mt7927-dkms..."
  git clone https://github.com/jetm/mediatek-mt7927-dkms.git
fi

cd "$WORKDIR/mediatek-mt7927-dkms"

# Auto-detect DKMS version from PKGBUILD
DKMS_VER=$(grep "^pkgver=" PKGBUILD | cut -d= -f2 | tr -d "'\"")
info "DKMS package version: ${DKMS_VER}"

# Download kernel source tarball
MT76_KVER=$(grep "_mt76_kver=" PKGBUILD | sed "s/.*'\(.*\)'/\1/")
KERNEL_TARBALL="linux-${MT76_KVER}.tar.xz"
info "Required kernel source: linux-${MT76_KVER}"

if [[ ! -f "$KERNEL_TARBALL" ]]; then
  info "Downloading kernel source (~130MB)..."
  curl -L --progress-bar -f \
    -o "$KERNEL_TARBALL" \
    "https://cdn.kernel.org/pub/linux/kernel/v${MT76_KVER%%.*}.x/${KERNEL_TARBALL}"
else
  SIZE=$(stat -c%s "$KERNEL_TARBALL" 2>/dev/null || echo 0)
  if (( SIZE < 100000000 )); then
    warn "Tarball looks incomplete — re-downloading..."
    rm -f "$KERNEL_TARBALL"
    curl -L --progress-bar -f \
      -o "$KERNEL_TARBALL" \
      "https://cdn.kernel.org/pub/linux/kernel/v${MT76_KVER%%.*}.x/${KERNEL_TARBALL}"
  else
    log "Kernel source tarball already present"
  fi
fi

# Download ASUS driver ZIP
DRIVER_ZIP=$(ls DRV_WiFi_MTK_MT7925_MT7927_TP_W11_64_V*.zip 2>/dev/null | head -1 || true)
if [[ -z "$DRIVER_ZIP" ]]; then
  info "Downloading ASUS driver ZIP..."
  bash download-driver.sh . 2>&1 | tail -3
  DRIVER_ZIP=$(ls DRV_WiFi_MTK_MT7925_MT7927_TP_W11_64_V*.zip 2>/dev/null | head -1)
fi
log "Driver ZIP: $DRIVER_ZIP"

# Build and install DKMS source tree
info "Preparing sources and applying patches..."
make sources 2>&1 | grep -E "Applying|Installing|Sources|ERROR|error" | head -40

info "Installing DKMS source tree..."
make install 2>&1 | grep -E "Installing|complete|ERROR|error" | head -10

log "DKMS source installed at /usr/src/mediatek-mt7927-${DKMS_VER}"

# ════════════════════════════════════════════════════════════
# STEP 5 — Patch btusb.c to add USB ID 13d3:3579
# ════════════════════════════════════════════════════════════
header "STEP 5: Patching btusb.c (add 13d3:3579)"

BTUSB_SRC="/usr/src/mediatek-mt7927-${DKMS_VER}/drivers/bluetooth/btusb.c"

[[ ! -f "$BTUSB_SRC" ]] && error "btusb.c not found at ${BTUSB_SRC} — did Step 4 complete?"

if grep -q "0x3579" "$BTUSB_SRC"; then
  log "btusb.c already contains 13d3:3579 — skipping"
else
  LAST_MEDIATEK_LINE=$(grep -n "13d3.*BTUSB_MEDIATEK\|BTUSB_MEDIATEK.*13d3" "$BTUSB_SRC" | tail -1 | cut -d: -f1)
  [[ -z "$LAST_MEDIATEK_LINE" ]] && error "Could not find BTUSB_MEDIATEK 13d3 entries in btusb.c"

  INSERT_AFTER=$(( LAST_MEDIATEK_LINE + 1 ))
  info "Inserting 13d3:3579 after line ${INSERT_AFTER} of btusb.c"

  sed -i "${INSERT_AFTER}a\\\\t{ USB_DEVICE(0x13d3, 0x3579), .driver_info = BTUSB_MEDIATEK |\\n\\t\\tBTUSB_WIDEBAND_SPEECH }," "$BTUSB_SRC"

  # Fix tab mangling from sed on some systems
  sed -i 's/^t{ USB_DEVICE(0x13d3, 0x3579)/\t{ USB_DEVICE(0x13d3, 0x3579)/' "$BTUSB_SRC"

  grep -q "0x3579" "$BTUSB_SRC" \
    && log "btusb.c patched — 13d3:3579 added!" \
    || error "btusb.c patch failed — 13d3:3579 not found after insertion"
fi

# ════════════════════════════════════════════════════════════
# STEP 6 — Patch btmtk.c to handle chip ID 0x7902
# ════════════════════════════════════════════════════════════
header "STEP 6: Patching btmtk.c (add case 0x7902)"

BTMTK_SRC="/usr/src/mediatek-mt7927-${DKMS_VER}/drivers/bluetooth/btmtk.c"
BTMTK_HDR="/usr/src/mediatek-mt7927-${DKMS_VER}/drivers/bluetooth/btmtk.h"

[[ ! -f "$BTMTK_SRC" ]] && error "btmtk.c not found at ${BTMTK_SRC}"

if grep -q "case 0x7902:" "$BTMTK_SRC"; then
  log "btmtk.c already has case 0x7902 — skipping"
else
  CASE_LINE=$(grep -n "case 0x7922:" "$BTMTK_SRC" | tail -1 | cut -d: -f1)
  [[ -z "$CASE_LINE" ]] && error "Could not find 'case 0x7922:' in btmtk.c"

  info "Adding case 0x7902 before line ${CASE_LINE} of btmtk.c"
  sed -i "${CASE_LINE}s/case 0x7922:/case 0x7902:\n\tcase 0x7922:/" "$BTMTK_SRC"

  grep -q "case 0x7902:" "$BTMTK_SRC" \
    && log "btmtk.c patched — case 0x7902 added!" \
    || error "btmtk.c patch failed"
fi

if grep -q "FIRMWARE_MT7902" "$BTMTK_HDR"; then
  log "btmtk.h already has FIRMWARE_MT7902 — skipping"
else
  info "Adding FIRMWARE_MT7902 define to btmtk.h..."
  sed -i 's|#define FIRMWARE_MT7922|#define FIRMWARE_MT7902\t\t"mediatek/BT_RAM_CODE_MT7902_1_1_hdr.bin"\n#define FIRMWARE_MT7922|' "$BTMTK_HDR"
  grep -q "FIRMWARE_MT7902" "$BTMTK_HDR" \
    && log "btmtk.h patched!" \
    || warn "Could not patch btmtk.h — driver may still work with dynamic firmware naming"
fi

# ════════════════════════════════════════════════════════════
# STEP 7 — Build and install via DKMS
# ════════════════════════════════════════════════════════════
header "STEP 7: DKMS Build & Install"

info "Building modules (~3-5 minutes)..."
dkms build "mediatek-mt7927/${DKMS_VER}" -k "$KERNEL" --force 2>&1 \
  | grep -E "Signing|Building|Error|error|done" | head -20

info "Installing modules..."
dkms install "mediatek-mt7927/${DKMS_VER}" -k "$KERNEL" --force 2>&1 \
  | grep -E "Installing|Restoring|Error|done" | head -20

log "DKMS build and install complete!"

# ════════════════════════════════════════════════════════════
# STEP 8 — Load modules and bring up interfaces
# ════════════════════════════════════════════════════════════
header "STEP 8: Loading Modules"

# ── WiFi ─────────────────────────────────────────────────────
if [[ "$WIFI_WORKING" = false ]]; then
  info "Loading WiFi modules..."
  modprobe -r mt7921e mt7921_common mt792x_lib mt76_connac_lib mt76 2>/dev/null || true
  sleep 1
  modprobe mt76            && log "mt76 loaded"            || warn "mt76 failed"
  modprobe mt76-connac-lib && log "mt76-connac-lib loaded" || warn "mt76-connac-lib failed"
  modprobe mt792x-lib      && log "mt792x-lib loaded"      || warn "mt792x-lib failed"
  modprobe mt7921-common   && log "mt7921-common loaded"   || warn "mt7921-common failed"
  modprobe mt7921e         && log "mt7921e loaded"         || warn "mt7921e failed"
  sleep 2
  systemctl restart NetworkManager 2>/dev/null || true
  sleep 2
  ip link show 2>/dev/null | grep -qE "wlo[0-9]|wlp[0-9]" \
    && { log "WiFi interface is UP!"; WIFI_WORKING=true; } \
    || warn "WiFi not yet visible — may need reboot"
fi

# ── Bluetooth ────────────────────────────────────────────────
info "Loading Bluetooth modules..."
modprobe -r btusb btmtk 2>/dev/null || true
sleep 1
modprobe btbcm   2>/dev/null && log "btbcm loaded"   || warn "btbcm not available"
modprobe btintel 2>/dev/null && log "btintel loaded" || warn "btintel not available"
modprobe btrtl   2>/dev/null && log "btrtl loaded"   || warn "btrtl not available"
modprobe btmtk              && log "btmtk loaded"    || warn "btmtk failed"
sleep 1
modprobe btusb              && log "btusb loaded"    || warn "btusb failed"
sleep 5

rfkill unblock bluetooth
systemctl restart bluetooth
sleep 5
rfkill unblock bluetooth

bluetoothctl show 2>/dev/null | grep -q "Controller" \
  && { log "Bluetooth controller UP!"; BT_WORKING=true; } \
  || warn "Bluetooth not yet visible — will be ready after reboot"

# ════════════════════════════════════════════════════════════
# STEP 9 — Persistence config
# ════════════════════════════════════════════════════════════
header "STEP 9: Persistence Config"

# WiFi module autoload
cat > /etc/modules-load.d/mt7902-wifi.conf << 'EOF'
mt76
mt76-connac-lib
mt792x-lib
mt7921-common
mt7921e
EOF
log "WiFi autoload config written"

# BT module autoload
cat > /etc/modules-load.d/mt7902-bt.conf << 'EOF'
btbcm
btintel
btrtl
btmtk
btusb
EOF
log "Bluetooth autoload config written"

# udev rule — unblock bluetooth rfkill as soon as the device appears
# This fixes the KDE soft-block issue where KDE restores a saved "off" state
echo 'ACTION=="add", SUBSYSTEM=="rfkill", ATTR{type}=="bluetooth", ATTR{soft}="0"' \
  > /etc/udev/rules.d/99-mt7902-bluetooth-unblock.rules
log "rfkill unblock udev rule written"

udevadm control --reload-rules
udevadm trigger
log "udev rules reloaded"

# AutoEnable=true in bluetoothd config
# Tells bluetoothd to always power on the adapter at startup
# regardless of any saved power state from KDE or other desktop environments
if grep -q "^#AutoEnable=true" /etc/bluetooth/main.conf; then
  sed -i 's/^#AutoEnable=true/AutoEnable=true/' /etc/bluetooth/main.conf
  log "AutoEnable=true set in /etc/bluetooth/main.conf"
elif grep -q "^AutoEnable" /etc/bluetooth/main.conf; then
  sed -i 's/^AutoEnable=.*/AutoEnable=true/' /etc/bluetooth/main.conf
  log "AutoEnable=true already set"
else
  echo "AutoEnable=true" >> /etc/bluetooth/main.conf
  log "AutoEnable=true appended to /etc/bluetooth/main.conf"
fi

# Systemd service — handles the boot timing race condition
# btusb needs a moment after boot before the controller is ready
# This service reloads modules and unblocks rfkill after everything settles
cat > /etc/systemd/system/mt7902-bluetooth.service << 'EOF'
[Unit]
Description=MT7902 Bluetooth boot fix
After=multi-user.target bluetooth.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c "modprobe -r btusb btmtk; sleep 2; modprobe btmtk; modprobe btusb; sleep 8; rfkill unblock bluetooth; sleep 3; systemctl restart bluetooth; sleep 8; rfkill unblock bluetooth; bluetoothctl power on"

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable mt7902-bluetooth.service
log "mt7902-bluetooth systemd service enabled"

depmod -a
log "Module dependencies updated"

info "Regenerating initramfs (mkinitcpio -P)..."
mkinitcpio -P 2>&1 | grep -E "==>|ERROR|error" | tail -10
log "initramfs regenerated!"

# ════════════════════════════════════════════════════════════
# FINAL SUMMARY
# ════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}${CYAN}════════════════════════════════════════${NC}"
echo -e "${BOLD}${CYAN}  FINAL STATUS${NC}"
echo -e "${BOLD}${CYAN}════════════════════════════════════════${NC}"
echo ""

ip link show 2>/dev/null | grep -qE "wlo[0-9]|wlp[0-9]" \
  && echo -e "  WiFi      : ${GREEN}${BOLD}✓ WORKING${NC}" \
  || echo -e "  WiFi      : ${YELLOW}⟳ Needs reboot${NC}"

bluetoothctl show 2>/dev/null | grep -q "Controller" \
  && echo -e "  Bluetooth : ${GREEN}${BOLD}✓ WORKING${NC}" \
  || echo -e "  Bluetooth : ${YELLOW}⟳ Needs reboot${NC}"

echo ""
echo -e "  Log: ${CYAN}${LOGFILE}${NC}"
echo ""
echo -e "  ${BOLD}Reboot now:${NC}"
echo -e "    ${YELLOW}sudo reboot${NC}"
echo ""
echo -e "  ${BOLD}After reboot verify with:${NC}"
echo -e "    ${CYAN}ip link && bluetoothctl show${NC}"
echo ""
