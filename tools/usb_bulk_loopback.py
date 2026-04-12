#!/usr/bin/env python3
"""Send a USB bulk packet to the ZedBoard bridge app and verify the echoed data."""

from __future__ import annotations

import argparse
import sys
from typing import Optional

try:
    import usb.core
    import usb.util
except ImportError as exc:  # pragma: no cover - exercised by direct execution
    print("PyUSB is required. Install it with: python3 -m pip install pyusb", file=sys.stderr)
    raise SystemExit(1) from exc


DEFAULT_VID = 0x0D7D
DEFAULT_PID = 0x0200
DEFAULT_INTERFACE = 0
DEFAULT_OUT_EP = 0x01
DEFAULT_IN_EP = 0x81
DEFAULT_TIMEOUT_MS = 2000


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Exercise the ZedBoard USB bulk bridge and verify the echoed payload."
    )
    parser.add_argument("--vid", type=lambda value: int(value, 0), default=DEFAULT_VID)
    parser.add_argument("--pid", type=lambda value: int(value, 0), default=DEFAULT_PID)
    parser.add_argument("--interface", type=int, default=DEFAULT_INTERFACE)
    parser.add_argument("--out-ep", type=lambda value: int(value, 0), default=DEFAULT_OUT_EP)
    parser.add_argument("--in-ep", type=lambda value: int(value, 0), default=DEFAULT_IN_EP)
    parser.add_argument("--timeout-ms", type=int, default=DEFAULT_TIMEOUT_MS)
    parser.add_argument(
        "--text",
        default="hello from host",
        help="ASCII payload to send. Ignored when --hex is provided.",
    )
    parser.add_argument(
        "--hex",
        dest="hex_payload",
        help="Hex payload to send, for example: 'de ad be ef' or 'deadbeef'.",
    )
    return parser.parse_args()


def parse_hex_payload(text: str) -> bytes:
    compact = text.replace(" ", "").replace(":", "").replace("-", "")
    return bytes.fromhex(compact)


def build_payload(args: argparse.Namespace) -> bytes:
    if args.hex_payload:
        payload = parse_hex_payload(args.hex_payload)
    else:
        payload = args.text.encode("ascii")

    if not payload:
        raise ValueError("Payload must not be empty.")
    if len(payload) > 512:
        raise ValueError("Payload must be 512 bytes or smaller for the current firmware.")
    return payload


def detach_kernel_driver(device: usb.core.Device, interface: int) -> bool:
    try:
        if device.is_kernel_driver_active(interface):
            device.detach_kernel_driver(interface)
            return True
    except (NotImplementedError, usb.core.USBError):
        return False
    return False


def format_bytes(data: bytes) -> str:
    return " ".join(f"{byte:02x}" for byte in data)


def main() -> int:
    args = parse_args()
    payload = build_payload(args)

    device = usb.core.find(idVendor=args.vid, idProduct=args.pid)
    if device is None:
        print(
            f"USB device {args.vid:#06x}:{args.pid:#06x} not found. "
            "Program the FPGA, run the ELF, and connect the OTG port to the host.",
            file=sys.stderr,
        )
        return 1

    detached = False
    try:
        device.set_configuration()
        detached = detach_kernel_driver(device, args.interface)
        usb.util.claim_interface(device, args.interface)

        written = device.write(args.out_ep, payload, timeout=args.timeout_ms)
        reply = bytes(device.read(args.in_ep, len(payload), timeout=args.timeout_ms))

        print(f"wrote {written} byte(s): {format_bytes(payload)}")
        print(f"read  {len(reply)} byte(s): {format_bytes(reply)}")

        if reply != payload:
            print("loopback mismatch", file=sys.stderr)
            return 2

        print("loopback ok")
        return 0
    except usb.core.USBError as exc:
        print(f"USB transfer failed: {exc}", file=sys.stderr)
        return 1
    finally:
        try:
            usb.util.release_interface(device, args.interface)
        except usb.core.USBError:
            pass
        if detached:
            try:
                device.attach_kernel_driver(args.interface)
            except usb.core.USBError:
                pass
        usb.util.dispose_resources(device)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(1) from exc
