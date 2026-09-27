#!/usr/bin/env python3
"""Export the deployed contracts' compiler ABIs; requires the pinned Foundry toolchain."""

import json
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parents[1]
destination = root / "docs" / "abi"
destination.mkdir(parents=True, exist_ok=True)
for contract in ("LaunchToken", "BuybackBurnHook"):
    abi = json.loads(subprocess.check_output(
        ["forge", "inspect", f"src/{contract}.sol:{contract}", "abi", "--json"],
        cwd=root, text=True,
    ))
    (destination / f"{contract}.json").write_text(json.dumps(abi, indent=2) + "\n")
