#!/usr/bin/env python3
# Write the synthgui project for Vortex on the VC707 (open Verilator ->
# nextpnr-himbaechel -> prjxray flow). {root}, {prefix}, {builds}, {deps} and
# the per-step placeholders are synthgui's own, resolved when it loads the file.
import argparse
import json

parser = argparse.ArgumentParser()
parser.add_argument("--out", required=True)
parser.add_argument("--work", required=True)
parser.add_argument("--srcdir", required=True, help="directory of the lane*.hex images")
parser.add_argument("--xdc", required=True)
parser.add_argument("--sources", nargs="+", required=True)
parser.add_argument("--incdirs", nargs="+", required=True)
parser.add_argument("--defines", nargs="*", default=[])
args = parser.parse_args()

steps = [
    ("synth", "Synthesize",
     "MEM_INIT_DIR={srcdir} VERILATOR_ROOT={verilator_root} {verilator} -Wno-fatal --quiet {defines} {incdirs}"
     " --top-module {top} --struct-only-report {blackboxes} --map-only-output {json}"
     " --map-only-verilog {work}/{top}_mapped.v --map-only-edif {edif} --Mdir {work}/obj"
     " {xilinx_stubs} {sources}"),
    ("pnr", "Place & Route",
     "{nextpnr} --device {part} -o xdc={xdc} --json {json} -o fasm={fasm} -o placement={placement}"
     " --write {routed} --sdf {sdf} {nextpnr_flags}"),
    ("sta", "OpenSTA",
     "{sta_prep} --json {routed} --sdf {sdf} --log {work}/pnr.log --out {work}/sta"
     " && cd {work}/sta && {sta} -no_splash -exit sta.tcl"),
    ("bit", "Bitstream",
     "{fasm2frames} --part {part} --db-root {prjxray_db}/{family} {fasm} {work}/{top}.frames"
     " && {frames2bit} --part_file {prjxray_db}/{family}/{part}/part.yaml --part_name {part}"
     " --frm_file {work}/{top}.frames --output_file {bit}"),
    ("program", "Program",
     "{openfpgaloader} --cable digilent --freq 15000000 {bit}"),
]

project = {
    "name": "vortex vc707",
    "top": "vortex_vc707",
    "work": args.work,
    "device": "xc7vx485t",
    "part": "xc7vx485tffg1761-2",
    "family": "virtex7",
    "xdc": args.xdc,
    "srcdir": args.srcdir,
    "sources": args.sources,
    "incdirs": args.incdirs,
    "defines": args.defines,
    "blackboxes": ["BUFG", "IBUFDS", "MMCME2_ADV", "IBUF", "OBUF", "RAMB36E1"],
    "verilator": "{prefix}/bin/verilator_bin",
    "verilator_root": "{prefix}/share/verilator",
    "xilinx_stubs": "{root}/xc7/cells_sim.v {root}/xc7/cells_xtra.v",
    "nextpnr": "{builds}/nextpnr/nextpnr-himbaechel",
    "nextpnr_flags": "--router router2 --timing-allow-fail -o hold-fix --placer-heap-timingweight 60",
    "prjxray_db": "{deps}/prjxray-db",
    "sta": "{prefix}/bin/sta",
    "openfpgaloader": "{prefix}/bin/openFPGALoader",
    "steps": [{"id": i, "label": l, "command": c} for i, l, c in steps],
    "capacity": {
        "LUT": 303600, "FF": 607200, "RAMB36": 1030, "LUTRAM": 130800,
        "DSP": 2800, "IO": 700, "BUFG": 32,
    },
}

with open(args.out, "w") as f:
    json.dump(project, f, indent=2)
    f.write("\n")
