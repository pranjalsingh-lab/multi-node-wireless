# Wireless Device Lab

A minimal web app that boots a **three-node virtual Bluetooth LE network** and lets
you drop in your own firmware per device - no hardware, no simulator UI to learn.

- **Gateway** - BLE *central*. Scans, connects, and collects live readings.
- **Heart-Rate Band** - BLE *peripheral*. Advertises a heart-rate service and streams beats.
- **Motion Sensor Node** - an **ADXL372 accelerometer over SPI**. Move it live from the UI
  and watch the firmware react.

The two BLE nodes connect over a shared radio medium; the motion node reads a real
modelled sensor. The simulation engine runs entirely in the backend and is never
surfaced in the UI - users only ever see devices, consoles, and controls.

## Quick start

```bash
./setup.sh                 # one-time: fetch engine + default firmware + npm deps
cd app && node server.js   # start the lab
# open http://localhost:4000
```

Click **Start network**. Within a few seconds the gateway and heart-rate band show
*connected* and notifications start flowing; the motion node begins reading its sensor.
Drag the **X / Y / Z** sliders on the motion card to change the acceleration and watch
the reading move.

## Bring your own firmware

Each device card has an **Upload .elf** button. Upload a firmware image built for the
nRF52840 and it is used on the next **Start**; **Default** reverts to the shipped sample.
The motion node's platform exposes an `ADXL372` accelerometer on `spi2` (chip-select on
`gpio0` pin 22), so sensor-reading firmware works out of the box.

Requirements: Linux x86-64, Node 18+, ~150 MB disk, network access for `setup.sh`.

## How it works (for maintainers)

```
browser ──SSE──> Node/Express (app/server.js) ──spawns──> headless engine
   ▲   firmware upload, sensor sliders              │  UART → TCP sockets
   └──────────── live UART consoles ────────────────┘  monitor → TCP (sensor inject)
```

- `app/server.js` generates a platform/run script from `NODES`, launches the engine
  headless with a control port, reads each node's UART over a TCP socket, and streams
  lines to the browser via Server-Sent Events.
- Sensor sliders POST to `/api/sensor`, which is relayed over the engine's monitor
  socket as a live register write to the accelerometer model.
- `app/public/index.html` is a single self-contained page (no build step).

To change the topology (more nodes, different sensors/buses), edit the `NODES` array
and `buildResc()` in `app/server.js`.
