#!/usr/bin/env bash
# Fetches the simulation engine (portable, self-contained) and the three default
# firmware images, then installs the web app's dependencies.
set -euo pipefail
cd "$(dirname "$0")"

DL="https://dl.antmicro.com/projects/renode"

echo "==> Downloading the simulation engine (portable, ~100 MB)…"
mkdir -p vendor/renode
curl -L --retry 3 https://builds.renode.io/renode-latest.linux-portable.tar.gz \
  | tar xz --strip-components=1 -C vendor/renode

echo "==> Downloading default firmware images…"
mkdir -p firmware/defaults firmware/uploads
curl -L --retry 3 "$DL/nrf52840--zephyr-bluetooth_central_hr.elf-s_3380332-316e27f81dcda3c2b0e7f2c3516001e7b27ad051"   -o firmware/defaults/gateway.elf
curl -L --retry 3 "$DL/nrf52840--zephyr-bluetooth_peripheral_hr.elf-s_3217940-7b59adc9629f8be90067b131e663a13d2d4bb711" -o firmware/defaults/heartrate.elf
curl -L --retry 3 "$DL/nrf52840--zephyr_adxl372_spi.elf-s_993780-1dedb945dae92c07f1b4d955719bfb1f1e604173"            -o firmware/defaults/motion.elf

echo "==> Installing web app dependencies…"
( cd app && npm install --no-audit --no-fund )

echo ""
echo "Done. Start the lab with:"
echo "    cd app && node server.js"
echo "Then open http://localhost:4000"
