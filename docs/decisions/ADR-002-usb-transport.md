# ADR-002: USB transport: `adb reverse` for the MVP, Android Open Accessory for production

- Status: accepted (MVP part implemented; AOA part planned)
- Date: 2026-10-31

## Context

The brief requires USB-C, and requires that end users not need developer options.
USB-C does not expose a generic serial port. The BOOX enumerates as an MTP device
(`18d1:4ee1`, "ONYX", "BENGALP-IOT-IDP"). Details in
[`research/usb-research.md`](../research/usb-research.md).

| Option | Needs USB debugging | Mac-side code | Status on Note Air 3 |
|--------|--------------------|---------------|----------------------|
| `adb reverse tcp:8765 tcp:8765` | **yes** | none (plain TCP on loopback) | used for MVP; hardware test pending USB debugging |
| USB tethering (RNDIS/NCM) + TCP | no | none, but macOS has **no RNDIS driver**; NCM support depends on the device | not pursued |
| **Android Open Accessory (AOA)** | **no** | user-space USB (IOUSBHost or libusb): control requests 51–53, then bulk I/O | **AOA protocol v2 confirmed** (`ACCESSORY_GET_PROTOCOL` → 2) with debugging off |
| Custom USB gadget function | no | — | needs a custom kernel; impossible on retail devices |

## Decision

1. **MVP:** `AdbReverseTransport`. The tablet dials `127.0.0.1:8765`, adbd tunnels to
   the Mac's `localhost:8765`, and the Mac's loopback listener accepts it. It needs no
   Mac USB code and no special permissions, and the protocol is debuggable with `nc`.
2. **Production:** `NativeUsbTransport` over AOA. The Mac sends the identification
   strings and `ACCESSORY_START`; the tablet re-enumerates as `18d1:2d00/2d01`;
   Android offers InkBridge through a `USB_ACCESSORY_ATTACHED` intent filter; both
   sides exchange **the same frames** over the bulk endpoints.

## Consequences

- No protocol change is needed for AOA, because the framing is transport-neutral.
- The MVP depends on developer options. The UI and docs label it as a developer
  workflow, so it does not quietly become the end-user path.
- AOA risks to retire in Phase 5:
  - What happens to MTP while in accessory mode.
  - Whether the BOOX launcher shows the accessory permission dialog normally.
  - Re-enumeration timing (the < 3 s reconnect target).
  - IOUSBHost interface claiming on macOS without a DriverKit extension. libusb
    works for control transfers today.
