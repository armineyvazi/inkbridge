// aoa-probe: asks an Android device whether it supports Android Open
// Accessory (AOA) mode, without switching it into that mode.
//
// AOA is how a USB host can open a data channel to an Android app without
// USB debugging. Step one of the AOA handshake is a vendor control request
// ACCESSORY_GET_PROTOCOL (bRequest 51); a device that supports AOA answers
// with its protocol version (1 or 2). This tool sends only that read-only
// request. It does NOT send ACCESSORY_START (53), which would re-enumerate
// the device.
//
// Build: cc aoa_probe.c -I/opt/homebrew/include -L/opt/homebrew/lib -lusb-1.0 -o aoa-probe
// Usage: ./aoa-probe [vid] [pid]     (defaults: 0x18d1 0x4ee1, BOOX in MTP mode)
#include <libusb-1.0/libusb.h>
#include <stdio.h>
#include <stdlib.h>

#define ACCESSORY_GET_PROTOCOL 51

int main(int argc, char **argv) {
    unsigned vid = argc > 1 ? strtoul(argv[1], NULL, 16) : 0x18d1;
    unsigned pid = argc > 2 ? strtoul(argv[2], NULL, 16) : 0x4ee1;
    if (libusb_init(NULL) != 0) { fprintf(stderr, "libusb_init failed\n"); return 2; }

    libusb_device_handle *h = libusb_open_device_with_vid_pid(NULL, vid, pid);
    if (!h) { fprintf(stderr, "device %04x:%04x not found or not openable\n", vid, pid); return 2; }

    struct libusb_device_descriptor d;
    libusb_get_device_descriptor(libusb_get_device(h), &d);
    unsigned char s[256] = {0};
    if (d.iManufacturer) libusb_get_string_descriptor_ascii(h, d.iManufacturer, s, sizeof s);
    printf("device %04x:%04x bcdDevice=%04x manufacturer=\"%s\"", vid, pid, d.bcdDevice, s);
    if (d.iProduct && libusb_get_string_descriptor_ascii(h, d.iProduct, s, sizeof s) > 0) printf(" product=\"%s\"", s);
    printf("\n");

    unsigned char buf[2] = {0};
    int r = libusb_control_transfer(h,
        LIBUSB_ENDPOINT_IN | LIBUSB_REQUEST_TYPE_VENDOR | LIBUSB_RECIPIENT_DEVICE,
        ACCESSORY_GET_PROTOCOL, 0, 0, buf, sizeof buf, 1000);
    if (r == 2) {
        int version = buf[0] | buf[1] << 8;
        printf("AOA supported: protocol version %d%s\n", version, version >= 2 ? " (audio/HID extensions available)" : "");
    } else if (r >= 0) {
        printf("AOA: unexpected %d-byte reply\n", r);
    } else {
        printf("AOA not supported or request rejected: %s\n", libusb_error_name(r));
    }
    libusb_close(h);
    libusb_exit(NULL);
    return r == 2 ? 0 : 1;
}
