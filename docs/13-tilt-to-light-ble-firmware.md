# 13 - Building the Tilt → Hub → Bulb BLE Firmware (findings & gotchas)

> This is the end-to-end record of turning the three lab nodes into a working
> demo: a **tilt sensor** reads an accelerometer over SPI and broadcasts it over
> BLE, a **lighting hub** computes a brightness from the tilt, and a **smart
> bulb** lights up from that brightness. Every wrong turn, why it was wrong, and
> the fix. Read this before touching the firmware or the Renode wiring - it will
> save you the two days it cost to discover the hard way.
>
> Companion docs: [01](01-repl-format.md) (`.repl`), [02](02-resc-monitor.md)
> (`.resc`/Monitor), [10](10-robot-testing-gotchas.md) (`renode-test`/Robot).

---

## 0. What was built

Three custom Zephyr apps for `nrf52840dk/nrf52840`, one per lab node:

```
 Tilt Sensor (motion)          Lighting Hub (gateway)         Smart Bulb (heartrate)
 ────────────────────          ──────────────────────         ──────────────────────
 reads ADXL372 over SPI        BLE observer + broadcaster      BLE observer
 BLE broadcaster               hears tilt beacon,              hears light beacon,
 broadcasts X/Y/Z as a    ──►  computes brightness,       ──►  prints intensity +
 manufacturer beacon (1 Hz)    re-broadcasts a light beacon    drives its LED
```

- Sensor → hub and hub → bulb are **connectionless BLE beacons** (advertising +
  scanning). No GATT, no connections. See §7 for *why* connectionless.
- The sensor→motion link is **SPI** (the ADXL372 is wired to that board).
- The "computation" is on the hub: `brightness = min(100, isqrt(x²+y²)/100)`
  (horizontal-tilt magnitude → 0-100 %). Swap that one function to change how
  tilt drives the light.

Source of record lives in the Zephyr workspace, not this repo:

```
~/zephyrproject/apps/tiltlab/
├── motion/  src/main.c  prj.conf  CMakeLists.txt  boards/nrf52840dk_nrf52840.overlay
├── bulb/    src/main.c  prj.conf  CMakeLists.txt
└── hub/     src/main.c  prj.conf  CMakeLists.txt
```

The built ELFs and a **copy** of each `main.c` are deployed into this repo (§9).

---

## 1. The repo has no firmware build system - the `.c` files are references

`firmware/src/{gateway,heartrate,motion}.c` are **not compiled by anything in
this repo**. They are reference copies shown read-only in the UI (`/api/source`).
The ELFs Renode actually loads are downloaded prebuilt by `setup.sh` into
`firmware/defaults/`, and the app prefers an uploaded ELF in `firmware/uploads/`
over the default (`firmwareFor()` in `app/server.js`).

**To ship your own firmware you must:** build the `.elf` in a real Zephyr
workspace, drop it into `firmware/uploads/<id>.elf` (and/or `defaults/`), and -
if you want the UI source view to match - copy your `main.c` to
`firmware/src/<id>.c`. Node id → file name mapping:

| Node id | Label | src file | ELF name |
|---|---|---|---|
| `gateway` | Lighting Hub | `gateway.c` | `gateway.elf` |
| `heartrate` | Smart Bulb | `heartrate.c` | `heartrate.elf` |
| `motion` | Tilt Sensor | `motion.c` | `motion.elf` |

---

## 2. Zephyr toolchain bring-up on a `uv`-managed Python 3.13

Mainline Zephyr (v4.4.99 here) requires **Python ≥ 3.12**; CMake's
`find_package(Python3)` otherwise grabs the system 3.10 and dies with
`Could NOT find Python3 ... required is at least "3.12"`.

Two traps on this machine:

1. **`python3.13` is a `uv` standalone build**, not an apt package. There is no
   `python3.13-venv` package to install, and `python3.13 -m venv` fails in
   `ensurepip` (`returned non-zero exit status 1`) because uv's standalone
   interpreters don't ship a working ensurepip.

   **Fix - let `uv` build the venv** (it seeds pip itself):
   ```bash
   uv venv --seed --python 3.13 ~/zephyrproject/.venv
   source ~/zephyrproject/.venv/bin/activate
   python -m pip install west
   ```

2. **A CMake venv is only picked up when it is *active*.** Every `west build`
   must run with `source ~/zephyrproject/.venv/bin/activate` first, or you're
   back to Python 3.10.

Full bring-up:
```bash
uv venv --seed --python 3.13 ~/zephyrproject/.venv
source ~/zephyrproject/.venv/bin/activate
python -m pip install west
west init ~/zephyrproject && cd ~/zephyrproject && west update    # several GB
west zephyr-export
pip install -r ~/zephyrproject/zephyr/scripts/requirements.txt
cd ~/zephyrproject/zephyr && west sdk install -t arm-zephyr-eabi   # SDK 1.0.1
```

> **The venv bites you again with `renode-test`** - see §5.4. `renode-test` runs
> Robot Framework under `python3`; the venv's 3.13 does **not** have
> `robotframework` installed, so run `renode-test` in a shell where the venv is
> **not** active (system `python3` has it).

---

## 3. The ADXL372: driver present, sample gone, and the SPI-variant trap

- In Zephyr 4.4 the `samples/sensor/adxl372` **sample was removed**, but the
  **driver is present** at `drivers/sensor/adi/adxl372/` (compatible
  `adi,adxl372`, SPI + I2C). Don't look for the sample; use the sensor API +
  a devicetree overlay.
- Binding: only `reg` and `spi-max-frequency` are **required**; `int1-gpios` is
  optional, so you can **poll** (`sensor_sample_fetch` + `sensor_channel_get`)
  with no trigger/IRQ line.

### 3.1 THE big one: Renode models legacy SPI, not EasyDMA (SPIM)

Renode's `platforms/cpus/nrf52840.repl` maps `spi2` to
`SPI.NRF52840_SPI @ 0x40023000` - which is nRF **SPIM2**, i.e. Zephyr's `&spi2`.
But the model implements the **legacy register-based SPI**, *not* the EasyDMA
**SPIM** interface.

If your overlay uses `compatible = "nordic,nrf-spim"` (the DMA driver), the log
fills with:
```
motion/spi2: Unhandled write to offset 0x508   # SPIM PSEL.SCK
motion/spi2: Unhandled write to offset 0x524   # SPIM FREQUENCY
motion/spi2: Unhandled write to offset 0x10    # SPIM TASKS_START
```
no bytes actually transfer, the driver's device-ID read returns garbage, and the
firmware prints **`ADXL372 not ready`** (`device_is_ready()` is false).

**Fix - use the non-DMA driver:**
```dts
&spi2 {
	compatible = "nordic,nrf-spi";   /* NOT nordic,nrf-spim */
	status = "okay";
	pinctrl-0 = <&spi2_default_alt>;
	pinctrl-1 = <&spi2_sleep_alt>;
	pinctrl-names = "default", "sleep";
	cs-gpios = <&gpio0 22 GPIO_ACTIVE_LOW>;   /* matches Renode's "22 -> adxl372@0" */
	adxl372: adxl372@0 {
		compatible = "adi,adxl372";
		reg = <0>;
		spi-max-frequency = <8000000>;
	};
};
```
The pinctrl psels can be arbitrary free pins (the emulated radio ignores them);
just keep P0.22 for CS to match the `.repl` wiring. With the legacy driver the
model responds correctly - `sysbus.spi2.adxl372 AccelerationX N` (in **g**) then
shows up in the firmware read. The official reference for this exact wiring is
`renode_portable/tests/platforms/NRF52840.robot` ("Should Handle SPI").

---

## 4. Running Renode headless without losing your output

- **Never pass `--console`** in a non-interactive shell. It grabs the tty and
  **swallows all stdout of the whole command** (you get a bare exit code and no
  output). The web app launches Renode as `renode --disable-xwt -P <port> run.resc`
  (no `--console`); do the same for manual runs.
- For **automated verification use `renode-test`** (Robot Framework), not a hand
  rolled socket scraper. It's the documented path and gives clean pass/fail.
- `renode-test` also does `stty` juggling that eats piped stdout - **redirect it
  to a file and read the file** (`./renode-test x.robot > out.txt 2>&1`).

### 4.1 The `pkill` footgun (cost several confusing failures)

`pkill -9 -f renode` / `pkill -f 'PORT=4055'` / `pkill -f run.resc` will match
**the current shell's own command line** whenever that string appears in your
`cd`/env/args - so you kill the very shell running the command and get a bare
**exit 144** with no output. Don't pattern-kill on any string that appears in
your own command. Prefer a unique port and let `renode-test`/the app clean up
their own child processes.

---

## 5. Writing the Robot verification (model on the shipped BLE test)

`renode_portable/tests/platforms/NRF52840.robot` → "Should Run Bluetooth sample"
is the template for multi-node BLE. Key keywords:

```robot
Execute Command           emulation CreateBLEMedium "wireless"
Execute Command           mach create "gateway"
Execute Command           machine LoadPlatformDescription @platforms/cpus/nrf52840.repl
Execute Command           sysbus LoadELF @/abs/path/zephyr.elf
Execute Command           connector Connect sysbus.radio wireless
${hub}=  Create Terminal Tester  sysbus.uart0  machine=gateway
...
Start Emulation
Wait For Line On Uart     some text   testerId=${hub}   timeout=30
```

Gotchas that actually bit:

1. **`mach create`, not `mach add`.** `mach add` only *selects* the new machine
   if none is active; with a machine already selected, the next
   `LoadPlatformDescription` runs on the **wrong** machine and you get
   `Error E02: Variable 'nvic' was already declared`. `mach create` always
   selects the new machine (this is what `buildResc` does).
2. **ELF paths must be absolute `@/...`.** `renode-test` runs Renode with
   `cwd = <portable dir>`, and `@path` resolves against that cwd
   (doc 10 §2). Absolute paths sidestep it.
3. **`Wait For Line On Uart` scans forward from the cursor.** A line printed
   **once at startup** (e.g. `Broadcasting tilt beacon`) must be waited on
   *before* any line that repeats (e.g. `SPI read ...`); if you wait for the
   repeating line first, the cursor moves past the once-only line and the next
   wait hangs until timeout.
4. **Don't run `renode-test` with the Zephyr venv active** (§2) - it lacks
   `robotframework` (`No module named 'robot'`).

---

## 6. Every emulated nRF52840 has the *same* BLE address

`nrf52840.repl` hard-codes the factory address as read-only `Tag`s:
```
Tag <0x100000a0, 0x100000a3> "DEVICEADDRTYPE" 0x1
Tag <0x100000a4, 0x100000a7> "DEVICEADDR[0]"  0xAABBCCDD
```
Zephyr's controller reads exactly these (`hci_vendor.c` → `NRF_FICR->DEVICEADDR`)
so **every node advertises `C0:00:AA:BB:CC:DD`**.

- This is **fatal for the connection approach**: a central that is already
  connected to one peer cannot `bt_conn_le_create()` a second peer at the *same*
  address - it returns `-EINVAL (-22)`.
- **Override per machine** (before firmware runs) if you need distinct addresses:
  ```
  sysbus RemoveTag 0x100000a4
  sysbus Tag <0x100000a4, 0x100000a7> "DEVICEADDR0" 0xAABBCC03
  ```
- **Connectionless broadcast makes this moot** - beacons are matched by payload
  (company id + type), not by address, so all three nodes can share one address.
  The final design uses this, so the override was removed from `buildResc`.

---

## 7. The headline lesson: Renode BLE is reliable for *broadcast*, not for *multiple connections*

The first design was connection-oriented (hub = BLE central holding **two**
connections: subscribe to the sensor's GATT notifications, write brightness to
the bulb's GATT characteristic). It **connected, discovered, subscribed, and
relayed** - and then fell over:

- Both links dropped on **supervision timeout** (`disconnected reason 0x08`)
  within a few seconds of establishing.
- **Re-advertising from the `disconnected` callback returns `-ENOMEM (-12)`** -
  you cannot restart advertising synchronously in that callback context.
- Trying to buy slack with a longer connection interval / 32 s supervision
  timeout made it **worse**: GATT discovery then **hung** (the ATT transactions
  never completed) until the timeout killed the link.

Root cause: **Renode's BLE medium models advertising/scanning robustly but does
not reliably sustain a controller holding two simultaneous connections.** The
one-connection shipped demo (`central_hr` ↔ `peripheral_hr`) works precisely
because it is one connection.

**Fix - drop connections entirely; use connectionless beacons:**

- **motion** = broadcaster: `bt_le_adv_start(BT_LE_ADV_NCONN, ...)` with the tilt
  packed into `BT_DATA_MANUFACTURER_DATA`, refreshed each read via
  `bt_le_adv_update_data()`.
- **hub** = observer + broadcaster: `bt_le_scan_start()` for tilt beacons +
  `bt_le_adv_start(BT_LE_ADV_NCONN, ...)` for its own light beacon, updated on
  each tilt.
- **bulb** = observer: `bt_le_scan_start()`, act on the light beacon.

This removed the flapping completely. The full Robot test (level → full tilt →
back to level, one continuous run) passes in ~10 s, and the live app tracks the
slider `0% → 58% → 0%` with no drops.

### 7.1 Beacon framing (the only "protocol" here)

"AD" = **BLE Advertising Data** (nothing to do with Active Directory). A BLE
advertising packet is a list of *AD structures*, each `[length][AD-type][bytes]`.
Standard AD-types include Flags, Complete Local Name, and **Manufacturer
Specific Data** (type `0xFF`). We carry our reading inside a Manufacturer
Specific Data structure; the "payload" is just the bytes we put in it:

Manufacturer-specific advertising data, little-endian:
```
[company id 0xFFFF (2)] [type] [payload]
  type 'T' (tilt,  from sensor): int16 x, int16 y, int16 z   (0.01 m/s²)   -> 9 bytes
  type 'L' (light, from hub):    uint8 brightness, int16 magnitude          -> 6 bytes
```
`0xFFFF` is the "no company" test id. Everyone scans; each node filters on
`company id + type`. The bulb also hears the raw 'T' beacons and simply ignores
them - only the hub's 'L' beacons drive it, which is what demonstrates the hub's
role.

---

## 8. Multi-node BLE timing: quantum + serial execution

Even for broadcast, keep the nodes in lockstep or scanners miss beacons and
(for the connection experiments) links desync. In the `.resc`/Robot setup:
```
emulation SetGlobalQuantum "0.00001"
emulation SetGlobalSerialExecution True
```
`SerialExecution` was the single change that made the (doomed) connection
approach even establish, and it keeps the beacon scanners reliably catching
advertisements. See doc 10 §8. (`buildResc` emits both.)

---

## 9. How it wires into the web app (`app/server.js`)

`buildResc()` generates `work/run.resc` from the `NODES` array. Changes made for
this firmware:

- **`motion.ble = true`.** The original lab had the sensor as a radio-less node,
  so `buildResc` never connected its radio to the medium - the sensor beaconed
  into the void. It must be a BLE node so it gets
  `connector Connect sysbus.radio wireless`.
- **`SetGlobalSerialExecution true`** added after the quantum line.
- The `NODES` `srcOrigin`/`comms`/`sample` strings were updated to describe the
  beacon relay (they previously described the stock heart-rate samples).
- The sensor slider path is unchanged: `POST /api/sensor` →
  `sysbus.spi2.adxl372 AccelerationX <v>` (value in **g**, clamped ±10).

Deploy after building:
```bash
# ELFs the app actually runs (uploads shadow defaults):
cp build/hub/zephyr/zephyr.elf    firmware/uploads/gateway.elf   # + defaults/
cp build/bulb/zephyr/zephyr.elf   firmware/uploads/heartrate.elf
cp build/motion/zephyr/zephyr.elf firmware/uploads/motion.elf
# reference source shown in the UI:
cp .../hub/src/main.c    firmware/src/gateway.c
cp .../bulb/src/main.c   firmware/src/heartrate.c
cp .../motion/src/main.c firmware/src/motion.c
```

---

## 10. Build & verify - the exact commands

```bash
# Build (venv ACTIVE)
source ~/zephyrproject/.venv/bin/activate
cd ~/zephyrproject
for a in motion bulb hub; do
  west build -p always -b nrf52840dk/nrf52840 apps/tiltlab/$a -d build/$a
done

# Verify (venv NOT active - system python3 has robotframework)
cd /path/to/renode_portable
./renode-test /path/to/tiltlab.robot > out.txt 2>&1   # read out.txt
```

A passing run ends with `Tests finished successfully :)`. The test asserts, in
order: motion `Broadcasting tilt beacon` then `SPI read`; hub `relay online` then
`brightness 0%`; bulb `Light intensity = 0%`; then after
`sysbus.spi2.adxl372 AccelerationX/Y 10`, bulb `driving to full brightness`; then
back to level, bulb `Light intensity = 0%` again (proves sustained relaying).

Live-app smoke test:
```bash
RENODE_PATH=<portable>/renode PORT=4056 node app/server.js &
curl -s -X POST localhost:4056/api/start
curl -s -X POST -H 'Content-Type: application/json' -d '{"axis":"X","value":6}' localhost:4056/api/sensor
# GET /api/events (SSE 'hello' carries the per-node console history)
```

---

## 11. What layer this demo lives at (so you don't over-read it)

It is an **application-layer telemetry + actuation demo riding directly on the
BLE GAP broadcast layer.** Present: the BLE link/advertising layer, our own AD
**message framing**, a tiny **data model** (tilt / light records), and the
**application logic** (tilt→brightness on the hub) + the **SPI device layer** on
the sensor. **Absent by design:** no IP/6LoWPAN, no routing (single broadcast
hop; the hub re-originates, it does not forward), no transport reliability
(fire-and-forget 1 Hz beacons), no connection/session layer (GATT removed), and
**no security** (plaintext beacons, no pairing/encryption). Natural next layers
if you extend it: LE encryption/signed beacons (security), GATT (sessions - but
see §7), or IPv6-over-BLE/Thread (routing).

---

## 12. Quick diagnosis checklist

```
1. "ADXL372 not ready" + "spi2: Unhandled write to offset 0x5xx/0x10"
   → overlay uses nordic,nrf-spim. Switch to nordic,nrf-spi (§3.1).

2. Firmware won't build: "Could NOT find Python3 ... at least 3.12"
   → venv not active, or built without a >=3.12 interpreter. `uv venv --seed` (§2).

3. renode-test: "No module named 'robot'"
   → the Zephyr venv is active. Run renode-test with the system python3 (§2, §5.4).

4. "Error E02: Variable 'nvic' was already declared"
   → used `mach add`; a stale machine was selected. Use `mach create` (§5.1).

5. Central connect fails "-22 / -EINVAL" on the second peer
   → both nodes share the FICR address. Override DEVICEADDR, or (better) go
     connectionless (§6, §7).

6. BLE links drop with "disconnected reason 0x08" / re-adv "-ENOMEM (-12)"
   → you're holding >1 connection. Renode won't sustain it. Use beacons (§7).

7. A command returns bare "exit 144" with no output
   → a `pkill -f <pattern>` matched your own shell, or you passed `--console`
     (§4, §4.1).

8. A `Wait For Line` hangs on a line you can see in the log
   → it was printed before the tester's cursor. Wait for startup-once lines
     first (§5.3).
```

---

Next: nothing - this is the applied capstone. For the machinery underneath, go
back to [01](01-repl-format.md)/[02](02-resc-monitor.md) and
[10](10-robot-testing-gotchas.md).
