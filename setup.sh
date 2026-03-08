#!/bin/bash
# setup.sh — Inicializacni skript pro Raspberry Pi (MeshCore Bridge)
#
# Pouziti:
#   curl -fsSL https://raw.githubusercontent.com/romankysely/mcbridge-setup/main/setup.sh | bash
#
# Co skript dela:
#   1. Nainstaluje zavislosti (pipx, adafruit-nrfutil + Python 3.13 patche)
#   2. Nainstaluje mctomqtt daemon
#   3. Vytvori /etc/mctomqtt/config.d/00-user.toml (s vyzadanim vstupu)
#   4. Nasadi flash_firmware skript do /usr/local/bin/
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
title "1/6  Systemove zavislosti"

log "Aktualizace balicku..."
sudo apt-get update -qq

log "Instalace pipx a python3..."
sudo apt-get install -y pipx python3 python3-pip > /dev/null

log "Konfigurace PATH pro pipx..."
pipx ensurepath
export PATH="$HOME/.local/bin:$PATH"

# --- 2. adafruit-nrfutil + patche ---
title "2/6  adafruit-nrfutil"

if command -v adafruit-nrfutil &>/dev/null; then
    log "adafruit-nrfutil jiz nainstalovan."
else
    log "Instalace adafruit-nrfutil pres pipx..."
    pipx install adafruit-nrfutil
fi

log "Kontrola Python 3.13 patchu..."

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

# --- 3. mctomqtt daemon ---
title "3/6  mctomqtt daemon"

if systemctl is-active --quiet mctomqtt 2>/dev/null; then
    log "mctomqtt jiz nainstalovan a bezi."
elif [ -f /opt/mctomqtt/mctomqtt.py ]; then
    log "mctomqtt jiz nainstalovan (nespusten)."
else
    log "Instalace mctomqtt..."
    curl -fsSL https://raw.githubusercontent.com/Cisien/meshcoretomqtt/main/install.sh | sudo bash
    log "mctomqtt nainstalovan."
fi

# --- 4. Konfigurace mctomqtt ---
title "4/6  Konfigurace mctomqtt"

USER_CFG="/etc/mctomqtt/config.d/00-user.toml"

if [ -f "$USER_CFG" ]; then
    log "$USER_CFG jiz existuje, preskakuji."
else
    warn "Konfigurace mctomqtt chybi. Zadej hodnoty:"
    echo ""

    read -rp "  IATA kod (napr. PRG): " IATA
    read -rp "  LetsMesh email: " EMAIL
    read -rp "  Owner public key (64 hex, nebo Enter pro prazdne): " OWNER

    echo ""
    warn "Lokalni MQTT broker (nechej prazdne pro preskoceni):"
    read -rp "  Server IP (napr. 192.168.1.100): " LOCAL_MQTT_SERVER

    LOCAL_BROKER_BLOCK=""
    if [ -n "$LOCAL_MQTT_SERVER" ]; then
        read -rp "  Port [1883]: " LOCAL_MQTT_PORT
        LOCAL_MQTT_PORT="${LOCAL_MQTT_PORT:-1883}"
        read -rp "  Uzivatelske jmeno: " LOCAL_MQTT_USER
        read -rsp "  Heslo: " LOCAL_MQTT_PASS
        echo ""
        LOCAL_BROKER_BLOCK="
[[broker]]
name = \"custom-local\"
enabled = true
server = \"$LOCAL_MQTT_SERVER\"
port = $LOCAL_MQTT_PORT
transport = \"tcp\"
keepalive = 60
qos = 0
retain = true

[broker.auth]
method = \"password\"
username = \"$LOCAL_MQTT_USER\"
password = \"$LOCAL_MQTT_PASS\""
    fi

    sudo tee "$USER_CFG" > /dev/null << TOML
# MeshCore to MQTT - User Configuration

[general]
iata = "$IATA"

[serial]
ports = ["/dev/ttyACM0"]

[update]
repo = "Cisien/meshcoretomqtt"
branch = "main"

[[broker]]
name = "letsmesh-us"
enabled = true
server = "mqtt-us-v1.letsmesh.net"
port = 443
transport = "websockets"
keepalive = 60
qos = 0
retain = true

[broker.tls]
enabled = true
verify = true

[broker.auth]
method = "token"
audience = "mqtt-us-v1.letsmesh.net"
owner = "$OWNER"
email = "$EMAIL"

[[broker]]
name = "letsmesh-eu"
enabled = true
server = "mqtt-eu-v1.letsmesh.net"
port = 443
transport = "websockets"
keepalive = 60
qos = 0
retain = true

[broker.tls]
enabled = true
verify = true

[broker.auth]
method = "token"
audience = "mqtt-eu-v1.letsmesh.net"
owner = "$OWNER"
email = "$EMAIL"
$LOCAL_BROKER_BLOCK
TOML

    log "Konfigurace ulozena do $USER_CFG"
    sudo systemctl restart mctomqtt
    log "mctomqtt restartovan."
fi

# --- 5. flash_firmware ---
title "5/6  flash_firmware skript"

mkdir -p "$HOME/meshcore-firmware"
log "Adresar ~/meshcore-firmware/ pripraven."

if [ -f /usr/local/bin/flash_firmware ]; then
    log "flash_firmware jiz nainstalovan."
else
    log "Stahuji flash_firmware..."
    curl -fsSL "$BASE_URL/flash_firmware.sh" | sudo tee /usr/local/bin/flash_firmware > /dev/null
    sudo chmod +x /usr/local/bin/flash_firmware
    log "flash_firmware nainstalovan do /usr/local/bin/flash_firmware"
fi

SUDOERS_FILE="/etc/sudoers.d/admin-mctomqtt"
if [ ! -f "$SUDOERS_FILE" ]; then
    log "Pridavam sudo prava pro spravu mctomqtt..."
    echo "admin ALL=(ALL) NOPASSWD: /bin/systemctl start mctomqtt, /bin/systemctl stop mctomqtt" \
        | sudo tee "$SUDOERS_FILE" > /dev/null
    sudo chmod 440 "$SUDOERS_FILE"
else
    log "sudo prava pro mctomqtt jiz nastavena."
fi

# --- 6. .bashrc ---
title "6/6  Konfigurace .bashrc"

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
echo -e "    1. Pripoj SenseCAP Solar pres USB"
echo -e "    2. Spust:  ${BOLD}sudo systemctl status mctomqtt${NC}  — over ze bezi"
echo -e "    3. Nakopiruj firmware .zip do ${BOLD}~/meshcore-firmware/${NC}  (pres WinSCP)"
echo -e "    4. Spust:  ${BOLD}flash_firmware${NC}"
echo ""
