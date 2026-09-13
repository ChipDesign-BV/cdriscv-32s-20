# SPDX-FileCopyrightText: 2026 ChipDesign B.V.
# SPDX-License-Identifier: Apache-2.0
#
# cdriscv-32s-20 -- O8 on the FINAL hardened netlist (chip2b): gate-level
# simulation of the flat post-route chip with SDF, booting through the
# real QSPI loader.  Included from the main Makefile
# (`-include verif/gate/gate_chip.mk`); standalone use:
#
#   make -f Makefile -f verif/gate/gate_chip.mk gate-chip-sdf   # smoke
#   make -f Makefile -f verif/gate/gate_chip.mk gate-chip-arch  # subset
#   ... CHIP_CORNER=nom_slow_1p08V_125C                         # corner
#
# Nothing here runs place-and-route: the netlist and the three SDFs are
# the artefacts flow/runs/chip2b/final already holds.  Relies on the
# main Makefile for BUILD, IVERILOG, VVP, PYTHON, GATE_UDP, SRAM_PDK,
# sw and the boot_flash images, and on $(BUILD)/gate/sg13g2_cells_sdf.v
# (cell models with their specify blocks kept).

.PHONY: gate-chip-sdf gate-chip-arch gate-chip-vvp gate-chip-sdf-file

CHIP_RUN     ?= flow/runs/chip2b/final
CHIP_NL      := $(CHIP_RUN)/nl/cdriscv_32s_20_chip.nl.v
CHIP_SDF_DIR := $(CHIP_RUN)/sdf
CHIP_CORNER  ?= nom_typ_1p20V_25C
CHIP_BUILD   := $(BUILD)/gate/chip
CHIP_IO_V    ?= /foss/pdks/ihp-sg13g2/libs.ref/sg13g2_io/verilog/sg13g2_io.v
# `=`: SRAM_PDK is defined further down the main Makefile.
CHIP_SRAM_V   = $(SRAM_PDK)/verilog
# Parallel arch tests.  Each vvp of this netlist holds ~3.5 GB; size
# this to the machine's memory, not its cores.
CHIP_JOBS    ?= 2
# Cycle budgets: 1-bit boot moves 16 clk per flash byte, quad 4; the
# arch images are 20-24 KiB.
CHIP_SMOKE_CYCLES ?= 100000
CHIP_ARCH_CYCLES  ?= 300000

$(CHIP_BUILD):
	mkdir -p $(CHIP_BUILD)

# The SRAM macros compile -DFUNCTIONAL (behavioural array, no specify):
# their timing branch is built on $setuphold delayed-net outputs, which
# Icarus does not implement, so that branch would leave the array core
# undriven.  The macro IOPATH entries in the SDF therefore annotate to
# nothing and are counted as benign in the report.  The blackbox shells
# in verif/gate/cdriscv_32s_20_tcm_macro.sv are deliberately NOT read.
$(CHIP_BUILD)/tb_sdf_chip.vvp: $(CHIP_NL) $(BUILD)/gate/sg13g2_cells_sdf.v $(GATE_UDP) \
                               verif/gate/tb_sdf_chip.sv verif/models/spi_norflash_model.sv \
                               | $(CHIP_BUILD)
	$(IVERILOG) -g2012 -gspecify -ginterconnect -DFUNCTIONAL -o $@ -s tb_sdf_chip \
	  $(CHIP_NL) \
	  $(BUILD)/gate/sg13g2_cells_sdf.v $(GATE_UDP) \
	  $(CHIP_IO_V) \
	  $(CHIP_SRAM_V)/RM_IHPSG13_1P_2048x32_c2_bm_bist.v \
	  $(CHIP_SRAM_V)/RM_IHPSG13_1P_4096x8_c3_bm_bist.v \
	  $(CHIP_SRAM_V)/RM_IHPSG13_1P_core_behavioral_bm_bist.v \
	  verif/models/spi_norflash_model.sv verif/gate/tb_sdf_chip.sv \
	  2>&1 | tee $(CHIP_BUILD)/compile.log

gate-chip-vvp: $(CHIP_BUILD)/tb_sdf_chip.vvp

# One filtered SDF per corner (scripts/sdf_chip_filter.py: drops only
# the port-to-pad INTERCONNECT entries Icarus cannot place).  Explicit
# rules per corner: a `%` pattern cannot name the corner twice in the
# prerequisite path.
CHIP_CORNERS := nom_typ_1p20V_25C nom_slow_1p08V_125C nom_fast_1p32V_m40C
define chip_sdf_rule
$(CHIP_BUILD)/chip_$(1).sdf: $(CHIP_SDF_DIR)/$(1)/cdriscv_32s_20_chip__$(1).sdf scripts/sdf_chip_filter.py | $(CHIP_BUILD)
	$$(PYTHON) scripts/sdf_chip_filter.py $$< $$@ | tee $$@.log
endef
$(foreach c,$(CHIP_CORNERS),$(eval $(call chip_sdf_rule,$(c))))

gate-chip-sdf-file: $(CHIP_BUILD)/chip_$(CHIP_CORNER).sdf

# Smoke: the same two images `make bootsim` boots at RTL (1-bit and
# quad payload), each through the pads with timing.  Verdict grep as
# everywhere else: vvp does not fail make on its own.
# The two runs are independent and each takes hours at ~20 cycles/s,
# so they run concurrently; the verdict greps follow both.
gate-chip-sdf: $(CHIP_BUILD)/tb_sdf_chip.vvp $(CHIP_BUILD)/chip_$(CHIP_CORNER).sdf \
               $(BUILD)/boot_flash.hex $(BUILD)/boot_flash_quad.hex
	/usr/bin/time -f "[TB-CHIP] wall %e s, maxrss %M KiB" \
	  $(VVP) $(CHIP_BUILD)/tb_sdf_chip.vvp \
	  +FLASH_HEX=$(BUILD)/boot_flash.hex \
	  +SDF=$(CHIP_BUILD)/chip_$(CHIP_CORNER).sdf +MAX_CYCLES=$(CHIP_SMOKE_CYCLES) \
	  > $(CHIP_BUILD)/sdf_smoke_$(CHIP_CORNER).log 2>&1 & \
	/usr/bin/time -f "[TB-CHIP] wall %e s, maxrss %M KiB" \
	  $(VVP) $(CHIP_BUILD)/tb_sdf_chip.vvp \
	  +FLASH_HEX=$(BUILD)/boot_flash_quad.hex \
	  +SDF=$(CHIP_BUILD)/chip_$(CHIP_CORNER).sdf +MAX_CYCLES=$(CHIP_SMOKE_CYCLES) \
	  > $(CHIP_BUILD)/sdf_smoke_quad_$(CHIP_CORNER).log 2>&1 & \
	wait
	@grep -h "annotated\|boot_done at\|loaded image\|PASS\|FAIL\|TIMEOUT\|wall" \
	  $(CHIP_BUILD)/sdf_smoke_$(CHIP_CORNER).log $(CHIP_BUILD)/sdf_smoke_quad_$(CHIP_CORNER).log
	@grep -q "\[TB-CHIP\] PASS" $(CHIP_BUILD)/sdf_smoke_$(CHIP_CORNER).log
	@grep -q "\[TB-CHIP\] PASS" $(CHIP_BUILD)/sdf_smoke_quad_$(CHIP_CORNER).log

# The O8 architectural subset (GATE_ARCH_TESTS from the main Makefile),
# each test packed into a quad-payload flash image and booted through
# the loader before its signature is compared with the Spike reference.
gate-chip-arch: $(CHIP_BUILD)/tb_sdf_chip.vvp $(CHIP_BUILD)/chip_$(CHIP_CORNER).sdf
	CHIP_CORNER=$(CHIP_CORNER) CHIP_JOBS=$(CHIP_JOBS) CHIP_ARCH_CYCLES=$(CHIP_ARCH_CYCLES) \
	  scripts/gate_chip_arch.sh $(GATE_ARCH_TESTS) \
	  2>&1 | tee $(CHIP_BUILD)/gate_chip_arch_$(CHIP_CORNER).log
