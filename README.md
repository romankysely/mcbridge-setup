# MCBridge Setup — MeshCore Bridge + Firmware Flash

Dokumentace pro obnovu Raspberry Pi po vymene SD karty.

## Prehled

Raspberry Pi slouzi jako:
1. **MeshCore <-> MQTT bridge** — daemon `mctomqtt` preposila data ze SenseCAP Solar (USB) na MQTT broker
2. **Firmware flasher** — prikaz `flash_firmware` umoznuje aktualizovat firmware SenseCAP Solar pres USB DFU
3. **AI asistent** — Claude Code s kontextem tohoto projektu (`~/CLAUDE.md`)

---

## Hardware

| Komponenta | Detail |
|-----------|--------|
| Raspberry Pi | Libovolny model s USB + siti |
| SenseCAP Solar (P1) | XIAO nRF52840, USB ID `2886:0059` (Seeed Technology) |
| Pripojeni | USB kabel RPi <-> SenseCAP -> `/dev/ttyACM0` |

---

## Rychla obnova po vymene SD karty

### Predpoklady

- Raspberry Pi OS **Bookworm 64-bit** Lite
- Uzivatel: **`admin`**
- Sitove pripojeni WiFi nebo LAN

### Jeden prikaz

```bash
curl -fsSL https://raw.githubusercontent.com/romankysely/mcbridge-setup/main/setup.sh | bash
```

Skript je interaktivni — zeptá se na GitHub PAT, IATA kod, email a hesla pro MQTT brokery.

### Co setup.sh nainstaluje

| Krok | Co se stane |
|------|-------------|
| 0 | Pozada o GitHub PAT → ulozi do `~/.config/meshcore/config` (chmod 600) |
| 1 | `pipx` + `python3` + `python3-serial` ze systemovych balicku |
| 2 | `adafruit-nrfutil 0.5.3` + Python 3.13 patche |
| 3 | `mctomqtt` daemon (official installer z `Cisien/meshcoretomqtt`) |
| 4 | `/etc/mctomqtt/config.d/00-user.toml` — interaktivne zadane hodnoty |
| 5 | `flash_firmware` do `/usr/local/bin/` + adresar `~/meshcore-firmware/` |
| 6 | `.bashrc` — reminder pri prihlaseni + barevny prompt |
| 7 | Node.js 22 (nodesource) + Claude Code + `ensure-claude.service` |
| 8 | `~/CLAUDE.md` — kontext pro Claude Code |

---

## Claude Code (AI asistent)

Claude Code je nainstalovan jako soucast setup.sh. Po dokonceni instalace ho spustis:

```bash
cd ~
claude
```

### ensure-claude.service

Po upgradu `nodejs` pres `apt` muze dojit ke smazani `/usr/bin/claude`. Systemd service
`ensure-claude.service` ho po bootu automaticky reinstaluje pokud chybi:

```bash
sudo systemctl status ensure-claude.service
```

### Rucni reinstalace Claude

Pokud Claude neni k dispozici:

```bash
sudo npm install -g @anthropic-ai/claude-code
```

---

## Konfigurace mctomqtt

Uzivatelska konfigurace: `/etc/mctomqtt/config.d/00-user.toml`

Hodnoty ktere je potreba zadat:

| Hodnota | Popis | Priklad |
|---------|-------|---------|
| `iata` | 3-pismenny IATA kod letiste pro vasi lokalitu | `PRG` |
| `email` | Email uctu na letsmesh.net | `user@example.com` |
| `owner` | Public key vlastnickeho MeshCore companion zarizeni (64 hex znaku) | viz companion app |
| Lokalni broker | IP, port, uzivatel, heslo lokalniho MQTT brokeru (volitelne) | `192.168.1.100:1883` |

Po zmene konfigurace restartuj:
```bash
sudo systemctl restart mctomqtt
journalctl -u mctomqtt -f   # sledovani logu
```

---

## Jak aktualizovat firmware

### 1. Sestav nebo stahni firmware

Zkompiluj firmware v PlatformIO pro SenseCAP Solar P1 (XIAO nRF52840).

### 2. Nakopiruj firmware na RPi

Pres **WinSCP** do: `~/meshcore-firmware/`

### 3. Spust flashovani

```bash
flash_firmware
```

Skript automaticky:

1. Zastavi `mctomqtt` (uvolni `/dev/ttyACM0`)
2. Zobrazi seznam .zip souboru v `~/meshcore-firmware/`
3. Spusti USB DFU: `adafruit-nrfutil dfu serial --touch 1200`
4. Pocka na restart zarizeni a synchronizuje hodiny (`time <epoch>`)
5. Spusti `mctomqtt`

---

## Uzitecne prikazy

```bash
# Stav sluzby
sudo systemctl status mctomqtt

# Logy v realnem case
journalctl -u mctomqtt -f

# Restart po zmene konfigurace
sudo systemctl restart mctomqtt

# Aktualizace mctomqtt na nejnovejsi verzi
curl -fsSL https://raw.githubusercontent.com/Cisien/meshcoretomqtt/main/install.sh | sudo bash

# Stav ensure-claude.service
sudo systemctl status ensure-claude.service
```

---

## Technicke detaily

### Proc adafruit-nrfutil (ne nrfutil)?

SenseCAP Solar P1 pouziva **OTAFix bootloader** (fork Adafruit nRF52 bootloaderu).

| Nastroj | Vysledek |
|---------|---------|
| `nrfutil 5.x` (Nordic) | Nefunguje s OTAFix bootloaderem |
| `adafruit-nrfutil 0.5.3` | Spravna volba, nativne podporuje OTAFix |

### Jak funguje USB DFU (`--touch 1200`)

```
adafruit-nrfutil dfu serial -pkg firmware.zip -p /dev/ttyACM0 -b 115200 --touch 1200
```

`--touch 1200` = posle DTR signal pri baudrate 1200 -> bootloader se restartuje do DFU modu.

> **POZOR:** Prikaz `start ota` v MeshCore companion = **BLE DFU** (AdaDFU), **ne USB DFU**.
> Pro USB aktualizaci vzdy pouzivej `flash_firmware`.

### Python 3.13 patche pro adafruit-nrfutil

Nrfutil obsahuje dve nekompatibility s Python 3.13 (automaticky opraveno setup.sh):

**manifest.py** — pridat parametry:
```python
# Manifest.__init__: pridat dfu_version=None
# Firmware.__init__: pridat init_packet_data=None
```

**dfu_transport_serial.py** — nahradit `map(ord, ...)` za `list(map(ord, ...))` na radcich ~359, 404, 466.

### mctomqtt daemon

```ini
# /etc/systemd/system/mctomqtt.service
[Service]
User=mctomqtt
WorkingDirectory=/opt/mctomqtt
ExecStart=/opt/mctomqtt/venv/bin/python3 /opt/mctomqtt/mctomqtt.py
Restart=always
```

---

## Bezpecnost

- GitHub PAT **neskladuj** v repozitari
- Token ukládej lokalne: `~/.config/meshcore/config` (chmod 600)
- MQTT hesla jsou pouze v `/etc/mctomqtt/config.d/00-user.toml` (chmod spravuje installer)
- Po kompromitaci tokenu: GitHub -> Settings -> Developer settings -> Personal access tokens -> Revoke

---

*Dokumentace aktualizovana 2026-03-08*
