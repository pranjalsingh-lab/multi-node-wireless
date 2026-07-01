/*
 * Tilt & Tamper Sensor node.
 *
 * Reads a 3-axis ADXL372 accelerometer over SPI (the sensor is wired to this
 * board) and broadcasts the live X/Y/Z tilt as a connectionless BLE beacon
 * (manufacturer-specific advertising data). The Lighting Hub listens for it.
 *
 * Connectionless broadcast is used instead of a GATT connection because the
 * emulated radio models advertising/scanning far more robustly than it models
 * multiple simultaneous connections.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/sys/printk.h>
#include <zephyr/sys/byteorder.h>
#include <zephyr/drivers/sensor.h>

#include <zephyr/bluetooth/bluetooth.h>

/* Beacon framing: [company id LE (2)][type][payload].  0xFFFF is the "no
 * company" test id; type 'T' marks a tilt reading from this sensor. */
#define TILTLAB_COMPANY_0  0xFF
#define TILTLAB_COMPANY_1  0xFF
#define BEACON_TYPE_TILT   'T'

/* payload = int16 X, Y, Z (little-endian), hundredths of m/s^2 */
static uint8_t mfg[9] = { TILTLAB_COMPANY_0, TILTLAB_COMPANY_1, BEACON_TYPE_TILT };

static struct bt_data ad[] = {
	BT_DATA(BT_DATA_MANUFACTURER_DATA, mfg, sizeof(mfg)),
};

/* m/s^2 sensor_value -> signed hundredths of m/s^2 (integer only, no libm). */
static int16_t sv_to_centi(const struct sensor_value *v)
{
	return (int16_t)(v->val1 * 100 + v->val2 / 10000);
}

static const struct device *const accel = DEVICE_DT_GET_ANY(adi_adxl372);

int main(void)
{
	int err;

	printk("Tilt sensor node starting\n");

	if (!device_is_ready(accel)) {
		printk("ADXL372 not ready\n");
		return 0;
	}

	err = bt_enable(NULL);
	if (err) {
		printk("Bluetooth init failed (err %d)\n", err);
		return 0;
	}
	printk("Bluetooth initialized\n");

	/* Non-connectable beacon; we refresh its payload every read. */
	err = bt_le_adv_start(BT_LE_ADV_NCONN, ad, ARRAY_SIZE(ad), NULL, 0);
	if (err) {
		printk("Advertising failed to start (err %d)\n", err);
		return 0;
	}
	printk("Broadcasting tilt beacon\n");

	while (1) {
		struct sensor_value a[3];
		int16_t x, y, z;

		if (sensor_sample_fetch(accel) < 0 ||
		    sensor_channel_get(accel, SENSOR_CHAN_ACCEL_XYZ, a) < 0) {
			printk("sensor read failed\n");
			k_sleep(K_MSEC(1000));
			continue;
		}

		x = sv_to_centi(&a[0]);
		y = sv_to_centi(&a[1]);
		z = sv_to_centi(&a[2]);

		sys_put_le16(x, &mfg[3]);
		sys_put_le16(y, &mfg[5]);
		sys_put_le16(z, &mfg[7]);

		printk("SPI read  X=%d Y=%d Z=%d (0.01 m/s^2) -> beacon\n", x, y, z);
		bt_le_adv_update_data(ad, ARRAY_SIZE(ad), NULL, 0);

		k_sleep(K_MSEC(1000));
	}

	return 0;
}
