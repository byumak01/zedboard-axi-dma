#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${XILINX_VITIS:-}" ]]; then
  echo "XILINX_VITIS is not set."
  echo "Set it to your Vitis 2025.2 install directory and rerun this script."
  exit 1
fi

export PYTHONPATH="${PYTHONPATH:-}"

# Some minimal Linux installs do not provide /usr/bin/hostname.
# The AMD environment script only needs a basic hostname value, so fall back
# to uname when the hostname command is missing.
if ! command -v hostname >/dev/null 2>&1; then
  hostname() {
    uname -n
  }
fi

source "$XILINX_VITIS/cli/examples/customer_python_utils/setup_vitis_env.sh"
vitis -s "$SCRIPT_DIR/build-vitis.py"
