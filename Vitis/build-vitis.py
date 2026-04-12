#!/usr/bin/env python3
import shutil
from pathlib import Path

import vitis


SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
WORKSPACE_DIR = SCRIPT_DIR / "workspace"
SOURCE_FILE = SCRIPT_DIR / "common" / "src" / "xaxidma_example_sg_poll.c"

PLATFORM_NAME = "zedboard_axi_dma_platform"
DOMAIN_NAME = "standalone_ps7_cortexa9_0"
APP_NAME = "zedboard_axi_dma_test_app"


def find_xsa() -> Path:
    exported_xsa = REPO_ROOT / "Vivado" / "export" / "zedboard_axi_dma.xsa"
    if exported_xsa.exists():
        return exported_xsa

    xsa_files = sorted(
        (REPO_ROOT / "Vivado").glob("**/*.xsa"),
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )
    if xsa_files:
        return xsa_files[0]

    raise FileNotFoundError(
        "No XSA found. Run Vivado/build-bitstream.tcl first to generate and export hardware."
    )


def main() -> None:
    xsa_path = find_xsa()

    if WORKSPACE_DIR.exists():
        shutil.rmtree(WORKSPACE_DIR)

    client = vitis.create_client()
    try:
        client.set_workspace(str(WORKSPACE_DIR))

        platform = client.create_platform_component(
            name=PLATFORM_NAME,
            hw_design=str(xsa_path),
            generate_dtb=False,
        )
        platform.add_domain(name=DOMAIN_NAME, cpu="ps7_cortexa9_0", os="standalone")
        platform.build()

        platform_xpfm = client.find_platform_in_repos(PLATFORM_NAME)
        if not platform_xpfm:
            raise RuntimeError(f"Could not locate built platform '{PLATFORM_NAME}' in Vitis repos.")

        app = client.create_app_component(
            name=APP_NAME,
            platform=platform_xpfm,
            domain=DOMAIN_NAME,
            template="empty_application",
        )
        app.import_files(
            from_loc=str(SOURCE_FILE.parent),
            files=[SOURCE_FILE.name],
            dest_dir_in_cmp="src",
        )
        app.build()

        print(f"INFO: Built Vitis workspace at {WORKSPACE_DIR}")
        print(f"INFO: Platform component: {PLATFORM_NAME}")
        print(f"INFO: Application component: {APP_NAME}")
    finally:
        vitis.dispose()


if __name__ == "__main__":
    main()
