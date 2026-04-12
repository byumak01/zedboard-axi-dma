#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${XILINX_VITIS:-}" ]]; then
  echo "XILINX_VITIS is not set."
  echo "Set it to your Vitis 2025.2 install directory and rerun this script."
  exit 1
fi

source "$XILINX_VITIS/cli/examples/customer_python_utils/setup_vitis_env.sh"
vitis -s build-vitis.py
