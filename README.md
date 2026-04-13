zedboard-axi-dma
================

Demonstration project for the AXI DMA Engine on the ZedBoard

## Quick start

Use JTAG for the first bring-up. You do not need an SD card or `BOOT.BIN`.

1. Build the hardware and software:
   ```
   cd Vivado
   ./build.sh
   ./build-bitstream.sh
   cd ../Vitis
   ./build-vitis.sh
   ```
2. Set the ZedBoard boot mode to `JTAG`.
3. Connect the board power and the JTAG/UART USB cable.
4. Open Vitis with workspace `Vitis/workspace`.
5. Run the generated hardware launch configuration `zedboard_axi_dma_test_app_app_hw_1`.
   This launch programs the bitstream, runs the FSBL, and downloads `zedboard_axi_dma_test_app.elf`.
6. Open the UART at `115200 8N1` and confirm you see:
   ```
   --- ZedBoard USB DMA bridge ---
   ```
7. Connect the ZedBoard OTG USB port to the host PC and run:
   ```
   python3 -m pip install pyusb
   python3 scripts/usb_dma_nn_test.py
   ```
8. Expected host behavior:
   ```
   batch 01/...
   ...
   All 2000 steps match exactly.
   ```

## Requirements

This port is designed for Vivado 2025.2 and Vitis 2025.2.

* Vivado 2025.2
* Vitis 2025.2
* [ZedBoard](http://zedboard.org "ZedBoard")

## Description

This project demonstrates the use of the AXI DMA Engine IP for transferring
data between a custom IP block and memory. A tutorial for recreating this project
from the Vivado GUI can be found here:

http://www.fpgadeveloper.com/2014/08/using-the-axi-dma-in-vivado.html

The current fork includes a standalone USB bulk neural-network bridge app for
the ZedBoard OTG port. The data path is:

`host PC USB bulk OUT -> Zynq PS USB controller -> DDR buffer -> AXI DMA -> PL NN batch bridge -> AXI DMA -> USB bulk IN`

The PL side now packetizes NN inputs into small USB/DMA-friendly batches,
executes `hd_neuron` step-by-step, and returns the packed weights/calcium/spike
results back to the host.

For a code-oriented walkthrough of the repo structure and design decisions, see
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Build instructions

This port does not require you to create Vivado or Vitis projects by hand.

### Linux

1. Create the Vivado project:
   ```
   cd Vivado
   ./build.sh
   ```
2. Build the bitstream and export the XSA:
   ```
   ./build-bitstream.sh
   ```
3. Build the Vitis workspace, platform, and application:
   ```
   cd ../Vitis
   ./build-vitis.sh
   ```
4. Open Vitis and select `Vitis/workspace` as the workspace.
5. Connect and power the ZedBoard.
6. Program the FPGA and run `zedboard_axi_dma_test_app`.
7. Connect the ZedBoard OTG USB port to the host and run the host NN test tool:
   ```
   python3 -m pip install pyusb
   python3 scripts/usb_dma_nn_test.py
   ```

### Windows

1. Run `Vivado\\build.bat` to create the Vivado project.
2. Run `vivado -mode batch -source build-bitstream.tcl` from the `Vivado` directory.
3. Run `Vitis\\build-vitis.bat` to create the Vitis workspace.

### Standalone bridge simulation

To run the AXI-stream NN bridge testbench without rebuilding the full hardware:

```
cd Vivado
./sim-nn-bridge.sh
```

This launches `scripts/hd_dma_stream_bridge_tb.sv`, which exercises the same
framed batch protocol used by the USB/DMA path.

The hardware project is created against the Zynq part directly. If you do not have the old
Avnet ZedBoard board file installed, the build still works because the script imports the
built-in `ZedBoard` PS preset instead of relying on `em.avnet.com:zed:part0:1.4`.

## USB bridge notes

The USB bridge firmware enumerates as a vendor-specific bulk device with:

* VID `0x0D7D`
* PID `0x0200`
* Interface `0`
* Bulk OUT endpoint `0x01`
* Bulk IN endpoint `0x81`

The current firmware accepts NN batch requests up to 512 bytes on USB OUT. Each
request has the format:

* `0xA5`
* flags byte (`bit0=reset model state before the batch`)
* 16-bit big-endian step count
* `step_count * 9` bytes of inputs (`pre_in1`, `pre_in2`, `post_in`, each 24-bit big-endian)

The response is `step_count * 13` bytes:

* `w1`, `w2`, `c1`, `c2` as 24-bit big-endian values
* one spike byte `{5'b0, post_spike, pre2_spike, pre1_spike}`

The provided host script chunks the 2000-step reference file automatically so it
fits inside the USB endpoint limits.

## References used for the USB port

The USB app in this fork follows AMD's 2025.2 `xusbps` device-mode example
structure for SDT lookup, endpoint configuration, and interrupt wiring, plus
the chapter-9 helper patterns from the storage example:

* `xusbps_intr_example.c`
* `xusbps_ch9_storage.c`
* `xusbps_ch9_storage.h`

Useful ZedBoard GitHub references while porting:

* `lvgl/lv_port_xilinx_zedboard_vitis` for Zynq USB usage on ZedBoard in Vitis
* `giuseppewebber/FPGA_video_processing` for the broader `USB on PS -> DMA -> PL`
  architecture, although that project is Linux/webcam-based rather than this
  standalone bulk bridge

## Troubleshooting

Check the following if the project fails to build or generate a bitstream:

### 1. Are you using the correct tool versions?
Check the version specified in the Requirements section of this readme file.

### 2. Did you run the scripted flow in order?
Create the Vivado project first, then build/export the XSA, then run the Vitis build script.

### 3. Did you copy/clone the repo into a short directory structure?
Vivado doesn't cope well with long directory structures, so copy/clone the repo into a short directory structure such as
`C:\projects\`. When working in long directory structures, you can get errors relating to missing files, particularly files 
that are normally generated by Vivado (FIFOs, etc).

## License

Feel free to modify the code for your specific application.

## Fork and share

If you port this project to another hardware platform, please send me the
code or push it onto GitHub and send me the link so I can post it on my
website. The more people that benefit, the better.

## About us

This project was developed by [Opsero Inc.](http://opsero.com "Opsero Inc."),
a tight-knit team of FPGA experts delivering FPGA products and design services to start-ups and tech companies. 
Follow our blog, [FPGA Developer](http://www.fpgadeveloper.com "FPGA Developer"), for news, tutorials and
updates on the awesome projects we work on.
