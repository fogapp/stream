#!/usr/bin/env python3
"""The UI tests' screenshots out of the result bundle, named as the tests
named them: `make ui` puts them in build/screenshots for looking at (never
compared against stored baselines — they drift between machines)."""
import json
import os
import shutil
import subprocess
import sys
import tempfile

bundle, out = sys.argv[1], sys.argv[2]
with tempfile.TemporaryDirectory() as raw:
    subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", bundle, "--output-path", raw], check=True,
                   stdout=subprocess.DEVNULL)
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(raw, "manifest.json")) as file:
        manifest = json.load(file)
    count = 0
    for test in manifest:
        for attachment in test.get("attachments", []):
            name = attachment.get("suggestedHumanReadableName", attachment["exportedFileName"])
            base = name.split("_0_")[0] if "_0_" in name else os.path.splitext(name)[0]
            extension = os.path.splitext(attachment["exportedFileName"])[1]
            shutil.copy(os.path.join(raw, attachment["exportedFileName"]), os.path.join(out, f"{base}{extension}"))
            count += 1
print(f"{count} screenshots in {out}")
