# USB research

## What the Note Air 3 exposes over USB-C (hardware verified, 2026-10-31)

Connected to a MacBook through a USB-C hub (VIA Labs USB 3.0/2.0 hub), with USB debugging **off**:

```
idVendor   = 0x18d1 (Google)      ← BOOX uses Google's VID for its gadget functions
idProduct  = 0x4ee1 (MTP)         ← 0x4ee2 would be MTP+ADB
bcdDevice  = 0x0419
Manufacturer = "ONYX"
Product      = "BENGALP-IOT-IDP _SN:00E2B01C"
Device speed = high speed (USB 2.0); bNumConfigurations = 1
```

Source: `ioreg -p IOUSB -l` and `tools/aoa-probe`. "BENGALP" suggests Qualcomm's
Bengal platform (SM6115-class). That is an inference, not a verified fact.

There is no CDC-ACM or other serial interface. USB-C carries **MTP only** by default.

## Option A: `adb reverse` (implemented)

```bash
adb reverse tcp:8765 tcp:8765
```

Direction (per `adb help`: `reverse REMOTE LOCAL`, *remote* being the device): a
connection to `127.0.0.1:8765` **on the tablet** is forwarded by adbd over USB to
`localhost:8765` **on the Mac**. Hardware confirmation: see
[hardware-feasibility.md](hardware-feasibility.md). The tablet is the TCP client and the Mac is the server, so the Mac
listener binds only to loopback.

| + | − |
|---|---|
| no Mac USB code; plain sockets; `nc`/Wireshark-debuggable | needs Developer options → USB debugging, a security-sensitive setting |
| works over any cable that carries data | the rule is lost when adbd restarts or the cable is replugged; reapply with `scripts/adb-usb.sh` |
| adb tunnelling adds well under 1 ms of latency (to be measured on hardware) | an "authorize this computer" prompt on first use |

## Option B: Android Open Accessory (AOA) (verified feasible, not implemented)

AOA lets a USB host (the Mac) ask an Android device to switch into *accessory mode*.
The device then re-enumerates with VID `18d1` and PID `2d00` (accessory) or `2d01`
(accessory + adb), exposing one bulk IN/OUT pair. An app that declares the
accessory's identification strings gets a `UsbAccessory` and a `ParcelFileDescriptor`
to read and write.

The handshake (host side):

1. `GET_PROTOCOL` (vendor IN, bRequest **51**) → 2-byte version.
2. `SEND_STRING` (bRequest **52**) × 6: manufacturer, model, description, version, URI, serial.
3. `START` (bRequest **53**) → the device re-enumerates.

**Test, 2026-10-31, USB debugging off:**

```
$ tools/aoa-probe/aoa-probe
device 18d1:4ee1 bcdDevice=0419 manufacturer="ONYX" product="BENGALP-IOT-IDP _SN:00E2B01C"
AOA supported: protocol version 2 (audio/HID extensions available)
```

So the BOOX kernel includes the `f_accessory` gadget function. Only step 1 was sent:
steps 2–3 switch the device out of MTP and would need the Android side to be ready.

| + | − |
|---|---|
| **no developer options**; the normal end-user path | Mac needs user-space USB: libusb (works today for control transfers) or IOUSBHost; possibly a DriverKit entitlement for distribution |
| same byte stream, so the existing framing works unchanged | MTP file transfer is unavailable while in accessory mode |
| first-run permission dialog on the tablet ("Open InkBridge when this accessory is connected?") | more moving parts: re-enumeration, permission, replug handling |

## Option C: USB networking (tethering): rejected

RNDIS has no macOS driver. CDC-NCM tethering is not offered on most Android 12
devices without root. Even where it works, it changes the Mac's network
configuration, which is too invasive for a drawing tablet.

## Recommendation

`adb reverse` for development now. AOA as `NativeUsbTransport` in Phase 5, with
`tools/aoa-probe` grown into a full handshake test first. See
[ADR-002](../decisions/ADR-002-usb-transport.md).
