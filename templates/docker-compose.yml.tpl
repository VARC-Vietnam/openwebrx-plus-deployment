# Reference shape used by install.sh (the installer writes docker-compose.yml directly).
# Kept for documentation / manual edits.

services:
  openwebrx:
    image: ${OWRX_IMAGE}
    container_name: ${OWRX_CONTAINER_NAME}
    restart: unless-stopped
    ports:
      - "${OWRX_PORT}:8073"
      # Optional rtl_tcp publish, e.g.:
      # - "5678:5678"
    environment:
      TZ: ${TZ}
      OPENWEBRX_ADMIN_USER: ${OPENWEBRX_ADMIN_USER}
      OPENWEBRX_ADMIN_PASSWORD: ${OPENWEBRX_ADMIN_PASSWORD}
      # Optional:
      # FORWARD_LOCALPORT_1234: 5678
      # HEALTHCHECK_USB_0BDA_2838: 1
      # HEALTHCHECK_SDR_DEVICES: 1
    # USB mode only:
    # devices:
    #   - /dev/bus/usb:/dev/bus/usb
    # privileged: true
    # rtl_tcp client mode (no USB):
    # extra_hosts:
    #   - "host.docker.internal:host-gateway"
    # privileged: false
    volumes:
      - ${OWRX_DATA_DIR}/etc:/etc/openwebrx
      - ${OWRX_DATA_DIR}/var:/var/lib/openwebrx
      - ${OWRX_DATA_DIR}/plugins:/usr/lib/python3/dist-packages/htdocs/plugins
      # Hotfix: SondeHub isValidValue missing self (remove when image > 2026-10-28)
      - ./patches/sondehub.py:/usr/lib/python3/dist-packages/owrx/reporting/sondehub.py:ro
    tmpfs:
      - /tmp:mode=1777
    privileged: true

  autoheal:
    image: willfarrell/autoheal:latest
    container_name: ${OWRX_CONTAINER_NAME}-autoheal
    restart: always
    environment:
      AUTOHEAL_CONTAINER_LABEL: all
      AUTOHEAL_INTERVAL: 60
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    profiles:
      - autoheal
