/*
 * Smart Bulb (light fixture) node.
 *
 * A BLE observer that listens for the Lighting Hub's light beacon and drives
 * its LED / prints its live intensity from the brightness the hub computed.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/sys/printk.h>
#include <zephyr/sys/byteorder.h>
#include <zephyr/drivers/gpio.h>

#include <zephyr/bluetooth/bluetooth.h>

#define TILTLAB_COMPANY_0  0xFF
#define TILTLAB_COMPANY_1  0xFF
#define BEACON_TYPE_LIGHT  'L'

#define LED0_NODE DT_ALIAS(led0)
static const struct gpio_dt_spec led = GPIO_DT_SPEC_GET_OR(LED0_NODE, gpios, {0});

/* De-dupe: only print when the intensity actually changes. */
static int last_brightness = -1;

static void apply_brightness(uint8_t pct)
{
	if (led.port) {
		/* No PWM on the modelled board - LED is on above a floor. */
		gpio_pin_set_dt(&led, pct > 0 ? 1 : 0);
	}
}

static bool on_ad(struct bt_data *data, void *user_data)
{
	const uint8_t *d = data->data;
	uint8_t brightness;
	int16_t mag;

	if (data->type != BT_DATA_MANUFACTURER_DATA || data->data_len < 6) {
		return true;
	}
	if (d[0] != TILTLAB_COMPANY_0 || d[1] != TILTLAB_COMPANY_1 ||
	    d[2] != BEACON_TYPE_LIGHT) {
		return true;
	}

	brightness = d[3];
	mag = (int16_t)sys_get_le16(&d[4]);

	if (brightness != last_brightness) {
		last_brightness = brightness;
		printk("Light intensity = %u%%  (tilt magnitude %d)\n",
		       brightness, mag);
		if (brightness >= 80) {
			printk("  -> fixture disturbed: driving to full brightness\n");
		}
		apply_brightness(brightness);
	}

	return false;
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

	printk("Smart bulb node starting\n");

	if (led.port && gpio_is_ready_dt(&led)) {
		gpio_pin_configure_dt(&led, GPIO_OUTPUT_INACTIVE);
	}

	err = bt_enable(NULL);
	if (err) {
		printk("Bluetooth init failed (err %d)\n", err);
		return 0;
	}
	printk("Bluetooth initialized\n");

	err = bt_le_scan_start(&scan_param, scan_cb);
	if (err) {
		printk("Scan failed to start (err %d)\n", err);
		return 0;
	}
	printk("Listening for the hub's light beacon\n");

	return 0;
}
