# Architecture Notes

This note documents the current USB/DMA spiking-neural-network flow in the
repository. It is intended as a codebase guide for future maintenance rather
than as a user tutorial.

## Scope

The active data path in this repo is:

`host Python -> USB bulk OUT -> Zynq PS USB device stack -> DDR -> AXI DMA -> PL bridge -> hd_neuron -> AXI DMA -> DDR -> USB bulk IN -> host Python`

The design is split between:

- Host-side tooling in `scripts/`
- PS-side firmware in `Vitis/common/src/`
- PL-side batch bridge and NN RTL in `Vivado/src/new/`
- Vivado/Vitis scripted build flow in `Vivado/` and `Vitis/`

## Why The Design Is Split This Way

### USB stays in the PS

The ZedBoard already has a hard USB controller in the Zynq PS. Using that block
avoids building a custom USB device stack in PL and lets the firmware expose a
simple vendor-specific bulk interface.

### PL only sees AXI-stream batches

The PL side is intentionally kept unaware of USB protocol details. The custom
RTL bridge receives a framed AXI-stream command, unpacks a batch of NN inputs,
executes `hd_neuron` step-by-step, and emits a framed response stream.

This separation keeps responsibilities clean:

- USB enumeration, endpoint handling, and cache management are software tasks.
- Deterministic per-step NN execution is a hardware task.

### AXI DMA is the boundary between software and hardware

The AXI DMA engine converts DDR-backed software buffers into AXI-stream traffic
for the PL bridge, and vice versa. Scatter-gather mode was kept because the
original project already used it and it cleanly supports the required MM2S and
S2MM channels.

### 24-bit values are preserved end-to-end

`hd_neuron` uses 24-bit fixed-point quantities. The host protocol therefore
packs every NN scalar as a 24-bit big-endian field instead of rounding up to
32 bits on the wire. This keeps USB traffic smaller and makes the host test
format match the RTL data width directly.

### The PL clock runs at 50 MHz

The current block design drives the custom bridge from PS `FCLK_CLK0` at
50 MHz. The repo previously had timing violations at 100 MHz on the ZedBoard
speed grade. Lowering the PL clock provides comfortable timing margin while
remaining more than adequate for the low-bandwidth USB batch workload.

## End-To-End Protocol

The active request opcode is `0xA5` (`NN_CMD_RUN_BATCH`).

Request frame:

- byte 0: command = `0xA5`
- byte 1: flags
- bytes 2..3: big-endian step count
- payload: `step_count * 9` bytes
- each step is:
  - `pre_in1` as 24-bit big-endian
  - `pre_in2` as 24-bit big-endian
  - `post_in` as 24-bit big-endian

Response frame:

- no separate response header
- payload only: `step_count * 13` bytes
- each step is:
  - `w1` as 24-bit big-endian
  - `w2` as 24-bit big-endian
  - `c1` as 24-bit big-endian
  - `c2` as 24-bit big-endian
  - one spike byte `{5'b0, post_spike, pre2_spike, pre1_spike}`

The current flag usage is:

- `bit0`: reset NN state before executing the batch

### Why the maximum batch size is 56 steps

USB bulk OUT transfers are capped at 512 bytes in this design. The request has
4 bytes of header and each NN input step costs 9 bytes, so:

`floor((512 - 4) / 9) = 56`

The response is larger (`56 * 13 = 728` bytes), which means a single logical
reply may span multiple USB packets on the IN endpoint. The host script already
handles that by reading until the full expected response length is collected.

## Hardware Structure

### Block design

The main block design is created by `Vivado/src/bd/design_1.tcl`.

Key blocks:

- `processing_system7_0`
- `axi_dma_0`
- `hd_dma_stream_bridge_0`
- interrupt concat for DMA completion IRQ lines

Key connections:

- PS `M_AXI_GP0` controls the AXI DMA register interface
- PS `S_AXI_HP0` gives the DMA high-performance DDR access
- DMA `M_AXIS_MM2S` feeds the custom bridge input stream
- Bridge `M_AXIS` feeds DMA `S_AXIS_S2MM`

### `hd_dma_stream_bridge.v`

`Vivado/src/new/hd_dma_stream_bridge.v` is the active PL-side protocol engine.

Internal phases:

- `ST_RECV`: collect and parse the framed request
- `ST_PROC_RESET`: optionally reset the NN state
- `ST_PROC_LOAD`: drive one step of input currents into `hd_neuron`
- `ST_PROC_EN`: pulse `nn_en`
- `ST_PROC_WAIT`: give `hd_neuron` one clock to update registered outputs
- `ST_PROC_CAP`: capture output scalars into the response buffer
- `ST_SEND`: emit the response as AXI-stream words with `TKEEP/TLAST`

Important design choices:

- The bridge starts processing once the advertised payload length has been
  consumed. It does not rely on input `TLAST` to begin execution.
- The extra `ST_PROC_WAIT` state exists because `hd_neuron` updates its state
  on the cycle after `nn_en` is asserted. Sampling in the same cycle would
  return the previous step's outputs.
- Responses are buffered internally before transmit. This keeps transmit logic
  simple and decouples per-step NN execution from AXI-stream backpressure.

### `hd_neuron.v` and submodules

`Vivado/src/new/hd_neuron.v` composes:

- three `simplified_neuron` instances
- one `synapse` instance

The neuron outputs and synapse state are updated synchronously when `en` is
asserted. The bridge and the AXI-Lite wrapper both account for that by waiting
one cycle before latching result values.

### `hd_hw.v`

`Vivado/src/new/hd_hw.v` is a separate AXI4-Lite wrapper around `hd_neuron`.
It is not part of the main USB/DMA path, but it is kept as a simpler direct
register interface for bring-up and experimentation.

The wrapper uses the same `PROC -> WAIT -> LATCH` timing model as the stream
bridge for the same reason: `hd_neuron` outputs are only valid after the
registered update completes.

## Software Structure

### `usb_dma_bridge.c`

`Vitis/common/src/usb_dma_bridge.c` is the PS application that turns the board
into a USB bulk NN bridge.

Responsibilities:

- initialize AXI DMA in scatter-gather mode
- initialize the PS USB device controller
- expose one control endpoint and one bulk IN/OUT pair
- accept one OUT packet at a time
- validate the NN batch command format
- copy the request into the DMA TX buffer in DDR
- arm S2MM first, then MM2S
- poll DMA completion
- return the response bytes to USB bulk IN

Important design choices:

- Only one USB OUT packet is held at a time. This simplifies ownership between
  the USB buffer manager, the DMA buffers, and the firmware main loop.
- DMA completion is polled instead of interrupt-driven. For these short,
  infrequent transfers, polling keeps the control flow smaller and easier to
  debug.
- Cache flush/invalidate is done explicitly around USB and DMA buffers because
  both peripherals access memory outside the CPU cache coherency domain.

### `build-vitis.py`

`Vitis/build-vitis.py` recreates the workspace from scratch each run. That is a
deliberate choice: it avoids stale platform state when the XSA changes and
makes the build script deterministic.

### `usb_dma_nn_test.py`

`scripts/usb_dma_nn_test.py` is the host-side functional checker.

Responsibilities:

- load the 2000-step reference trace
- chunk it into USB-sized requests
- stream requests to the board
- reassemble multi-packet USB IN replies
- write captured hardware output to CSV
- compare hardware output against the reference

The script also contains a targeted diagnostic for the historical "one-step
lag" failure mode. If that pattern appears, it usually indicates that the board
is still running an older bitstream or that hardware/software artifacts are out
of sync.

## Memory Ownership And DMA Buffers

The firmware uses three distinct memory regions:

- USB controller DMA memory: `UsbDeviceMemory`
- MM2S source buffer in DDR: `DmaTxBuffer`
- S2MM destination buffer in DDR: `DmaRxBuffer`

Ownership flow for a request:

1. USB endpoint manager owns the OUT buffer.
2. `UsbEp1OutEventHandler()` records the buffer pointer/length/handle.
3. `ProcessReceivedUsbPacket()` validates the packet and copies it into
   `DmaTxBuffer`.
4. The USB OUT buffer is released back to the USB stack.
5. DMA owns `DmaTxBuffer` and `DmaRxBuffer` for the exchange.
6. After completion, the firmware copies `DmaRxBuffer` into `UsbInBuffer`.
7. USB endpoint IN owns `UsbInBuffer` until the transmit-complete callback
   clears `TxBusy`.

This explicit ownership model is intentionally simple. The project is not
trying to maximize throughput with deep pipelining; it is trying to keep the
boundary between USB, software, DMA, and RTL understandable.

## Build Artifacts And Consistency

Primary generated artifacts:

- bitstream:
  `Vivado/zedboard_axi_dma/zedboard_axi_dma.runs/impl_1/zedboard_axi_dma_wrapper.bit`
- exported hardware platform:
  `Vivado/export/zedboard_axi_dma.xsa`
- Vitis workspace platform copy:
  `Vitis/workspace/zedboard_axi_dma_platform/hw/zedboard_axi_dma.xsa`
- PS application:
  `Vitis/workspace/zedboard_axi_dma_test_app/build/zedboard_axi_dma_test_app.elf`

When debugging hardware/software mismatches, treat these four files as a set.

Recommended sequence:

1. `cd Vivado && ./build.sh && ./build-bitstream.sh`
2. `cd ../Vitis && ./build-vitis.sh`
3. Program the FPGA with the current `.bit`
4. Run the current `.elf`
5. Run the host Python test

If Vitis is used to launch the ELF, remember that the launch configuration may
or may not also reprogram the FPGA depending on the `Program FPGA` setting.
That is why manual programming with the generated `.bit` can be useful when
debugging version skew.

## Verification Strategy

### RTL regression

`Vivado/sim-nn-bridge.sh` runs `scripts/hd_dma_stream_bridge_tb.sv`.

The current bridge testbench checks:

- packet parsing through the stream bridge
- response streaming with `TKEEP/TLAST`
- behavior both with and without input `TLAST`
- a stimulus window that crosses the first spike/calcium update boundary

### Host/board regression

`scripts/usb_dma_nn_test.py` is the end-to-end functional check for the real
board:

- USB bulk transport
- PS firmware
- AXI DMA path
- PL bridge
- NN output values

### Timing

The routed timing summary should be checked after bitstream generation:

- `Vivado/.../zedboard_axi_dma_wrapper_timing_summary_routed.rpt`

The current scripted hardware flow targets positive setup/hold slack at 50 MHz.

## Files Worth Reading First

If you need to re-learn the repo quickly, start here:

- `README.md`
- `docs/ARCHITECTURE.md`
- `Vivado/src/new/hd_dma_stream_bridge.v`
- `Vitis/common/src/usb_dma_bridge.c`
- `scripts/usb_dma_nn_test.py`
- `Vivado/src/bd/design_1.tcl`

## Known Limits

- Only one USB OUT request is processed at a time.
- The batch size is capped by a 512-byte USB OUT packet.
- DMA completions are polled, not interrupt-driven.
- Endpoint numbers, VID, and PID are currently fixed in the firmware and host
  script.
- The maintained regression path is the AXI-stream bridge testbench. Other
  historical test files in `scripts/` may reflect older experiments or wrapper
  variants.
