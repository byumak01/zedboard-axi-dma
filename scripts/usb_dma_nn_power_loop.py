#!/usr/bin/env python3
"""
usb_dma_nn_power_loop.py -- Continuously stream the USB/DMA NN workload.

This variant is intended for power measurements on hardware. It repeats the
same 2000-step stimulus indefinitely by default, or until an iteration/time
limit is reached.
"""

from __future__ import annotations

import argparse
import os
import sys
import time
from typing import List, Tuple

try:
    import usb.core
    import usb.util
except ImportError as exc:
    print("PyUSB is required. Install it with: python3 -m pip install pyusb", file=sys.stderr)
    raise SystemExit(1) from exc

from usb_dma_nn_test import (
    BYTES_PER_RESULT,
    DEFAULT_IN_EP,
    DEFAULT_INTERFACE,
    DEFAULT_OUT_EP,
    DEFAULT_PID,
    DEFAULT_TIMEOUT_MS,
    DEFAULT_VID,
    MAX_STEPS_PER_BATCH,
    TOTAL_STEPS,
    build_batch,
    bytes_to_u24,
    compare_rows,
    detect_one_step_lag,
    detach_kernel_driver,
    looks_like_loopback_echo,
    parse_sim_file,
    usb_read_exact,
    write_output_csv,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Continuously run the heterosynaptic dynamics model over the ZedBoard USB/DMA bridge."
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
        default=None,
        help="Optional CSV path for the most recently captured hardware results.",
    )
    parser.add_argument(
        "--chunk-steps",
        type=int,
        default=MAX_STEPS_PER_BATCH,
        help=f"Number of simulation steps per USB batch (max {MAX_STEPS_PER_BATCH}).",
    )
    parser.add_argument(
        "--iterations",
        type=int,
        default=0,
        help="Number of full 2000-step passes to run. Use 0 to run until stopped.",
    )
    parser.add_argument(
        "--duration-s",
        type=float,
        default=0.0,
        help="Optional elapsed-time limit in seconds. Use 0 to disable.",
    )
    parser.add_argument(
        "--status-interval-s",
        type=float,
        default=5.0,
        help="Print a throughput summary every N seconds. Use 0 to print every pass.",
    )
    parser.add_argument(
        "--skip-compare",
        action="store_true",
        help="Skip the first-pass hardware-vs-simulation comparison.",
    )
    parser.add_argument(
        "--no-reset-each-pass",
        action="store_true",
        help="Only assert reset on the very first pass instead of every pass.",
    )
    return parser.parse_args()


def run_pass(
    device: usb.core.Device,
    args: argparse.Namespace,
    sim_rows: List[dict],
    *,
    reset_state: bool,
    capture_rows: bool,
) -> Tuple[List[dict], int, int]:
    hw_rows: List[dict] = []
    sent_bytes = 0
    received_bytes = 0

    for batch_index, start in enumerate(range(0, TOTAL_STEPS, args.chunk_steps), start=1):
        chunk = sim_rows[start:start + args.chunk_steps]
        request = build_batch(chunk, reset_state=(reset_state and batch_index == 1))
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
            raise SystemExit(3)

        sent_bytes += len(request)
        received_bytes += len(reply)

        if not capture_rows:
            continue

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

    return hw_rows, sent_bytes, received_bytes


def print_status(pass_count: int, total_sent: int, total_received: int, started_at: float) -> None:
    elapsed = max(time.monotonic() - started_at, 1e-9)
    total_steps = pass_count * TOTAL_STEPS
    total_mib = (total_sent + total_received) / (1024 * 1024)
    print(
        f"[*] passes={pass_count} steps={total_steps} elapsed={elapsed:.1f} s "
        f"rate={pass_count / elapsed:.2f} pass/s ({total_steps / elapsed:.0f} steps/s) "
        f"usb={total_mib:.2f} MiB"
    )


def main() -> int:
    args = parse_args()

    if args.chunk_steps <= 0 or args.chunk_steps > MAX_STEPS_PER_BATCH:
        print(
            f"--chunk-steps must be in the range 1..{MAX_STEPS_PER_BATCH}",
            file=sys.stderr,
        )
        return 1
    if args.iterations < 0:
        print("--iterations must be >= 0", file=sys.stderr)
        return 1
    if args.duration_s < 0:
        print("--duration-s must be >= 0", file=sys.stderr)
        return 1
    if args.status_interval_s < 0:
        print("--status-interval-s must be >= 0", file=sys.stderr)
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
    pass_count = 0
    total_sent = 0
    total_received = 0
    last_status_at = 0.0
    last_hw_rows: List[dict] = []
    started_at = time.monotonic()
    stop_reason = "completed"

    if args.iterations == 0 and args.duration_s == 0:
        print("[*] Running continuously until Ctrl-C.")
    elif args.iterations > 0 and args.duration_s > 0:
        print(f"[*] Running for up to {args.iterations} passes or {args.duration_s:.1f} s.")
    elif args.iterations > 0:
        print(f"[*] Running for {args.iterations} passes.")
    else:
        print(f"[*] Running for {args.duration_s:.1f} s.")

    try:
        device.set_configuration()
        detached = detach_kernel_driver(device, args.interface)
        usb.util.claim_interface(device, args.interface)

        while True:
            now = time.monotonic()
            if args.iterations > 0 and pass_count >= args.iterations:
                stop_reason = f"reached pass limit ({args.iterations})"
                break
            if args.duration_s > 0 and now - started_at >= args.duration_s:
                stop_reason = f"reached time limit ({args.duration_s:.1f} s)"
                break

            pass_count += 1
            capture_rows = (pass_count == 1 and not args.skip_compare) or (args.output is not None)
            hw_rows, sent_bytes, received_bytes = run_pass(
                device,
                args,
                sim_rows,
                reset_state=(pass_count == 1 or not args.no_reset_each_pass),
                capture_rows=capture_rows,
            )
            total_sent += sent_bytes
            total_received += received_bytes

            if capture_rows:
                last_hw_rows = hw_rows

            if pass_count == 1 and not args.skip_compare:
                print("[*] Comparing first pass against simulation ...")
                mismatches = compare_rows(hw_rows, sim_rows)
                if mismatches == 0:
                    print("  First pass matches all 2000 steps.")
                else:
                    if detect_one_step_lag(hw_rows, sim_rows):
                        print(
                            "  Diagnosis: hardware matches the reference with a one-step lag. "
                            "This is the bridge sampling hd_neuron outputs one clock too early. "
                            "Rebuild and reprogram the updated FPGA design.",
                            file=sys.stderr,
                        )
                    print(f"  {mismatches}/{TOTAL_STEPS} steps have mismatches.", file=sys.stderr)
                    if mismatches > 10:
                        print("  (Only the first 10 mismatches are shown above)", file=sys.stderr)
                    #return 2

            if args.status_interval_s == 0 or time.monotonic() - last_status_at >= args.status_interval_s:
                print_status(pass_count, total_sent, total_received, started_at)
                last_status_at = time.monotonic()

    except KeyboardInterrupt:
        stop_reason = "stopped by user"
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

    if args.output and last_hw_rows:
        write_output_csv(args.output, last_hw_rows)
        print(f"[*] Hardware results written to: {args.output}")

    print_status(pass_count, total_sent, total_received, started_at)
    print(f"[*] Stopped: {stop_reason}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
