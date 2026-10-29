# OpenWebRX+ Docker Deployment (Debian)

Deploy [slechev/openwebrxplus](https://hub.docker.com/r/slechev/openwebrxplus) on a **native Debian** machine with a plugged-in SDR (RTL-SDR or RX-888).

## Requirements

- Debian (Bookworm/Trixie recommended) or Debian-like
- USB SDR plugged into the host
- Root/`sudo` for Docker packages, blacklist, and udev

`install.sh` can install missing packages via apt:

```bash
sudo apt-get install -y docker.io docker-compose-v2 usbutils udev
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

1. Verifies Debian host; offers apt install of Docker / `usbutils`
2. Adds your user to `docker` + `plugdev` (optional)
3. Scans USB for RTL-SDR / RX-888
4. Prompts: device, image (standard/SoftMBE), admin, TZ, port, data dir
5. RTL-SDR: optional **rtl_tcp** port publish (`FORWARD_LOCALPORT_…`)
6. Installs `/etc/modprobe.d/owrx-blacklist.conf` + udev rules
7. Writes `.env` + `docker-compose.yml`, seeds profiles, starts Compose

## Helper scripts

| Script | Purpose |
|--------|---------|
| `./scripts/start.sh` | Start stack |
| `./scripts/stop.sh` | Stop stack |
| `./scripts/update.sh` | Pull latest image & recreate |
| `./scripts/status.sh` | Status + USB scan |
| `./scripts/detect-usb.sh` | List plugged SDR USB devices |

## Supported devices

### RTL-SDR

- Type: `rtl_sdr`
- USB: `0bda:2832`, `0bda:2838`, …
- Host DVB drivers blacklisted so Docker can claim the stick
- Optional rtl_tcp: e.g. container `1234` → host `5678`
- Profiles: `presets/rtl_sdr/sdrs.json`

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

Presets land in `$OWRX_DATA_DIR/presets/`. Live config is under `$OWRX_DATA_DIR/var/`. Prefer the web UI:

1. Admin → **Settings → SDR Devices and Profiles**
2. Enable `rtl_sdr` or add `sddc_soapy` for RX-888
3. Use `presets/*.json` as a band/profile reference

RTL-SDR Blog **v4**: turn **off** direct sampling on VHF/UHF profiles.

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
