#!/bin/bash
# setup.sh — Inicializacni skript pro Raspberry Pi (MeshCore Bridge)
#
# Pouziti:
#   curl -fsSL https://raw.githubusercontent.com/romankysely/mcbridge-setup/main/setup.sh | bash
#
#   Skript se interaktivne zepta na GitHub PAT pro stazeni CLAUDE.md.

set -euo pipefail

# Pokud je stdin pipe (curl | bash), otevri /dev/tty jako fd 3 pro interaktivni vstup
# (exec < /dev/tty by prepisalo bash stdin a bash by prestal cist zbytek skriptu z pipe)
if ! [ -t 0 ]; then
    exec 3</dev/tty
else
    exec 3<&0
fi

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
CLAUDE_REPO="romankysely/MeshCore"
CLAUDE_BRANCH="moje-zmeny"
CLAUDE_PATH="mcbridge-setup/CLAUDE.md"
MEMORY_PATH="mcbridge-setup/MEMORY.md"
MEMORY_LOCAL="$HOME/.claude/projects/-home-admin/memory/MEMORY.md"

title "MeshCore Bridge — Inicializace RPi"

# --- 0. GitHub token ---
title "0/8  GitHub token"

TOKEN_FILE="$HOME/.config/meshcore/config"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

# Zkus nacist token z ulozeneho souboru
if [ -z "$GITHUB_TOKEN" ] && [ -f "$TOKEN_FILE" ]; then
    GITHUB_TOKEN=$(grep -oP '(?<=GITHUB_TOKEN=)\S+' "$TOKEN_FILE" || true)
    [ -n "$GITHUB_TOKEN" ] && log "GitHub token nacten z $TOKEN_FILE"
fi

# Pokud stale neni, zeptej se interaktivne
if [ -z "$GITHUB_TOKEN" ]; then
    warn "GitHub token nenalezen."
    echo ""
    echo -e "  ${BOLD}Jak ziskat GitHub Personal Access Token (PAT):${NC}"
    echo -e "    1. Otevri: ${BLUE}https://github.com/settings/tokens${NC}"
    echo -e "    2. Klikni: Generate new token → Generate new token (classic)"
    echo -e "    3. Note: napr. 'mcbridge-rpi'"
    echo -e "    4. Expiration: dle preference (napr. 1 year)"
    echo -e "    5. Scope: zatrhni ${BOLD}repo${NC}  (cely radek — pro cteni privat. repo)"
    echo -e "    6. Klikni Generate token → zkopiruj token (ghp_...)"
    echo ""
    read -rsp "  Token (ghp_...): " GITHUB_TOKEN <&3
    echo ""
fi

mkdir -p "$(dirname "$TOKEN_FILE")"
if [ ! -f "$TOKEN_FILE" ]; then
    cat > "$TOKEN_FILE" << TOKENEOF
# MeshCore flash konfigurace
GITHUB_TOKEN=$GITHUB_TOKEN
# PORT=/dev/ttyACM0   # vychozi, odkomentuj pro zmenu
TOKENEOF
    chmod 600 "$TOKEN_FILE"
    log "Token ulozen do $TOKEN_FILE (chmod 600)"
else
    log "$TOKEN_FILE jiz existuje, preskakuji."
fi

# --- 1. Systemove zavislosti ---
title "1/8  Systemove zavislosti"

log "Aktualizace balicku..."
sudo apt-get update -qq

log "Instalace pipx a python3..."
sudo apt-get install -y pipx python3 python3-pip python3-serial > /dev/null

log "Konfigurace PATH pro pipx..."
pipx ensurepath
export PATH="$HOME/.local/bin:$PATH"

# --- 2. adafruit-nrfutil + patche ---
title "2/8  adafruit-nrfutil"

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
title "3/8  mctomqtt daemon"

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
title "4/8  Konfigurace mctomqtt"

USER_CFG="/etc/mctomqtt/config.d/00-user.toml"

if [ -f "$USER_CFG" ]; then
    log "$USER_CFG jiz existuje, preskakuji."
else
    warn "Konfigurace mctomqtt chybi. Zadej hodnoty:"
    echo ""

    read -rp "  IATA kod (napr. PRG): " IATA <&3
    read -rp "  LetsMesh email: " EMAIL <&3
    read -rp "  Owner public key (64 hex, nebo Enter pro prazdne): " OWNER <&3

    echo ""
    warn "Lokalni MQTT broker (nechej prazdne pro preskoceni):"
    read -rp "  Server IP (napr. 192.168.1.100): " LOCAL_MQTT_SERVER <&3

    LOCAL_BROKER_BLOCK=""
    if [ -n "$LOCAL_MQTT_SERVER" ]; then
        read -rp "  Port [1883]: " LOCAL_MQTT_PORT <&3
        LOCAL_MQTT_PORT="${LOCAL_MQTT_PORT:-1883}"
        read -rp "  Uzivatelske jmeno: " LOCAL_MQTT_USER <&3
        read -rsp "  Heslo: " LOCAL_MQTT_PASS <&3
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
title "5/8  flash_firmware skript"

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
title "6/8  Konfigurace .bashrc"

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

# --- 7. Node.js + Claude Code + ensure-claude.service + sync-claude-memory (volitelne) ---
title "7/8  Node.js 22 + Claude Code (volitelne)"

INSTALL_CLAUDE=true
if [ -f /usr/bin/claude ]; then
    log "Claude Code jiz nainstalovan, preskakuji dotaz."
else
    read -rp "  Instalovat Claude Code (AI asistent)? [Y/n]: " _claude_ans <&3
    [[ "${_claude_ans,,}" == n* ]] && INSTALL_CLAUDE=false
fi

if $INSTALL_CLAUDE; then
    if command -v node &>/dev/null && node --version | grep -q "^v22"; then
        log "Node.js 22 jiz nainstalovan: $(node --version)"
    else
        log "Instalace Node.js 22 z nodesource..."
        curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
        sudo apt-get install -y nodejs
        log "Node.js nainstalovan: $(node --version)"
    fi

    if [ -f /usr/bin/claude ]; then
        log "Claude Code jiz nainstalovan."
    else
        log "Instalace Claude Code..."
        sudo npm install -g @anthropic-ai/claude-code
        log "Claude Code nainstalovan: $(claude --version 2>/dev/null || echo 'OK')"
    fi

    ENSURE_CLAUDE_SERVICE="/etc/systemd/system/ensure-claude.service"
    if [ -f "$ENSURE_CLAUDE_SERVICE" ]; then
        log "ensure-claude.service jiz existuje."
    else
        log "Instalace ensure-claude.service..."
        sudo tee "$ENSURE_CLAUDE_SERVICE" > /dev/null << 'SVCEOF'
[Unit]
Description=Ensure Claude Code is installed
After=network-online.target
Wants=network-online.target
ConditionPathExists=!/usr/bin/claude

[Service]
Type=oneshot
ExecStart=/usr/bin/npm install -g @anthropic-ai/claude-code
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCEOF
        sudo systemctl daemon-reload
        sudo systemctl enable ensure-claude.service
        log "ensure-claude.service nainstalovan a povolen."
    fi

    # sync-claude-memory: automaticky push MEMORY.md na GitHub pri kazde zmene
    if [ -f /usr/local/bin/sync-claude-memory ]; then
        log "sync-claude-memory jiz nainstalovan."
    else
        log "Instalace sync-claude-memory..."
        sudo tee /usr/local/bin/sync-claude-memory > /dev/null << 'SYNCEOF'
#!/usr/bin/env bash
# Sync ~/.claude/projects/-home-admin/memory/MEMORY.md to GitHub

set -euo pipefail

MEMORY_FILE="/home/admin/.claude/projects/-home-admin/memory/MEMORY.md"
CONFIG_FILE="/home/admin/.config/meshcore/config"
REPO="romankysely/MeshCore"
BRANCH="moje-zmeny"
REMOTE_PATH="mcbridge-setup/MEMORY.md"

GITHUB_TOKEN=$(grep -oP '(?<=GITHUB_TOKEN=)\S+' "$CONFIG_FILE")

SHA=$(curl -sf \
  -H "Authorization: token $GITHUB_TOKEN" \
  "https://api.github.com/repos/$REPO/contents/$REMOTE_PATH?ref=$BRANCH" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('sha',''))" 2>/dev/null || true)

CONTENT=$(base64 -w 0 < "$MEMORY_FILE")

if [ -n "$SHA" ]; then
  PAYLOAD=$(python3 -c "import json; print(json.dumps({'message': 'auto: sync MEMORY.md', 'branch': '$BRANCH', 'content': '$CONTENT', 'sha': '$SHA'}))")
else
  PAYLOAD=$(python3 -c "import json; print(json.dumps({'message': 'auto: sync MEMORY.md', 'branch': '$BRANCH', 'content': '$CONTENT'}))")
fi

HTTP=$(curl -sf -o /dev/null -w "%{http_code}" -X PUT \
  -H "Authorization: token $GITHUB_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  "https://api.github.com/repos/$REPO/contents/$REMOTE_PATH")

echo "$(date -Iseconds) sync-claude-memory: HTTP $HTTP"
SYNCEOF
        sudo chmod +x /usr/local/bin/sync-claude-memory
        log "sync-claude-memory nainstalovan."
    fi

    SYNC_PATH_UNIT="/etc/systemd/system/sync-claude-memory.path"
    if [ -f "$SYNC_PATH_UNIT" ]; then
        log "sync-claude-memory.path jiz existuje."
    else
        log "Instalace sync-claude-memory systemd units..."
        sudo tee /etc/systemd/system/sync-claude-memory.service > /dev/null << 'SVCEOF'
[Unit]
Description=Sync Claude MEMORY.md to GitHub
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=admin
ExecStart=/usr/local/bin/sync-claude-memory
StandardOutput=journal
StandardError=journal
SVCEOF

        sudo tee "$SYNC_PATH_UNIT" > /dev/null << 'SVCEOF'
[Unit]
Description=Watch Claude MEMORY.md for changes

[Path]
PathModified=/home/admin/.claude/projects/-home-admin/memory/MEMORY.md

[Install]
WantedBy=multi-user.target
SVCEOF

        sudo systemctl daemon-reload
        sudo systemctl enable --now sync-claude-memory.path
        log "sync-claude-memory.path nainstalovan a spusten."
    fi
else
    log "Instalace Claude Code preskocena."
fi

# --- 8. CLAUDE.md + MEMORY.md ---
title "8/8  CLAUDE.md + MEMORY.md pro Claude Code"

CLAUDE_MD="$HOME/CLAUDE.md"
if [ -f "$CLAUDE_MD" ]; then
    log "CLAUDE.md jiz existuje."
else
    log "Stahuji CLAUDE.md..."
    curl -fsSL \
        -H "Authorization: token $GITHUB_TOKEN" \
        "https://raw.githubusercontent.com/$CLAUDE_REPO/$CLAUDE_BRANCH/$CLAUDE_PATH" \
        -o "$CLAUDE_MD"
    log "CLAUDE.md ulozeno do $CLAUDE_MD"
fi

if [ -f "$MEMORY_LOCAL" ]; then
    log "MEMORY.md jiz existuje."
else
    log "Stahuji MEMORY.md..."
    mkdir -p "$(dirname "$MEMORY_LOCAL")"
    HTTP=$(curl -sf -o "$MEMORY_LOCAL" -w "%{http_code}" \
        -H "Authorization: token $GITHUB_TOKEN" \
        "https://raw.githubusercontent.com/$CLAUDE_REPO/$CLAUDE_BRANCH/$MEMORY_PATH" || true)
    if [ -s "$MEMORY_LOCAL" ]; then
        log "MEMORY.md ulozeno do $MEMORY_LOCAL"
    else
        warn "MEMORY.md nenalezeno v repozitari (prvni instalace) — bude vytvoreno pri prvnim spusteni claude."
        rm -f "$MEMORY_LOCAL"
    fi
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
if $INSTALL_CLAUDE; then
    echo -e "    5. Pro AI asistenta spust:  ${BOLD}cd ~ && claude${NC}"
fi
echo ""
