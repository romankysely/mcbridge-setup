#!/bin/bash
# flash_firmware.sh — Flashuje MeshCore firmware do SenseCAP Solar (P1)
#
# Použití:
#   flash_firmware
#
# Firmware .zip soubory umísti do: ~/meshcore-firmware/

set -euo pipefail

FIRMWARE_DIR="$HOME/meshcore-firmware"
SERVICE="mctomqtt"
PORT="/dev/ttyACM0"

# --- PATH ---
export PATH="$HOME/.local/bin:$PATH"

# --- Barvy ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;36m'
BOLD='\033[1m'
NC='\033[0m'

log()   { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
title() { echo -e "\n${BOLD}${BLUE}=== $* ===${NC}\n"; }

# --- Kontrola závislostí ---
if ! command -v adafruit-nrfutil &>/dev/null; then
    error "adafruit-nrfutil není v PATH. Nainstaluj: pipx install adafruit-nrfutil"
    exit 1
fi

mkdir -p "$FIRMWARE_DIR"

# --- Cleanup: vždy obnoví mctomqtt ---
SERVICE_WAS_RUNNING=false
cleanup() {
    local exit_code=$?
    if $SERVICE_WAS_RUNNING && ! systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        warn "Obnovuji $SERVICE..."
        sudo systemctl start "$SERVICE" && log "$SERVICE spuštěn." || error "Nepodařilo se spustit $SERVICE!"
    fi
    [ $exit_code -ne 0 ] && error "Flashování selhalo (exit code $exit_code)."
    exit $exit_code
}
trap cleanup EXIT

# --- Výběr firmware ---
select_firmware() {
    title "Dostupné firmware buildy"

    local files=()
    while IFS= read -r f; do
        files+=("$f")
    done < <(find "$FIRMWARE_DIR" -name "*.zip" | sort -r)

    if [ ${#files[@]} -eq 0 ]; then
        error "Žádné .zip soubory v $FIRMWARE_DIR"
        error "Nakopíruj firmware přes WinSCP do ~/meshcore-firmware/"
        exit 1
    fi

    echo "  Vyber firmware pro flashování:"
    echo ""
    local i=1
    for f in "${files[@]}"; do
        local fname
        fname=$(basename "$f")
        printf "  ${BOLD}%2d)${NC} %s\n" "$i" "$fname"
        i=$((i + 1))
    done

    echo ""
    read -rp "  Číslo [1-${#files[@]}]: " choice

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#files[@]} ]; then
        error "Neplatná volba."
        exit 1
    fi

    SELECTED_FIRMWARE="${files[$((choice - 1))]}"
    echo ""
    log "Vybrán: $(basename "$SELECTED_FIRMWARE")"
}

# --- Flashování ---
flash_firmware() {
    title "Flashování firmware"

    # Zastav mctomqtt
    if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        SERVICE_WAS_RUNNING=true
        log "Zastavuji $SERVICE..."
        sudo systemctl stop "$SERVICE"
        log "$SERVICE zastaven."
    else
        warn "$SERVICE neběží."
    fi

    # Zkontroluj port
    if [ ! -e "$PORT" ]; then
        error "Port $PORT není dostupný. Je zařízení připojeno přes USB?"
        exit 1
    fi

    log "Port: $PORT"
    log "Firmware: $(basename "$SELECTED_FIRMWARE")"
    echo ""

    adafruit-nrfutil dfu serial \
        -pkg "$SELECTED_FIRMWARE" \
        -p "$PORT" \
        -b 115200 \
        --touch 1200

    echo ""
    log "Firmware úspěšně nahrán!"
}

# --- Synchronizace hodin ---
sync_clock() {
    title "Synchronizace hodin"
    log "Čekám na restart zařízení..."

    local waited=0
    while [ ! -e "$PORT" ]; do
        sleep 1
        waited=$((waited + 1))
        if [ $waited -ge 30 ]; then
            warn "Port $PORT se neobjevil do 30s — přeskakuji sync hodin."
            return
        fi
    done
    sleep 2  # chvíle pro dokončení startu firmware

    log "Synchronizuji hodiny zařízení..."
    python3 - << PYEOF
import serial, time, calendar
epoch = int(calendar.timegm(time.gmtime()))
try:
    with serial.Serial("$PORT", 115200, timeout=3) as ser:
        ser.write(f"time {epoch}\r\n".encode())
        response = ser.readline().decode(errors="replace").strip()
    print(f"  OK  time {epoch}  ({time.strftime('%Y-%m-%d %H:%M:%S UTC')})")
except Exception as e:
    print(f"  WARN: nepodařilo se synchronizovat hodiny: {e}")
PYEOF
}

# --- Hlavní program ---
title "MeshCore Firmware Flash — SenseCAP Solar (P1)"

select_firmware
echo ""
read -rp "Flashovat teď? [y/N]: " confirm
[[ "${confirm,,}" != "y" ]] && { warn "Zrušeno."; exit 0; }

flash_firmware
sync_clock
