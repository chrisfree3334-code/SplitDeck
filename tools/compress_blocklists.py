#!/usr/bin/env python3
"""Compresses the converted block lists for the app bundle.

Each sd-*.json becomes sd-*.zz (raw DEFLATE, which iOS reads with NSData.decompressed(using: .zlib))
and the .json is removed, so the app ships about a fifth of the size. Run after validation.
"""
import glob
import os
import sys
import zlib

out_dir = sys.argv[1] if len(sys.argv) > 1 else "Sources/Blocklists"
before = after = 0
for path in sorted(glob.glob(os.path.join(out_dir, "sd-*.json"))):
    data = open(path, "rb").read()
    c = zlib.compressobj(9, zlib.DEFLATED, -15)
    packed = c.compress(data) + c.flush()
    with open(path[:-5] + ".zz", "wb") as f:
        f.write(packed)
    os.remove(path)
    before += len(data)
    after += len(packed)
    print(f"{os.path.basename(path)}: {len(data) // 1024} KB -> {len(packed) // 1024} KB")
print(f"Total: {before // 1024} KB -> {after // 1024} KB")
if os.environ.get("GITHUB_ACTIONS"):
    print(f"::notice title=Block lists::{before // 1024} KB of rules ship as {after // 1024} KB")
