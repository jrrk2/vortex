ROOT_DIR := $(realpath ../../../..)
include $(ROOT_DIR)/config.mk

# Vortex on the VC707 through synthgui's open flow
# (Verilator -> nextpnr-himbaechel -> prjxray -> openFPGALoader).
#
#   make project    write vortex_vc707.json
#   make gui        open it in synthgui
#   make synth      batch: synthesize + place & route
#   make bit        batch: ... + bitstream
#   make program    load the bitstream over JTAG

SYNTHGUI_DIR ?= $(HOME)/synthgui
SYNTHGUI     ?= $(SYNTHGUI_DIR)/build/synthgui
WORK_DIR     ?= $(CURDIR)/work
KERNEL_TOOL_PREFIX ?= riscv64-elf-

SRC_DIR    := $(VORTEX_HOME)/hw/syn/xilinx/vc707
RTL_DIR    := $(VORTEX_HOME)/hw/rtl
SCRIPT_DIR := $(VORTEX_HOME)/hw/scripts

STARTUP_ADDR := 0x80000000

# The FPU is the bulk of a core's area and needs DSP-mapped IP the open flow
# does not have; this is an integer-only build.
CONFIGS += -DVX_CFG_EXT_F_DISABLE

DEFINES := SYNTHESIS NDEBUG VX_CFG_XLEN=$(XLEN) VX_CFG_XLEN_$(XLEN) $(patsubst -D%,%,$(filter -D%,$(CONFIGS)))

INCDIRS := $(ROOT_DIR)/sw $(ROOT_DIR)/hw $(SRC_DIR) $(RTL_DIR) $(RTL_DIR)/libs $(RTL_DIR)/interfaces \
           $(RTL_DIR)/core $(RTL_DIR)/mem $(RTL_DIR)/vm $(RTL_DIR)/cache $(RTL_DIR)/cp $(RTL_DIR)/fpu

# Packages first; everything else Verilator finds through the include dirs.
SOURCES := $(RTL_DIR)/VX_gpu_pkg.sv $(RTL_DIR)/fpu/VX_fpu_pkg.sv $(RTL_DIR)/vm/VX_tlb_pkg.sv $(RTL_DIR)/VX_trace_pkg.sv \
           $(SRC_DIR)/clkgen_vc707.sv $(SRC_DIR)/vortex_vc707.sv

LANES := mem/lane00.hex

all: project

kernel.elf: $(SRC_DIR)/blink.S
	$(KERNEL_TOOL_PREFIX)gcc -march=rv32i -mabi=ilp32 -nostdlib -nostartfiles -Wl,-Ttext=$(STARTUP_ADDR) -o $@ $<

kernel.bin: kernel.elf
	$(KERNEL_TOOL_PREFIX)objcopy -O binary $< $@

$(LANES): kernel.bin $(SRC_DIR)/gen_lanes.py
	python3 $(SRC_DIR)/gen_lanes.py --outdir mem --line-size 64 --depth 4096 $<

vortex_vc707.json: $(SRC_DIR)/gen_project.py $(LANES) Makefile
	python3 $(SRC_DIR)/gen_project.py --out $@ --work $(WORK_DIR) --srcdir $(CURDIR)/mem \
		--xdc $(SRC_DIR)/vortex_vc707_open.xdc \
		--sources $(SOURCES) --incdirs $(INCDIRS) --defines $(DEFINES)

project: vortex_vc707.json

gui: vortex_vc707.json
	$(SYNTHGUI) --project $(CURDIR)/vortex_vc707.json &

synth: vortex_vc707.json
	QT_QPA_PLATFORM=offscreen $(SYNTHGUI) --project $(CURDIR)/vortex_vc707.json --run synth,pnr

bit: vortex_vc707.json
	QT_QPA_PLATFORM=offscreen $(SYNTHGUI) --project $(CURDIR)/vortex_vc707.json --run synth,pnr,bit

program: vortex_vc707.json
	$(SYNTHGUI) --project $(CURDIR)/vortex_vc707.json --run program

clean:
	rm -rf kernel.elf kernel.bin mem vortex_vc707.json

clean-work:
	rm -rf $(WORK_DIR)

.PHONY: all project gui synth bit program clean clean-work
