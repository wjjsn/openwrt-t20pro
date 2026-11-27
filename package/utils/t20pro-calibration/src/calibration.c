// SPDX-License-Identifier: GPL-2.0-only

#include <ctype.h>
#include <expat.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define EFUSE_SIZE 1536

static const struct {
	const char *name;
	size_t offset, count;
} tables[] = {
	{ "HW_2G_CCK_TSSI_A", 0x210, 6 },
	{ "HW_2G_BW40_1S_TSSI_A", 0x216, 5 },
	{ "HW_5G_BW40_1S_TSSI_A", 0x222, 14 },
	{ "HW_2G_CCK_TSSI_B", 0x23a, 6 },
	{ "HW_2G_BW40_1S_TSSI_B", 0x240, 5 },
	{ "HW_5G_BW40_1S_TSSI_B", 0x24c, 14 },
};

static const struct {
	const char *format;
	size_t offset;
} radio_fields[] = {
	{ "HW_XCAP_WLAN%u_AX", 0x2b9 },
	{ "HW_RFE_TYPE_WLAN%u", 0x2ca },
	{ "HW_THERMAL_A_WLAN%u", 0x2d0 },
	{ "HW_THERMAL_B_WLAN%u", 0x2d1 },
};

struct calibration {
	uint8_t efuse[2][EFUSE_SIZE];
	uint8_t mac[6];
	unsigned int common, radio[2];
};

static int hex_bytes(const char *value, uint8_t *out, size_t count, char separator)
{
	if (strlen(value) != count * 2 + (separator ? count - 1 : 0))
		return 0;
	for (size_t i = 0; i < count; i++) {
		char byte[] = { value[0], value[1], '\0' };

		if (!isxdigit((unsigned char)byte[0]) || !isxdigit((unsigned char)byte[1]))
			return 0;
		out[i] = strtoul(byte, NULL, 16);
		value += 2;
		if (separator && i + 1 < count && *value++ != separator)
			return 0;
	}
	return 1;
}

static int decimal_byte(const char *value, uint8_t *out)
{
	char *end;
	unsigned long number;

	if (!isdigit((unsigned char)*value))
		return 0;
	number = strtoul(value, &end, 10);
	if (*end || number > UINT8_MAX)
		return 0;
	*out = number;
	return 1;
}

static void factory_value(void *data, const char *element, const char **attr)
{
	struct calibration *cal = data;
	const char *name = NULL, *value = NULL;
	char key[40];
	uint8_t byte;

	if (strcmp(element, "Value"))
		return;
	for (; *attr; attr += 2) {
		if (!strcmp(attr[0], "Name"))
			name = attr[1];
		else if (!strcmp(attr[0], "Value"))
			value = attr[1];
	}
	if (!name || !value)
		return;

	for (size_t i = 0; i < sizeof(tables) / sizeof(*tables); i++) {
		if (!strcmp(name, tables[i].name)) {
			if (hex_bytes(value, cal->efuse[0] + tables[i].offset, tables[i].count, ',')) {
				memcpy(cal->efuse[1] + tables[i].offset,
				       cal->efuse[0] + tables[i].offset, tables[i].count);
				cal->common |= 1U << i;
			} else {
				cal->common &= ~(1U << i);
			}
			return;
		}
	}
	if (!strcmp(name, "ELAN_MAC_ADDR")) {
		if (!hex_bytes(value, cal->mac, sizeof(cal->mac), 0))
			memset(cal->mac, 0, sizeof(cal->mac));
		return;
	}
	if (!strcmp(name, "HW_IQK_LCK_MODE")) {
		cal->common &= ~0x40U;
		if (decimal_byte(value, &byte)) {
			cal->efuse[0][0x2bb] = cal->efuse[1][0x2bb] = byte;
			cal->common |= 0x40;
		}
		return;
	}
	for (unsigned int radio = 0; radio < 2; radio++) {
		for (size_t i = 0; i < sizeof(radio_fields) / sizeof(*radio_fields); i++) {
			snprintf(key, sizeof(key), radio_fields[i].format, radio);
			if (!strcmp(name, key)) {
				cal->radio[radio] &= ~(1U << i);
				if (decimal_byte(value, &cal->efuse[radio][radio_fields[i].offset]))
					cal->radio[radio] |= 1U << i;
				return;
			}
		}
		snprintf(key, sizeof(key), "HW_WLAN%u_COUNTRYSTR", radio);
		if (!strcmp(name, key)) {
			cal->radio[radio] &= ~0x10U;
			if (strlen(value) == 2 && value[0] >= 'A' && value[0] <= 'Z' &&
			    value[1] >= 'A' && value[1] <= 'Z') {
				memcpy(cal->efuse[radio] + 0x2cb, value, 2);
				cal->radio[radio] |= 0x10;
			}
			return;
		}
	}
}

static int read_factory(const char *path, struct calibration *cal)
{
	char buffer[4096];
	FILE *file = fopen(path, "r");
	XML_Parser parser;
	int valid = 0;

	if (!file)
		return 0;
	parser = XML_ParserCreate(NULL);
	if (parser) {
		XML_SetUserData(parser, cal);
		XML_SetStartElementHandler(parser, factory_value);
		do {
			size_t n = fread(buffer, 1, sizeof(buffer), file);

			valid = !ferror(file) && XML_Parse(parser, buffer, n, feof(file)) == XML_STATUS_OK;
		} while (valid && !feof(file));
		XML_ParserFree(parser);
	}
	fclose(file);
	return valid;
}

int main(int argc, char **argv)
{
	struct calibration cal = { 0 };
	char path[256];

	memset(cal.efuse, 0xff, sizeof(cal.efuse));
	if (argc != 3 || !read_factory(argv[1], &cal) || cal.common != 0x7f ||
	    cal.radio[0] != 0x1f || cal.radio[1] != 0x1f ||
	    (cal.mac[0] & 1) || !memcmp(cal.mac, (uint8_t[6]){ 0 }, 6)) {
		fputs("Invalid T20 Pro factory calibration\n", stderr);
		return 1;
	}

	for (unsigned int radio = 0; radio < 2; radio++) {
		uint8_t *mac = cal.efuse[radio] + 0x400;
		FILE *file;
		int length, written;

		memcpy(mac, cal.mac, sizeof(cal.mac));
		mac[0] |= 2;
		mac[5] ^= radio + 1;
		length = snprintf(path, sizeof(path), "%s/t20pro-8852ae-%u.bin", argv[2], radio);
		if (length < 0 || (size_t)length >= sizeof(path))
			return 1;
		file = fopen(path, "wb");
		if (!file)
			return 1;
		written = fwrite(cal.efuse[radio], 1, EFUSE_SIZE, file) == EFUSE_SIZE;
		if (fclose(file) || !written) {
			remove(path);
			return 1;
		}
	}
	return 0;
}
