#!/usr/bin/env bash
# Prepares the lab. Skips the (~100 MB) engine download if you already have a
# Renode build — set RENODE_PATH or keep a build at ../renode or ~/renode.
set -euo pipefail
cd "$(dirname "$0")"

DL="https://dl.antmicro.com/projects/renode"

# --- 1. Simulation engine (only if one isn't already available) -------------
have_engine=""
if [ -n "${RENODE_PATH:-}" ] && [ -x "${RENODE_PATH}" ]; then have_engine="${RENODE_PATH}";
elif [ -x ../renode/renode ]; then have_engine="../renode/renode";
elif [ -x "$HOME/renode/renode" ]; then have_engine="$HOME/renode/renode";
elif command -v renode >/dev/null 2>&1; then have_engine="$(command -v renode)";
fi

if [ -n "$have_engine" ]; then
  echo "==> Using existing Renode build: $have_engine  (skipping engine download)"
elif [ "$(uname -s)" = "Linux" ]; then
  echo "==> No Renode build found — downloading portable engine (~100 MB)…"
  mkdir -p vendor/renode
  curl -L --retry 3 https://builds.renode.io/renode-latest.linux-portable.tar.gz \
    | tar xz --strip-components=1 -C vendor/renode
else
  echo "!! No Renode build found and the auto-download is Linux-only (you are on $(uname -s))."
  echo "!! Point the app at your existing Renode launcher instead, e.g.:"
  echo "!!     RENODE_PATH=/path/to/renode/renode node app/server.js"
  echo "!! (Continuing to fetch firmware + deps so the rest is ready.)"
fi

# --- 2. Default firmware images (small, ~8 MB total) ------------------------
echo "==> Downloading default firmware images…"
mkdir -p firmware/defaults firmware/uploads
curl -L --retry 3 "$DL/nrf52840--zephyr-bluetooth_central_hr.elf-s_3380332-316e27f81dcda3c2b0e7f2c3516001e7b27ad051"   -o firmware/defaults/gateway.elf
curl -L --retry 3 "$DL/nrf52840--zephyr-bluetooth_peripheral_hr.elf-s_3217940-7b59adc9629f8be90067b131e663a13d2d4bb711" -o firmware/defaults/heartrate.elf
curl -L --retry 3 "$DL/nrf52840--zephyr_adxl372_spi.elf-s_993780-1dedb945dae92c07f1b4d955719bfb1f1e604173"            -o firmware/defaults/motion.elf

# --- 3. App deps ------------------------------------------------------------
echo "==> Installing web app dependencies…"
( cd app && npm install --no-audit --no-fund )

echo ""
echo "Done. Start the lab with:"
[ -n "$have_engine" ] && [ "$have_engine" != "../renode/renode" ] && [ "$have_engine" != "$HOME/renode/renode" ] \
  && echo "    RENODE_PATH=$have_engine node app/server.js" \
  || echo "    cd app && node server.js"
echo "Then open http://localhost:4000"
