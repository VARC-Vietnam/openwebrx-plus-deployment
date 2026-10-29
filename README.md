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
6. RTL-SDR: optional **rtl_tcp** port publish (`FORWARD_LOCALPORT_…`)
7. Installs blacklist + udev only if not already present
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

- Type: `rtl_sdr`
- USB: `0bda:2832`, `0bda:2838`, …
- Host DVB drivers blacklisted so Docker can claim the stick
- Optional rtl_tcp: e.g. container `1234` → host `5678`
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

Controls: **↑/↓** move, **Space** toggle, **a** all, **n** none, **Enter** confirm, **q** cancel.  
Profiles are listed by frequency; selected rows use a brighter color than unselected.

### Background FT8 (no browser required)

RTL-SDR preset enables:

| Setting | Value |
|---------|--------|
| Keep device running | `always-on: true` |
| Run background services | `services: true` |
| Static schedule (UTC) | `0001–2359` → profile `20m_ft8` (14.074 MHz) |
| Background decoding | `services_enabled` + decoder `ft8` |

OpenWebRX schedule times are **UTC**. A browser user selecting another profile temporarily overrides the schedule; when they disconnect, FT8 20m resumes.

RTL-SDR Blog **v4**: turn **off** direct sampling on VHF/UHF profiles if needed.

## Update

```bash
./scripts/update.sh
```

## Layout

```
.
├── install.sh
├── presets/{rtl_sdr,rx888}/sdrs.json
├── host/{owrx-blacklist.conf,99-sdr-devices.rules}
└── scripts/
```

Generated (gitignored): `.env`, `docker-compose.yml`, and data under `/opt/owrx-docker` (or your chosen path).

## References

- [Docker Hub — slechev/openwebrxplus](https://hub.docker.com/r/slechev/openwebrxplus)
- [OpenWebRX+](https://fms.komkon.org/OWRX/)
- [SDDC / RX-888 notes](https://github.com/jketterl/openwebrx/wiki/SDDC-device-notes)
