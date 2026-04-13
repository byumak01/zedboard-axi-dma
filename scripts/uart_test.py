#!/usr/bin/env python3
"""
uart_test.py — Hardware-in-the-loop test for HeterosynapticDynamics on ZedBoard.

Usage
-----
    python uart_test.py [--port /dev/ttyUSB0] [--sim output/post_implementation_data.txt]

The script reads simulation inputs from the provided file (pre_in1, pre_in2, post_in
for each of the 2000 steps), sends them to the FPGA via UART, then reads back the
hardware outputs (w1, w2, c1, c2, spikes) and compares them with the simulation.

Protocol (see neural_hw_controller.sv for the FPGA side):
    PC → FPGA:  0xAA  (start marker)
                2000 × 9 bytes  (pre_in1[23:16..7:0], pre_in2[…], post_in[…])
    PC → FPGA:  0xBB  (readback command)
    FPGA → PC:  2000 × 13 bytes (w1[23:0], w2[23:0], c1[23:0], c2[23:0],
                                  {5b0, post_spike, pre2_spike, pre1_spike})
                0xCC  (done marker)

Output
------
    output/hw_output_data.txt  — same format as post_implementation_data.txt
    Prints a per-step diff summary to stdout.
"""

import argparse
import os
import struct
import sys
import time

try:
    import serial
except ImportError:
    print("ERROR: pyserial not installed.  Run: pip install pyserial")
    sys.exit(1)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
BAUD_RATE    = 115200
TOTAL_STEPS  = 2000
MARK_START   = 0xAA
MARK_READBACK= 0xBB
MARK_DONE    = 0xCC

BYTES_PER_INPUT  = 9   # 3 × 24-bit values
BYTES_PER_RESULT = 13  # 4 × 24-bit + 1 byte spikes

# Fixed-point scale for display (Q8.16 → float)
SCALE = 1 << 16

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def u24_to_bytes(val: int):
    """Return three bytes for a 24-bit unsigned value, MSB first."""
    val = int(val) & 0xFFFFFF
    return bytes([(val >> 16) & 0xFF, (val >> 8) & 0xFF, val & 0xFF])


def bytes_to_u24(b0: int, b1: int, b2: int) -> int:
    """Reconstruct a 24-bit value from three bytes, MSB first."""
    return (b0 << 16) | (b1 << 8) | b2


def fp_to_float(val: int) -> float:
    """Convert Q8.16 fixed-point integer to a float."""
    return val / SCALE


# ---------------------------------------------------------------------------
# Parse simulation output file
# ---------------------------------------------------------------------------

def parse_sim_file(path: str):
    """
    Parse post_implementation_data.txt.
    Returns a list of dicts with keys:
        step, pre_in1, pre_in2, post_in,
        pre1_spike, pre2_spike, post_spike,
        w1, w2, c1, c2
    """
    rows = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("step"):
                continue
            parts = [p.strip() for p in line.split(",")]
            if len(parts) < 11:
                continue
            rows.append({
                "step":       int(parts[0]),
                "pre_in1":    int(parts[1]),
                "pre_in2":    int(parts[2]),
                "post_in":    int(parts[3]),
                "pre1_spike": int(parts[4], 2),
                "pre2_spike": int(parts[5], 2),
                "post_spike": int(parts[6], 2),
                "w1":         int(parts[7]),
                "w2":         int(parts[8]),
                "c1":         int(parts[9]),
                "c2":         int(parts[10]),
            })
    return rows


# ---------------------------------------------------------------------------
# UART helpers with timeout and retry
# ---------------------------------------------------------------------------

def uart_read_exact(ser: serial.Serial, n: int, timeout_s: float = 30.0) -> bytes:
    """Read exactly n bytes, blocking until all arrive or timeout."""
    buf = bytearray()
    deadline = time.monotonic() + timeout_s
    while len(buf) < n:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(
                f"Timeout waiting for {n} bytes; got {len(buf)}"
            )
        chunk = ser.read(n - len(buf))
        buf.extend(chunk)
    return bytes(buf)


def uart_read_byte(ser: serial.Serial, timeout_s: float = 30.0) -> int:
    return uart_read_exact(ser, 1, timeout_s)[0]


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="HeterosynapticDynamics hardware-in-the-loop test via UART"
    )
    parser.add_argument(
        "--port", default="/dev/ttyACM1",
        help="Serial port (default: /dev/ttyACM1)"
    )
    parser.add_argument(
        "--sim",
        default=os.path.join(os.path.dirname(__file__),
                             "output", "post_implementation_data.txt"),
        help="Path to simulation output file (provides inputs and reference)"
    )
    parser.add_argument(
        "--baud", type=int, default=BAUD_RATE,
        help=f"Baud rate (default: {BAUD_RATE})"
    )
    args = parser.parse_args()

    # ------------------------------------------------------------------
    # Load simulation data
    # ------------------------------------------------------------------
    print(f"[*] Loading simulation data from: {args.sim}")
    if not os.path.exists(args.sim):
        print(f"ERROR: file not found: {args.sim}")
        sys.exit(1)

    sim_rows = parse_sim_file(args.sim)
    if len(sim_rows) < TOTAL_STEPS:
        print(f"ERROR: expected {TOTAL_STEPS} rows, found {len(sim_rows)}")
        sys.exit(1)
    sim_rows = sim_rows[:TOTAL_STEPS]
    print(f"[*] Loaded {len(sim_rows)} simulation steps.")

    # ------------------------------------------------------------------
    # Open serial port
    # ------------------------------------------------------------------
    print(f"[*] Opening {args.port} at {args.baud} baud …")
    try:
        ser = serial.Serial(
            port=args.port,
            baudrate=args.baud,
            bytesize=serial.EIGHTBITS,
            parity=serial.PARITY_NONE,
            stopbits=serial.STOPBITS_ONE,
            timeout=1.0
        )
    except serial.SerialException as e:
        print(f"ERROR: {e}")
        sys.exit(1)

    # Flush stale data
    ser.reset_input_buffer()
    ser.reset_output_buffer()
    time.sleep(0.1)

    # ------------------------------------------------------------------
    # Send start marker + all inputs
    # ------------------------------------------------------------------
    print(f"[*] Sending start marker (0xAA) + {TOTAL_STEPS} × {BYTES_PER_INPUT} bytes …")
    t0 = time.monotonic()

    ser.write(bytes([MARK_START]))

    for idx, row in enumerate(sim_rows):
        payload = (
            u24_to_bytes(row["pre_in1"]) +
            u24_to_bytes(row["pre_in2"]) +
            u24_to_bytes(row["post_in"])
        )
        ser.write(payload)

        if (idx + 1) % 200 == 0:
            elapsed = time.monotonic() - t0
            rate = (idx + 1) * BYTES_PER_INPUT / elapsed
            print(f"    sent {idx + 1:4d}/{TOTAL_STEPS} steps  "
                  f"({rate:.0f} B/s, {elapsed:.1f} s elapsed)")

    elapsed_send = time.monotonic() - t0
    print(f"[*] All inputs sent in {elapsed_send:.2f} s")

    # ------------------------------------------------------------------
    # Send readback command
    # ------------------------------------------------------------------
    print(f"[*] Sending readback command (0xBB) …")
    ser.write(bytes([MARK_READBACK]))
    
    ser.timeout = 1.0

    # ------------------------------------------------------------------
    # Receive results
    # ------------------------------------------------------------------
    total_rx = TOTAL_STEPS * BYTES_PER_RESULT + 1  # +1 for 0xCC
    print(f"[*] Waiting for {total_rx} bytes from FPGA …")
    t1 = time.monotonic()

    raw = uart_read_exact(ser, total_rx, timeout_s=60.0)

    elapsed_recv = time.monotonic() - t1
    print(f"[*] Received {len(raw)} bytes in {elapsed_recv:.2f} s")

    done_marker = raw[-1]
    if done_marker != MARK_DONE:
        print(f"WARNING: expected done marker 0xCC, got 0x{done_marker:02X}")

    # ------------------------------------------------------------------
    # Parse results
    # ------------------------------------------------------------------
    hw_rows = []
    for i in range(TOTAL_STEPS):
        base = i * BYTES_PER_RESULT
        chunk = raw[base:base + BYTES_PER_RESULT]
        w1_val  = bytes_to_u24(chunk[0],  chunk[1],  chunk[2])
        w2_val  = bytes_to_u24(chunk[3],  chunk[4],  chunk[5])
        c1_val  = bytes_to_u24(chunk[6],  chunk[7],  chunk[8])
        c2_val  = bytes_to_u24(chunk[9],  chunk[10], chunk[11])
        spk_byte= chunk[12]
        hw_rows.append({
            "step":       i + 1,
            "pre_in1":    sim_rows[i]["pre_in1"],
            "pre_in2":    sim_rows[i]["pre_in2"],
            "post_in":    sim_rows[i]["post_in"],
            "pre1_spike": (spk_byte >> 0) & 1,
            "pre2_spike": (spk_byte >> 1) & 1,
            "post_spike": (spk_byte >> 2) & 1,
            "w1": w1_val,
            "w2": w2_val,
            "c1": c1_val,
            "c2": c2_val,
        })

    # ------------------------------------------------------------------
    # Write hardware output file
    # ------------------------------------------------------------------
    out_dir = os.path.join(os.path.dirname(__file__), "output")
    os.makedirs(out_dir, exist_ok=True)
    out_path = os.path.join(out_dir, "hw_output_data.txt")

    with open(out_path, "w") as f:
        f.write("step, pre_in1, pre_in2, post_in, "
                "pre1_spike, pre2_spike, post_spike, "
                "w1, w2, c1, c2\n")
        for row in hw_rows:
            f.write(
                f"{row['step']}, {row['pre_in1']}, {row['pre_in2']}, "
                f"{row['post_in']}, {row['pre1_spike']:b}, "
                f"{row['pre2_spike']:b}, {row['post_spike']:b}, "
                f"{row['w1']}, {row['w2']}, {row['c1']}, {row['c2']}\n"
            )
    print(f"[*] Hardware results written to: {out_path}")

    # ------------------------------------------------------------------
    # Compare with simulation
    # ------------------------------------------------------------------
    print("\n[*] Comparing hardware vs simulation …")
    mismatches = 0
    SIGNALS = ("w1", "w2", "c1", "c2", "pre1_spike", "pre2_spike", "post_spike")

    for i, (hw, sim) in enumerate(zip(hw_rows, sim_rows)):
        diffs = [s for s in SIGNALS if hw[s] != sim[s]]
        if diffs:
            mismatches += 1
            if mismatches <= 10:  # Print first 10 mismatches
                print(f"  Step {i+1:4d}: MISMATCH on {diffs}")
                for s in diffs:
                    print(f"    {s}: HW={hw[s]}  SIM={sim[s]}")

    if mismatches == 0:
        print("  All 2000 steps match exactly. ✓")
    else:
        print(f"  {mismatches}/{TOTAL_STEPS} steps have mismatches.")
        if mismatches > 10:
            print("  (Only first 10 shown above)")

    ser.close()
    print(f"\n[*] Done. Total elapsed: {time.monotonic() - t0:.2f} s")


if __name__ == "__main__":
    main()
