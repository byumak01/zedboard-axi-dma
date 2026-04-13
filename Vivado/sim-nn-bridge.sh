#!/usr/bin/env bash
set -euo pipefail

vivado -mode batch -source sim-nn-bridge.tcl
