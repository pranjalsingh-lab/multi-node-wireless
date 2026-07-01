/*
 * Lighting Hub node.
 *
 * The "brain" between the tilt sensor and the bulb. It listens (BLE observer)
 * for the sensor's tilt beacons, computes a brightness from each reading (the
 * "light calculation"), and re-broadcasts that brightness as its own BLE
 * beacon (BLE broadcaster) for the Smart Bulb to pick up.
 *
 * Connectionless on both sides: the emulated radio handles advertising and
 * scanning far more robustly than multiple live connections.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <zephyr/kernel.h>
#include <zephyr/sys/printk.h>
#include <zephyr/sys/byteorder.h>

#include <zephyr/bluetooth/bluetooth.h>

#define TILTLAB_COMPANY_0  0xFF
#define TILTLAB_COMPANY_1  0xFF
#define BEACON_TYPE_TILT   'T'   /* incoming: from the sensor */
#define BEACON_TYPE_LIGHT  'L'   /* outgoing: to the bulb      */

/* Outgoing light beacon: [company id LE (2)][type 'L'][brightness][mag LE (2)] */
static uint8_t light_mfg[6] = {
	TILTLAB_COMPANY_0, TILTLAB_COMPANY_1, BEACON_TYPE_LIGHT, 0, 0, 0
};

static struct bt_data light_ad[] = {
	BT_DATA(BT_DATA_MANUFACTURER_DATA, light_mfg, sizeof(light_mfg)),
};

/* Integer square root - no libm in the image. */
static uint32_t isqrt(uint32_t n)
{
	uint32_t x, y;

	if (n == 0) {
		return 0;
	}
	x = n;
	y = (x + 1) / 2;
	while (y < x) {
		x = y;
		y = (x + n / x) / 2;
	}
	return x;
}

/* The "light calculation": horizontal tilt magnitude -> 0..100 % brightness.
 * Level fixture (gravity on Z only) -> ~0 %; the more it is tilted or knocked,
 * the brighter it drives the bulb (~1 g of tilt -> ~10 %). */
static uint8_t tilt_to_brightness(int16_t x, int16_t y, uint32_t *mag_out)
{
	uint32_t horiz = isqrt((int32_t)x * x + (int32_t)y * y);
	uint32_t pct = horiz / 100;

	if (pct > 100) {
		pct = 100;
	}
	*mag_out = horiz;
	return (uint8_t)pct;
}

/* Called for each AD element in a received advertisement. */
static bool on_ad(struct bt_data *data, void *user_data)
{
	const uint8_t *d = data->data;
	uint32_t mag;
	uint8_t brightness;
	int16_t x, y, z;

	if (data->type != BT_DATA_MANUFACTURER_DATA || data->data_len < 9) {
		return true;   /* keep parsing */
	}
	if (d[0] != TILTLAB_COMPANY_0 || d[1] != TILTLAB_COMPANY_1 ||
	    d[2] != BEACON_TYPE_TILT) {
		return true;
	}

	x = (int16_t)sys_get_le16(&d[3]);
	y = (int16_t)sys_get_le16(&d[5]);
	z = (int16_t)sys_get_le16(&d[7]);

	brightness = tilt_to_brightness(x, y, &mag);
	light_mfg[3] = brightness;
	sys_put_le16((uint16_t)mag, &light_mfg[4]);

	printk("[HUB] tilt X=%d Y=%d Z=%d -> brightness %u%% (relaying)\n",
	       x, y, z, brightness);
	bt_le_adv_update_data(light_ad, ARRAY_SIZE(light_ad), NULL, 0);

	return false;   /* handled */
}

static void scan_cb(const bt_addr_le_t *addr, int8_t rssi, uint8_t type,
		    struct net_buf_simple *ad)
{
	bt_data_parse(ad, on_ad, NULL);
}

int main(void)
{
	int err;
	struct bt_le_scan_param scan_param = {
		.type = BT_LE_SCAN_TYPE_PASSIVE,
		.options = BT_LE_SCAN_OPT_NONE,
		.interval = BT_GAP_SCAN_FAST_INTERVAL,
		.window = BT_GAP_SCAN_FAST_WINDOW,
	};

	printk("Lighting hub node starting\n");

	err = bt_enable(NULL);
	if (err) {
		printk("Bluetooth init failed (err %d)\n", err);
		return 0;
	}
	printk("Bluetooth initialized\n");

	/* Broadcast our light beacon (starts at 0 %) ... */
	err = bt_le_adv_start(BT_LE_ADV_NCONN, light_ad, ARRAY_SIZE(light_ad),
			      NULL, 0);
	if (err) {
		printk("[HUB] light broadcast failed to start (err %d)\n", err);
		return 0;
	}

	/* ... and listen for the sensor's tilt beacons. */
	err = bt_le_scan_start(&scan_param, scan_cb);
	if (err) {
		printk("[HUB] scan failed to start (err %d)\n", err);
		return 0;
	}
	printk("[HUB] relay online: listening for tilt, broadcasting light\n");

	return 0;
}
