Vitis Project files
===================

### How to build the Vitis workspace

This 2025.2 port uses the Vitis Python CLI instead of the older `xsct` flow.

Before building the Vitis workspace, you must already have an exported XSA from
the Vivado project. The expected path is:

`../Vivado/export/zedboard_axi_dma.xsa`

If that file is not present, the script will search under `../Vivado` and use the
most recent `.xsa` it finds.

### Scripted build

Linux:
```
cd <path-to-repo>/Vitis
./build-vitis.sh
```

Windows:
```
build-vitis.bat
```

The build script does four things:

1. Creates a fresh Vitis workspace in `Vitis/workspace`.
2. Creates a standalone platform component from the exported XSA.
3. Adds a `ps7_cortexa9_0` standalone domain.
4. Creates an empty application, imports `common/src/xaxidma_example_sg_poll.c`, and builds it.

### Run the application

1. Build and export the Vivado hardware platform first.
2. Run the Vitis build script above.
3. Open Vitis with the workspace at `Vitis/workspace`.
4. Program the FPGA with the bitstream from the exported XSA.
5. Run the `zedboard_axi_dma_test_app` application.
