#!/usr/bin/env python3
"""Export the frontend ABI from the current Forge build."""
import argparse
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--check", action="store_true")
args = parser.parse_args()
artifact = json.loads((root / "out/RyodanKeys.sol/RyodanKeys.json").read_text())
contents = json.dumps(artifact["abi"], indent=2) + "\n"
destination = root / "abi/RyodanKeys.json"
if args.check:
    if not destination.exists() or destination.read_text() != contents:
        raise SystemExit("Frontend ABI is stale. Run forge build and python3 scripts/export-abi.py.")
else:
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(contents)
