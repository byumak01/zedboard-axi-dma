#!/usr/bin/env python3
"""
usb_dma_nn_test.py -- Run the heterosynaptic dynamics model over the USB/DMA bridge.

The script reads the 2000-step reference file, chunks the inputs into USB-sized
batches, sends them to the ZedBoard NN bridge, collects the results, writes
them back out in the same CSV format, and compares them against the reference.
"""

from __future__ import annotations

import argparse
import os
import sys
import time
from typing import List

try:
    import usb.core
    import usb.util
except ImportError as exc:
    print("PyUSB is required. Install it with: python3 -m pip install pyusb", file=sys.stderr)
    raise SystemExit(1) from exc


DEFAULT_VID = 0x0D7D
DEFAULT_PID = 0x0200
DEFAULT_INTERFACE = 0
DEFAULT_OUT_EP = 0x01
DEFAULT_IN_EP = 0x81
DEFAULT_TIMEOUT_MS = 5000

TOTAL_STEPS = 2000
CMD_RUN_BATCH = 0xA5
FLAG_RESET = 0x01
HEADER_BYTES = 4
BYTES_PER_INPUT = 9
BYTES_PER_RESULT = 13
USB_BULK_MAX_PACKET = 512
MAX_STEPS_PER_BATCH = (USB_BULK_MAX_PACKET - HEADER_BYTES) // BYTES_PER_INPUT


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run the heterosynaptic dynamics model over the ZedBoard USB/DMA bridge."
    )
    parser.add_argument("--vid", type=lambda value: int(value, 0), default=DEFAULT_VID)
    parser.add_argument("--pid", type=lambda value: int(value, 0), default=DEFAULT_PID)
    parser.add_argument("--interface", type=int, default=DEFAULT_INTERFACE)
    parser.add_argument("--out-ep", type=lambda value: int(value, 0), default=DEFAULT_OUT_EP)
    parser.add_argument("--in-ep", type=lambda value: int(value, 0), default=DEFAULT_IN_EP)
    parser.add_argument("--timeout-ms", type=int, default=DEFAULT_TIMEOUT_MS)
    parser.add_argument(
        "--sim",
        default=os.path.join(os.path.dirname(__file__), "output", "post_implementation_data.txt"),
        help="Path to the simulation CSV used for both inputs and reference outputs.",
    )
    parser.add_argument(
        "--output",
        default=os.path.join(os.path.dirname(__file__), "output", "usb_dma_hw_output_data.txt"),
        help="Where to write the captured hardware results.",
    )
    parser.add_argument(
        "--chunk-steps",
        type=int,
        default=MAX_STEPS_PER_BATCH,
        help=f"Number of simulation steps per USB batch (max {MAX_STEPS_PER_BATCH}).",
    )
    return parser.parse_args()


def parse_sim_file(path: str) -> List[dict]:
    rows: List[dict] = []
    with open(path, encoding="utf-8") as infile:
        for line in infile:
            line = line.strip()
            if not line or line.startswith("step"):
                continue
            parts = [part.strip() for part in line.split(",")]
            if len(parts) < 11:
                continue
            rows.append(
                {
                    "step": int(parts[0]),
                    "pre_in1": int(parts[1]),
                    "pre_in2": int(parts[2]),
                    "post_in": int(parts[3]),
                    "pre1_spike": int(parts[4], 2),
                    "pre2_spike": int(parts[5], 2),
                    "post_spike": int(parts[6], 2),
                    "w1": int(parts[7]),
                    "w2": int(parts[8]),
                    "c1": int(parts[9]),
                    "c2": int(parts[10]),
                }
            )
    return rows


def u24_to_bytes(value: int) -> bytes:
    value &= 0xFFFFFF
    return bytes([(value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF])


def bytes_to_u24(data: bytes) -> int:
    return (data[0] << 16) | (data[1] << 8) | data[2]


def build_batch(rows: List[dict], reset_state: bool) -> bytes:
    count = len(rows)
    header = bytes(
        [
            CMD_RUN_BATCH,
            FLAG_RESET if reset_state else 0,
            (count >> 8) & 0xFF,
            count & 0xFF,
        ]
    )
    payload = bytearray(header)
    for row in rows:
        payload.extend(u24_to_bytes(row["pre_in1"]))
        payload.extend(u24_to_bytes(row["pre_in2"]))
        payload.extend(u24_to_bytes(row["post_in"]))
    return bytes(payload)


def usb_read_exact(
    device: usb.core.Device,
    endpoint: int,
    expected_length: int,
    timeout_ms: int,
) -> bytes:
    received = bytearray()
    while len(received) < expected_length:
        chunk = device.read(endpoint, expected_length - len(received), timeout=timeout_ms)
        received.extend(bytes(chunk))
    return bytes(received)


def detach_kernel_driver(device: usb.core.Device, interface: int) -> bool:
    try:
        if device.is_kernel_driver_active(interface):
            device.detach_kernel_driver(interface)
            return True
    except (NotImplementedError, usb.core.USBError):
        return False
    return False


def looks_like_loopback_echo(request: bytes, reply: bytes) -> bool:
    if len(reply) < len(request):
        return False
    if reply[: len(request)] != request:
        return False
    return all(byte == 0 for byte in reply[len(request):])


def write_output_csv(path: str, rows: List[dict]) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as outfile:
        outfile.write(
            "step, pre_in1, pre_in2, post_in, "
            "pre1_spike, pre2_spike, post_spike, w1, w2, c1, c2\n"
        )
        for row in rows:
            outfile.write(
                f"{row['step']}, {row['pre_in1']}, {row['pre_in2']}, {row['post_in']}, "
                f"{row['pre1_spike']:b}, {row['pre2_spike']:b}, {row['post_spike']:b}, "
                f"{row['w1']}, {row['w2']}, {row['c1']}, {row['c2']}\n"
            )


def compare_rows(hw_rows: List[dict], sim_rows: List[dict]) -> int:
    mismatches = 0
    signals = ("w1", "w2", "c1", "c2", "pre1_spike", "pre2_spike", "post_spike")

    for index, (hw_row, sim_row) in enumerate(zip(hw_rows, sim_rows), start=1):
        diffs = [signal for signal in signals if hw_row[signal] != sim_row[signal]]
        if diffs:
            mismatches += 1
            if mismatches <= 10:
                print(f"  Step {index:4d}: MISMATCH on {diffs}")
                for signal in diffs:
                    print(f"    {signal}: HW={hw_row[signal]}  SIM={sim_row[signal]}")

    return mismatches


def main() -> int:
    args = parse_args()

    if args.chunk_steps <= 0 or args.chunk_steps > MAX_STEPS_PER_BATCH:
        print(
            f"--chunk-steps must be in the range 1..{MAX_STEPS_PER_BATCH}",
            file=sys.stderr,
        )
        return 1

    print(f"[*] Loading simulation data from: {args.sim}")
    if not os.path.exists(args.sim):
        print(f"ERROR: file not found: {args.sim}", file=sys.stderr)
        return 1

    sim_rows = parse_sim_file(args.sim)
    if len(sim_rows) < TOTAL_STEPS:
        print(f"ERROR: expected {TOTAL_STEPS} rows, found {len(sim_rows)}", file=sys.stderr)
        return 1
    sim_rows = sim_rows[:TOTAL_STEPS]
    print(f"[*] Loaded {len(sim_rows)} simulation steps.")

    device = usb.core.find(idVendor=args.vid, idProduct=args.pid)
    if device is None:
        print(
            f"USB device {args.vid:#06x}:{args.pid:#06x} not found. "
            "Program the FPGA, run the ELF, and connect the OTG port to the host.",
            file=sys.stderr,
        )
        return 1

    detached = False
    hw_rows: List[dict] = []
    started_at = time.monotonic()

    try:
        device.set_configuration()
        detached = detach_kernel_driver(device, args.interface)
        usb.util.claim_interface(device, args.interface)

        total_batches = (TOTAL_STEPS + args.chunk_steps - 1) // args.chunk_steps
        print(
            f"[*] Streaming {TOTAL_STEPS} steps in {total_batches} USB batches "
            f"({args.chunk_steps} steps per batch max)."
        )

        for batch_index, start in enumerate(range(0, TOTAL_STEPS, args.chunk_steps), start=1):
            chunk = sim_rows[start:start + args.chunk_steps]
            request = build_batch(chunk, reset_state=(batch_index == 1))
            expected_reply = len(chunk) * BYTES_PER_RESULT

            device.write(args.out_ep, request, timeout=args.timeout_ms)
            reply = usb_read_exact(device, args.in_ep, expected_reply, args.timeout_ms)

            if looks_like_loopback_echo(request, reply):
                print(
                    "ERROR: The USB reply is just the original request echoed back and zero-padded. "
                    "This usually means the FPGA is still running the old AXI DMA loopback "
                    "bitstream instead of the NN bridge bitstream.",
                    file=sys.stderr,
                )
                print(
                    "Recreate/program the Vivado hardware design, then rerun the Vitis app.",
                    file=sys.stderr,
                )
                return 3

            for offset, sim_row in enumerate(chunk):
                base = offset * BYTES_PER_RESULT
                result = reply[base:base + BYTES_PER_RESULT]
                spk_byte = result[12]
                hw_rows.append(
                    {
                        "step": sim_row["step"],
                        "pre_in1": sim_row["pre_in1"],
                        "pre_in2": sim_row["pre_in2"],
                        "post_in": sim_row["post_in"],
                        "pre1_spike": (spk_byte >> 0) & 1,
                        "pre2_spike": (spk_byte >> 1) & 1,
                        "post_spike": (spk_byte >> 2) & 1,
                        "w1": bytes_to_u24(result[0:3]),
                        "w2": bytes_to_u24(result[3:6]),
                        "c1": bytes_to_u24(result[6:9]),
                        "c2": bytes_to_u24(result[9:12]),
                    }
                )

            print(
                f"    batch {batch_index:02d}/{total_batches}: "
                f"sent {len(request)} B, received {len(reply)} B"
            )

        write_output_csv(args.output, hw_rows)
        print(f"[*] Hardware results written to: {args.output}")

        print("\n[*] Comparing hardware vs simulation ...")
        mismatches = compare_rows(hw_rows, sim_rows)
        if mismatches == 0:
            print("  All 2000 steps match exactly.")
        else:
            print(f"  {mismatches}/{TOTAL_STEPS} steps have mismatches.")
            if mismatches > 10:
                print("  (Only the first 10 mismatches are shown above)")

        print(f"\n[*] Done. Total elapsed: {time.monotonic() - started_at:.2f} s")
        return 0 if mismatches == 0 else 2
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
    raise SystemExit(main())
