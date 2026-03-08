#!/bin/bash
# setup.sh — Inicializacni skript pro Raspberry Pi (MeshCore Bridge)
#
# Pouziti:
#   curl -fsSL https://raw.githubusercontent.com/romankysely/mcbridge-setup/main/setup.sh | bash
#
# Co skript dela:
#   1. Nainstaluje zavislosti (pipx, adafruit-nrfutil)
#   2. Aplikuje Python 3.13 patche pro nrfutil
#   3. Vytvori adresar ~/meshcore-firmware/
#   4. Stahne a nasadi flash_firmware skript do /usr/local/bin/
#   5. Nakonfiguruje .bashrc (reminder + barevny prompt)

set -euo pipefail

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

BASE_URL="https://raw.githubusercontent.com/romankysely/mcbridge-setup/main"

title "MeshCore Bridge — Inicializace RPi"

# --- 1. Systemove zavislosti ---
title "1/5  Systemove zavislosti"

log "Aktualizace balicku..."
sudo apt-get update -qq

log "Instalace pipx a python3..."
sudo apt-get install -y pipx python3 python3-pip > /dev/null

log "Konfigurace PATH pro pipx..."
pipx ensurepath
export PATH="$HOME/.local/bin:$PATH"

# --- 2. adafruit-nrfutil ---
title "2/5  adafruit-nrfutil"

if command -v adafruit-nrfutil &>/dev/null; then
    log "adafruit-nrfutil jiz nainstalovan."
else
    log "Instalace adafruit-nrfutil pres pipx..."
    pipx install adafruit-nrfutil
fi

# --- 3. Python 3.13 patche ---
title "3/5  Opravy kompatibility (Python 3.13)"

NRFUTIL_VENV=$(find "$HOME/.local/share/pipx/venvs" -maxdepth 1 -name "nrfutil" 2>/dev/null | head -1)

if [ -z "$NRFUTIL_VENV" ]; then
    warn "Venv nrfutil nenalezen, preskakuji patche."
else
    PY_DIR=$(find "$NRFUTIL_VENV/lib" -maxdepth 1 -name "python3*" 2>/dev/null | head -1)
    if [ -n "$PY_DIR" ]; then
        MANIFEST="$PY_DIR/site-packages/nordicsemi/dfu/manifest.py"
        SERIAL="$PY_DIR/site-packages/nordicsemi/dfu/dfu_transport_serial.py"

        if [ -f "$MANIFEST" ] && ! grep -q "dfu_version=None" "$MANIFEST"; then
            log "Patch manifest.py..."
            python3 - "$MANIFEST" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    c = f.read()
c = c.replace(
    '                 softdevice_bootloader=None):',
    '                 softdevice_bootloader=None,\n                 dfu_version=None):'
)
c = c.replace(
    '                 init_packet_data):',
    '                 init_packet_data=None):'
)
with open(path, 'w') as f:
    f.write(c)
print('  OK: manifest.py patched')
PYEOF
        else
            log "manifest.py patch OK."
        fi

        if [ -f "$SERIAL" ] && ! grep -q "list(map(ord" "$SERIAL"; then
            log "Patch dfu_transport_serial.py..."
            python3 - "$SERIAL" << 'PYEOF'
import sys, re
path = sys.argv[1]
with open(path) as f:
    c = f.read()
def fix(m):
    return 'list(map(ord, ' + m.group(1) + '))'
c = re.sub(r'\bmap\(ord,\s*([^)]+)\)', fix, c)
with open(path, 'w') as f:
    f.write(c)
print('  OK: dfu_transport_serial.py patched')
PYEOF
        else
            log "dfu_transport_serial.py patch OK."
        fi
    fi
fi

# --- 4. Adresar a flash skript ---
title "4/5  Adresar a flash skript"

mkdir -p "$HOME/meshcore-firmware"
log "Adresar ~/meshcore-firmware/ pripraven."

log "Stahuji flash_firmware z GitHubu..."
curl -fsSL "$BASE_URL/flash_firmware.sh" | sudo tee /usr/local/bin/flash_firmware > /dev/null
sudo chmod +x /usr/local/bin/flash_firmware
log "flash_firmware nainstalovan do /usr/local/bin/flash_firmware"

SUDOERS_FILE="/etc/sudoers.d/admin-mctomqtt"
if [ ! -f "$SUDOERS_FILE" ]; then
    log "Pridavam sudo prava pro spravu mctomqtt..."
    echo "admin ALL=(ALL) NOPASSWD: /bin/systemctl start mctomqtt, /bin/systemctl stop mctomqtt" \
        | sudo tee "$SUDOERS_FILE" > /dev/null
    sudo chmod 440 "$SUDOERS_FILE"
else
    log "sudo prava pro mctomqtt jiz nastavena."
fi

# --- 5. .bashrc konfigurace ---
title "5/5  Konfigurace .bashrc"

BASHRC="$HOME/.bashrc"
MARKER="# MeshCore flash reminder"

if grep -q "$MARKER" "$BASHRC" 2>/dev/null; then
    log ".bashrc reminder jiz pritomen."
else
    log "Pridavam MeshCore reminder a barevny prompt..."
    cat >> "$BASHRC" << 'BASHEOF'

# MeshCore flash reminder
echo -e "\n\033[1;36m=== MeshCore Flash Repeater ===\033[0m"
echo -e "  Flash firmware:  \033[1mflash_firmware\033[0m"
echo -e "  Buildy kopiruj:  \033[1m~/meshcore-firmware/\033[0m  (pres WinSCP)"
echo ""

# Oranzovy prompt
PS1='${debian_chroot:+($debian_chroot)}\[\033[0;33m\]\u@\h\[\033[0m\]:\[\033[1;36m\]\w\[\033[0m\]\$ '
BASHEOF
    log ".bashrc aktualizovan."
fi

# --- Hotovo ---
title "Hotovo!"
echo -e "  ${GREEN}Instalace dokoncena.${NC}"
echo ""
echo -e "  Dalsi kroky:"
echo -e "    1. Nakopiruj firmware .zip do ${BOLD}~/meshcore-firmware/${NC}  (pres WinSCP)"
echo -e "    2. Pripoj SenseCAP Solar pres USB"
echo -e "    3. Spust:  ${BOLD}flash_firmware${NC}"
echo ""
echo -e "  ${YELLOW}POZNAMKA:${NC} mctomqtt daemon musit nainstalovat zvlast (viz README.md)"
echo ""
