# Backend image: the Node/Express control plane + the Renode simulation engine.
#
# Renode needs a full Linux userland (Mono/.NET runtime + system libs), which is
# exactly why this can't run on a serverless platform. We start from Antmicro's
# official Renode image (engine + all its dependencies preinstalled) and add
# Node.js on top, so the whole thing is self-contained and reproducible.
FROM antmicro/renode:latest

# The base image sets an ENTRYPOINT (renode). Clear it so our CMD runs as-is.
ENTRYPOINT []

# Node.js 20 (app needs 18+) plus tools used at build/runtime.
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl ca-certificates procps \
 && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /srv

# Install app deps first so this layer caches across source changes.
COPY app/package.json app/package-lock.json* ./app/
RUN cd app && npm install --omit=dev --no-audit --no-fund

# App source.
COPY app ./app

# Default firmware images — the same files setup.sh fetches. Uploaded firmware
# lands in firmware/uploads at runtime (ephemeral; resets on redeploy).
RUN mkdir -p firmware/defaults firmware/uploads \
 && DL="https://dl.antmicro.com/projects/renode" \
 && curl -L --retry 3 "$DL/nrf52840--zephyr-bluetooth_central_hr.elf-s_3380332-316e27f81dcda3c2b0e7f2c3516001e7b27ad051"   -o firmware/defaults/gateway.elf \
 && curl -L --retry 3 "$DL/nrf52840--zephyr-bluetooth_peripheral_hr.elf-s_3217940-7b59adc9629f8be90067b131e663a13d2d4bb711" -o firmware/defaults/heartrate.elf \
 && curl -L --retry 3 "$DL/nrf52840--zephyr_adxl372_spi.elf-s_993780-1dedb945dae92c07f1b4d955719bfb1f1e604173"            -o firmware/defaults/motion.elf

ENV NODE_ENV=production
# server.js finds the engine via `which renode` (on PATH in this base image).
# If a different base puts it elsewhere, uncomment and point at the launcher:
# ENV RENODE_PATH=/opt/renode/renode

# The platform injects $PORT; server.js already honors it (default 4000).
EXPOSE 4000
CMD ["node", "app/server.js"]
