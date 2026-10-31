# OpenWebRX+ Docker Deployment (Debian)

Deploy [slechev/openwebrxplus](https://hub.docker.com/r/slechev/openwebrxplus) on a **native Debian** machine with a plugged-in SDR (RTL-SDR or RX-888).

## Requirements

- Debian (Bookworm/Trixie recommended) or Debian-like
- USB SDR plugged into the host
- Root/`sudo` for Docker packages, blacklist, and udev

`install.sh` can install missing packages via apt. On **Debian Trixie** the Compose package is `docker-compose` (not `docker-compose-v2`):

```bash
sudo apt-get install -y docker.io docker-compose usbutils udev
sudo systemctl enable --now docker
sudo usermod -aG docker,plugdev "$USER"   # log out/in after this
```

## Quick start

```bash
git clone <this-repo> openwebrx-plus-deployment
cd openwebrx-plus-deployment
chmod +x install.sh scripts/*.sh
./install.sh
```

Defaults suited to Debian servers:

| Setting | Default |
|---------|---------|
| Data dir | `/opt/owrx-docker` |
| Timezone | from `/etc/timezone` |
| Web UI | `http://localhost:8073` |
| USB | `/dev/bus/usb` → container |

Sign in with the admin user/password you set in the installer.

## What `install.sh` does

1. Detects an existing install (`.env`, compose, data dir, container) and offers:
   - **Keep config** — pull & restart only
   - **Reconfigure** — full prompts again
   - **Select profiles only** — checkbox UI, apply profile changes (nothing else)
   - **Abort**
   Shortcut: `./install.sh --profiles`
2. Verifies Debian host; offers apt install of Docker / `usbutils`
3. Adds your user to `docker` + `plugdev` (skips if already a member)
4. Scans USB for RTL-SDR / RX-888
5. Prompts: device, image (standard/SoftMBE), admin, TZ, port, data dir
6. RTL-SDR access mode:
   - **USB** — mount `/dev/bus/usb`, device type `rtl_sdr` (optional IQ tap publish)
   - **rtl_tcp** — no USB mount; device type `rtl_tcp` → `host:port` (LAN or `host.docker.internal`)
7. Installs blacklist + udev only for USB mode (skipped for rtl_tcp client)
8. Writes `.env` + `docker-compose.yml`, seeds profiles, starts Compose

## Helper scripts

| Script | Purpose |
|--------|---------|
| `./scripts/start.sh` | Start stack |
| `./scripts/stop.sh` | Stop stack |
| `./scripts/update.sh` | Pull latest image & recreate |
| `./scripts/status.sh` | Status + USB scan |
| `./scripts/detect-usb.sh` | List plugged SDR USB devices |
| `./uninstall.sh` | Remove OpenWebRX+ + Docker (keeps blacklist/udev) |

## Uninstall

```bash
./uninstall.sh
```

Stops containers, removes OpenWebRX+/autoheal images, deletes generated `.env` / `docker-compose.yml`, optionally wipes `/opt/owrx-docker`, and can purge `docker.io` / `docker-compose`.

**Kept:** `/etc/modprobe.d/owrx-blacklist.conf`, `/etc/udev/rules.d/99-sdr-devices.rules`, and `plugdev` membership.

## Supported devices

### RTL-SDR

Two access modes (chosen at install):

| Mode | OpenWebRX type | Docker | When to use |
|------|----------------|--------|-------------|
| USB | `rtl_sdr` | mounts `/dev/bus/usb` | Dongle plugged into this host |
| rtl_tcp client | `rtl_tcp` | no USB; `remote: host:port` | `rtl_tcp` on this host or another LAN machine |

- USB IDs: `0bda:2832`, `0bda:2838`, …
- USB mode: host DVB drivers blacklisted so Docker can claim the stick
- USB mode optional IQ tap: publish `FORWARD_LOCALPORT_…` for external clients
- rtl_tcp client: start server elsewhere, e.g. `rtl_tcp -a 0.0.0.0 -p 1234`; from the container use `host.docker.internal:1234` (same host) or `192.168.x.x:1234` (LAN)
- Profiles: `presets/rtl_sdr/sdrs.json` — HAMVN 2m/70cm, HF 10/20/40 (LSB/USB + FT8/FT4), ISS voice/SSTV/FM/APRS

### RX-888

- Type: `sddc_soapy` (CPU-heavy)
- USB: `04b4:00f1`, `04b4:00f3`
- Profiles: `presets/rx888/sdrs.json`
- Restart the container after USB (re)plug if the device is missing

## Host files (Debian)

| File | Purpose |
|------|---------|
| `/etc/modprobe.d/owrx-blacklist.conf` | Stop kernel from owning the SDR |
| `/etc/udev/rules.d/99-sdr-devices.rules` | USB permissions (`plugdev`) |

**Reboot** after the first blacklist install if you still see `usb_claim_interface` errors.

```bash
# Optional check after reboot
./scripts/detect-usb.sh
lsusb | grep -iE 'realtek|cypress|0bda|04b4'
```

## Applying profiles

To change **only** which profiles are available (no reconfigure):

```bash
./install.sh --profiles
# or: ./install.sh  →  option 3) Select profiles only
```

This updates the profile list in `settings.json` and **reloads the OpenWebRX+ container**.  
Device settings tuned in the web UI (**PPM, gain, schedule, always-on, …**) are **kept**; only the profile set changes. Use `apply-presets.py --replace-device` only if you want a full preset reset.

Controls: **↑/↓** move, **Space** toggle, **a** all, **n** none, **Enter** confirm, **q** cancel.  
Profiles are listed by frequency; selected rows use a brighter color than unselected.

### Background decoding (checkbox UI)

Install step **Background decoding services** (also `./install.sh --services` or option **4**) uses the same checkbox UI as profiles.

Pick decoders such as **FT8**, **Meshtastic**, **Sonde RS41**, …. That writes `services_enabled` + `services_decoders` into `settings.json`.

**Sonde RS41 note:** MQTT is **not** required to decode. You need:

1. `sonde-rs41` checked in background services  
2. Profile **Sonde RS41 403** enabled  
3. Idle schedule on that profile (installer can set this when you enable Sonde)  
4. Bandplan dial at 403 MHz (installer adds it under `etc/`)

Optional follow-ups when Sonde is selected:

- **SondeHub** upload  
- **Local Mosquitto MQTT** broker (compose service + `mqtt_host=mosquitto`) for pub/sub of spots  

Default idle schedule remains FT8 20m unless you opt into the Sonde schedule.

RTL-SDR Blog **v4**: turn **off** direct sampling on VHF/UHF profiles if needed.

## Update

```bash
./scripts/update.sh
```

## SondeHub hotfix

OpenWebRX+ images through **1.2.128** crash SondeHub uploads (`isValidValue()` missing `self`). This repo mounts `patches/sondehub.py` over the image file. `./scripts/start.sh` and `./scripts/update.sh` add the volume to an existing `docker-compose.yml` if needed, then recreate the container.

Remove that volume once Docker Hub ships a build newer than the 2026-10-28 upstream fix.

## Layout

```
.
├── install.sh
├── patches/sondehub.py          # SondeHub reporter hotfix (mounted into container)
├── presets/{rtl_sdr,rx888}/sdrs.json
├── host/{owrx-blacklist.conf,99-sdr-devices.rules}
└── scripts/
```

Generated (gitignored): `.env`, `docker-compose.yml`, and data under `/opt/owrx-docker` (or your chosen path).

`./scripts/start.sh` seeds `etc/custom.css` and `plugins/{receiver,map}/init.js` if missing. Without those, the browser requests return HTML 404 pages and Firefox blocks them as MIME mismatches.

## References

- [Docker Hub — slechev/openwebrxplus](https://hub.docker.com/r/slechev/openwebrxplus)
- [OpenWebRX+](https://fms.komkon.org/OWRX/)
- [SDDC / RX-888 notes](https://github.com/jketterl/openwebrx/wiki/SDDC-device-notes)
