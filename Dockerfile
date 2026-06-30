# Backend image: the Node/Express control plane + the Renode simulation engine.
#
# Renode needs a full Linux userland (Mono/.NET runtime + system libs), which is
# why this can't run serverless. The official Renode image already solves all of
# that - but its base OS is old, so running apt inside it fails. So we do all the
# fetching/installing in a clean Debian build stage and copy the results in.

# ---- build stage: Node runtime, app deps, and firmware (apt works here) ------
FROM node:20-bullseye-slim AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
      curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /srv

# Install app deps first so this layer caches across source changes.
COPY app/package.json app/package-lock.json* ./app/
RUN cd app && npm install --omit=dev --no-audit --no-fund

# App source.
COPY app ./app

# Reference firmware sources shown read-only in the UI (the "View code" panel).
COPY firmware/src ./firmware/src

# Default firmware images - the same files setup.sh fetches.
RUN mkdir -p firmware/defaults firmware/uploads \
 && DL="https://dl.antmicro.com/projects/renode" \
 && curl -L --retry 3 "$DL/nrf52840--zephyr-bluetooth_central_hr.elf-s_3380332-316e27f81dcda3c2b0e7f2c3516001e7b27ad051"   -o firmware/defaults/gateway.elf \
 && curl -L --retry 3 "$DL/nrf52840--zephyr-bluetooth_peripheral_hr.elf-s_3217940-7b59adc9629f8be90067b131e663a13d2d4bb711" -o firmware/defaults/heartrate.elf \
 && curl -L --retry 3 "$DL/nrf52840--zephyr_adxl372_spi.elf-s_993780-1dedb945dae92c07f1b4d955719bfb1f1e604173"            -o firmware/defaults/motion.elf

# ---- runtime stage: Renode engine + the Node runtime copied in ---------------
FROM antmicro/renode:latest

# The base image sets an ENTRYPOINT (renode). Clear it so our CMD runs as-is.
ENTRYPOINT []

# The base image runs as a non-root user, but the app writes to /srv at runtime
# (work/, run.resc, renode.log, uploaded firmware). Run as root so those - and
# the COPY'd files below - are writable.
USER root

# Bring in just the Node.js runtime from the build stage - npm isn't needed at
# runtime (deps were already installed there). node is a single binary on PATH.
# (node from bullseye/glibc 2.31 runs on the Renode base; if you ever hit a
# "GLIBC_… not found" error, the base is older than expected - tell me and I'll
# switch to fetching the standalone Node tarball instead.)
COPY --from=build /usr/local/bin/node /usr/local/bin/node

WORKDIR /srv

# App + deps + firmware, already assembled in the build stage.
COPY --from=build /srv /srv

ENV NODE_ENV=production
# server.js finds the engine via `which renode` (on PATH in this base image).
# If a different base puts it elsewhere, uncomment and point at the launcher:
# ENV RENODE_PATH=/opt/renode/renode

# The platform injects $PORT; server.js already honors it (default 4000).
EXPOSE 4000
CMD ["node", "app/server.js"]
