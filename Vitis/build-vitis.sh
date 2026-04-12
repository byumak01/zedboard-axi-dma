#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${XILINX_VITIS:-}" ]]; then
  echo "XILINX_VITIS is not set."
  echo "Set it to your Vitis 2025.2 install directory and rerun this script."
  exit 1
fi

export PYTHONPATH="${PYTHONPATH:-}"
source "$XILINX_VITIS/cli/examples/customer_python_utils/setup_vitis_env.sh"
vitis -s "$SCRIPT_DIR/build-vitis.py"
