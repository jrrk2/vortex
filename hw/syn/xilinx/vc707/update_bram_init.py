#!/usr/bin/env python3
# Replace the contents of block RAMs in a routed FASM with new $readmemh
# images, so a new kernel needs only fasm2frames and xc7frames2bit, not a
# new synthesis or place and route.
#
# The placement JSON nextpnr wrote (-o placement=) names the tile of every
# memory cell; the Verilator mapper's layout puts word k bit i of a lane at
# INIT bit k*width+i of its RAMB36E1, and nextpnr deals those bits out to
# the tile's two RAMB18 halves alternately.  Both rules are applied here,
# so the lines written are the ones nextpnr itself would have written.
import argparse
import json
import os
import re
import sys

parser = argparse.ArgumentParser()
parser.add_argument("--placement", required=True, help="nextpnr -o placement= JSON")
parser.add_argument("--fasm", required=True, help="routed FASM to patch")
parser.add_argument("--out", help="patched FASM (may equal --fasm)")
parser.add_argument("--hexdir", required=True, help="directory of lane<NN>.hex images")
parser.add_argument("--cell", default=r"g_lane_(\d+)__lane_mem_inst_t0",
                    help="regex for a lane's RAMB36E1 cell; group 1 is the lane number")
parser.add_argument("--width", type=int, default=8, help="word width of the memory (1, 8 or 32)")
parser.add_argument("--check", action="store_true",
                    help="only report whether the FASM already holds these images")
args = parser.parse_args()

if not args.out and not args.check:
    parser.error("--out is required unless --check")
if args.width not in (1, 8, 32):
    sys.exit("--width must be 1, 8 or 32 (the mapper's RAMB36E1 lane widths)")
WORDS_PER_TILE = 32768 // args.width


def read_hex(path):
    """$readmemh: hex words, @addr markers, // comments."""
    words = {}
    addr = 0
    with open(path) as f:
        for line in f:
            line = line.split("//")[0].strip()
            for tok in line.split():
                if tok.startswith("@"):
                    addr = int(tok[1:], 16)
                    continue
                words[addr] = int(tok, 16)
                addr += 1
    if not words:
        return []
    image = [0] * (max(words) + 1)
    for a, w in words.items():
        image[a] = w
    return image


def init_lines(tile, image):
    """The INIT_xx lines of both RAMB18 halves of `tile` for this image."""
    if len(image) > WORDS_PER_TILE:
        sys.exit(f"{tile}: {len(image)} words do not fit one x{args.width} RAMB36E1")
    # the RAMB36E1 parameter image: param line L bit b
    param = [[0] * 256 for _ in range(128)]
    for k, word in enumerate(image):
        for i in range(args.width):
            if (word >> i) & 1:
                pos = k * args.width + i
                param[pos // 256][pos % 256] = 1
    # The mapper emits a parameter line only when a bit of it is set, and
    # nextpnr writes a half's line whenever either parameter feeding it
    # exists, even if that half's share is all zero.
    present = [any(p) for p in param]
    # nextpnr's split: half h, line n takes bits b == h (mod 2) of params
    # 2n (into vector index b//2) and 2n+1 (into 128 + b//2)
    lines = []
    for half in (0, 1):
        for n in range(64):
            vec = [0] * 256
            for j in (0, 1):
                for b in range(half, 256, 2):
                    if param[2 * n + j][b]:
                        vec[j * 128 + b // 2] = 1
            if present[2 * n] or present[2 * n + 1]:
                bits = "".join("1" if v else "0" for v in reversed(vec))
                lines.append(f"{tile}.RAMB18_Y{half}.INIT_{n:02X}[255:0] = 256'b{bits}\n")
    return lines


cell_re = re.compile(args.cell)
with open(args.placement) as f:
    placement = json.load(f)
tiles = {}
for name, where in placement.items():
    m = cell_re.fullmatch(name)
    if not m:
        continue
    if where.get("bel") != "RAMB36E1":
        sys.exit(f"{name} is placed on {where.get('bel')}, not a RAMB36E1")
    tiles[int(m.group(1))] = where["tile"]
if not tiles:
    sys.exit(f"no cell in {args.placement} matches {args.cell!r}")

wanted = {}
for lane, tile in sorted(tiles.items()):
    path = os.path.join(args.hexdir, f"lane{lane:02d}.hex")
    if not os.path.exists(path):
        sys.exit(f"{path}: no image for lane {lane} (cell placed at {tile})")
    wanted[tile] = init_lines(tile, read_hex(path))

init_re = re.compile(r"^([A-Z_]+_X\d+Y\d+)\.RAMB18_Y[01]\.INITP?_[0-9A-F]{2}\[")
with open(args.fasm) as f:
    fasm = f.readlines()

# Drop the tiles' old INIT lines; each half's new ones go after its last kept
# line, where nextpnr writes them, so an unchanged image leaves the file as it was.
result = []
have = {t: [] for t in wanted}
insert_at = {}
for line in fasm:
    tile = line.split(".", 1)[0]
    if tile in wanted:
        if init_re.match(line):
            have[tile].append(line)
            continue
        insert_at[line[:len(tile) + 10]] = len(result) + 1  # "<tile>.RAMB18_Yh"
    result.append(line)

changed = [t for t in wanted if sorted(have[t]) != sorted(wanted[t])]
if args.check:
    print(f"{len(wanted)} lanes, {len(changed)} differ from the images in {args.hexdir}")
    sys.exit(1 if changed else 0)

by_half = {}
for tile, lines in wanted.items():
    for line in lines:
        by_half.setdefault(line[:len(tile) + 10], []).append(line)
for half in by_half:
    if half not in insert_at:
        sys.exit(f"{half}: no lines in {args.fasm}; is this the FASM of that placement?")
for half in sorted(by_half, key=lambda h: insert_at[h], reverse=True):
    result[insert_at[half]:insert_at[half]] = by_half[half]

with open(args.out, "w") as f:
    f.writelines(result)
print(f"{args.out}: {len(wanted)} lanes updated, {len(changed)} changed, "
      f"{sum(len(v) for v in wanted.values())} INIT lines written")
