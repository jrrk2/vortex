#!/usr/bin/env python3
# Split a flat program image into one $readmemh file per byte lane of a
# LINE_SIZE-byte-wide memory: lane<i>.hex holds byte i of every line.
import argparse
import os

parser = argparse.ArgumentParser()
parser.add_argument("binfile")
parser.add_argument("--outdir", default=".")
parser.add_argument("--line-size", type=int, default=64)
parser.add_argument("--depth", type=int, default=4096)
args = parser.parse_args()

image = open(args.binfile, "rb").read()
capacity = args.line_size * args.depth
if len(image) > capacity:
    raise SystemExit(f"{args.binfile}: {len(image)} bytes does not fit in {capacity}")
image = image.ljust(capacity, b"\0")

os.makedirs(args.outdir, exist_ok=True)
for lane in range(args.line_size):
    with open(os.path.join(args.outdir, f"lane{lane:02d}.hex"), "w") as f:
        f.write("\n".join(f"{b:02x}" for b in image[lane::args.line_size]) + "\n")
