#!/usr/bin/env bash
# List known SDR USB devices currently plugged in.
set -euo pipefail

echo "Scanning USB for known SDR devices..."
echo

if ! command -v lsusb >/dev/null 2>&1; then
  echo "lsusb not found. Install usbutils (apt install usbutils)."
  exit 1
fi

found=0

match_device() {
  local vid="$1" pid="$2" label="$3"
  if lsusb -d "${vid}:${pid}" >/dev/null 2>&1; then
    echo "  [found] ${label}  (${vid}:${pid})"
    lsusb -d "${vid}:${pid}" | sed 's/^/         /'
    found=1
  fi
}

echo "RTL-SDR family:"
match_device 0bda 2832 "RTL2832U (generic)"
match_device 0bda 2838 "RTL-SDR Blog / R820T2"
match_device 0bda 2839 "RTL2838"

echo
echo "RX-888 / SDDC family:"
match_device 04b4 00f1 "RX-888 / BBRF103 (FX3)"
match_device 04b4 00f3 "RX-888mk2 / SDDC"

echo
echo "Other common SDRs:"
match_device 1d50 6089 "HackRF One"
match_device 1df7 2500 "SDRPlay"
match_device 1df7 3000 "SDRPlay RSPdx"

echo
if [[ "$found" -eq 0 ]]; then
  echo "No known SDR USB devices detected."
  echo "Plug the device in, then re-run: ./scripts/detect-usb.sh"
  exit 1
fi

echo "Done."
