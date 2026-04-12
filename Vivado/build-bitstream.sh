#!/usr/bin/env bash
set -euo pipefail

vivado -mode batch -source build-bitstream.tcl
