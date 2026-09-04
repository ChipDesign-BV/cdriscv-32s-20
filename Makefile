# SPDX-FileCopyrightText: 2026 ChipDesign B.V.
# SPDX-License-Identifier: Apache-2.0
#
# cdriscv-32s-10 -- build entry points.
#
# See doc/verification_plan.md for what these are meant to establish and
# doc/verification_findings.md for what they have actually found.
#
# .SHELLFLAGS carries pipefail, and it is not optional.  Almost every
# simulation recipe here ends in `| tee somelog`, and a pipeline's exit
# status is the *last* command's -- so `vvp ... | tee` returns 0 even
# when the simulation calls $fatal.  Eleven recipes were built that way,
# which means a failing test reported a passing make, and the CI
# workflow would have gone green on it.  Verified directly: vvp alone
# exits 1 on $fatal, `vvp | tee` exits 0.

SHELL       := /bin/bash
.SHELLFLAGS := -o pipefail -c
BUILD      := build
FILELIST   := rtl/cdriscv_32s_20_files.f
RTL        := $(shell grep -v '^//' $(FILELIST))
TOP        := cdriscv_32s_20_subsys
TB         := tb/tb_cdriscv_subsys.sv
TB_TOP     := tb_cdriscv_subsys

VERILATOR  ?= verilator
IVERILOG   ?= iverilog
VVP        ?= vvp
YOSYS      ?= yosys
PYTHON     ?= python3

CROSS      ?= riscv64-unknown-elf-
CC         := $(CROSS)gcc
OBJCOPY    := $(CROSS)objcopy
OBJDUMP    := $(CROSS)objdump
ARCH       := rv32imc_zba_zbb_zbs_zicsr_zifencei_zcb_zcmp
ABI        := ilp32

.PHONY: pmp zcmp all lint lint-tb sim sw synth ecc clean block block-20 block-alu block-alu-bitmanip block-mult block-pmp block-e2e block-e2e-link block-clint block-jtag block-dbg block-decompress block-zcmp block-if-align block-decoder-equiv block-csr-equiv block-ecc block-multdiv block-tcm block-if-equiv safety safety-sw safety-bench periph reaction trap ams regwalk formal formal-if formal-ecc formal-bus formal-dec formal-lsu formal-safety coverage fi fi-arith fi-trap fi-mem fi-e2e fi-clint fi-pmp fi-zcmp fi-dbg fi-check cosim cosim-iverilog cosim-stall cosim-random

all: lint

# ---------------------------------------------------------------- lint
WAIVERS := verif/lint/waivers.vlt

# No -Wno-fatal: a new warning that is not waived in $(WAIVERS) fails
# the build.  Every waiver in that file carries its justification.
lint:
	$(VERILATOR) --lint-only -sv --timing -Wall \
	  --top-module $(TOP) $(WAIVERS) $(RTL)

# The RTL carries no `timescale (the tool default applies); the bench
# does, so the bench lint sets one globally to keep them consistent.
lint-tb:
	$(VERILATOR) --lint-only -sv --timing -Wall --timescale 1ns/1ps \
	  --top-module $(TB_TOP) $(WAIVERS) $(RTL) $(TB)

# ----------------------------------------------------------------- sim
$(BUILD)/$(TB_TOP).vvp: $(RTL) $(TB) | $(BUILD)
	$(IVERILOG) -g2012 -o $@ -s $(TB_TOP) $(RTL) $(TB)

sim: $(BUILD)/$(TB_TOP).vvp sw
	$(VVP) $< +ITCM_HEX=$(BUILD)/prog.itcm.hex \
	          +DTCM_HEX=$(BUILD)/prog.dtcm.hex \
	          +TRACE=1

# ------------------------------------------------------------ software
sw: $(BUILD)/prog.itcm.hex $(BUILD)/prog.dtcm.hex

$(BUILD)/prog.elf: tb/sw/start.S tb/sw/link.ld | $(BUILD)
	$(CC) -march=$(ARCH) -mabi=$(ABI) -nostdlib -nostartfiles \
	  -T tb/sw/link.ld -o $@ tb/sw/start.S
	$(OBJDUMP) -d $@ > $(BUILD)/prog.dis

$(BUILD)/prog.itcm.bin: $(BUILD)/prog.elf
	$(OBJCOPY) -O binary --only-section=.text $< $@

$(BUILD)/prog.dtcm.bin: $(BUILD)/prog.elf
	$(OBJCOPY) -O binary --only-section=.data $< $@

# Images are padded to the full memory depth.  The prefetcher runs past
# the end of the program, and an unwritten TCM word is X in simulation
# and a random code word in silicon -- either way the ECC check on it is
# meaningless.  See finding V4-F2.
TCM_WORDS ?= 4096

$(BUILD)/%.hex: $(BUILD)/%.bin
	$(PYTHON) scripts/mkimage.py $< $@ --words $(TCM_WORDS)

# -------------------------------------------------------- block benches
# Each block bench prints "PASS" or "FAIL"; the recipe greps for the
# verdict so that a failing bench fails make, which vvp itself does not.
ALU_VECTORS := $(BUILD)/alu_vectors.hex
ALU_RANDOM  ?= 20000

$(ALU_VECTORS): verif/block/alu/gen_vectors.py | $(BUILD)
	$(PYTHON) $< $@ $(ALU_RANDOM)

$(BUILD)/tb_alu.vvp: rtl/core/cdriscv_32s_20_pkg.sv rtl/core/cdriscv_32s_20_alu.sv \
                     verif/block/alu/tb_alu.sv | $(BUILD)
	$(IVERILOG) -g2012 -o $@ -s tb_alu $^

block-alu: $(BUILD)/tb_alu.vvp $(ALU_VECTORS)
	$(VVP) $(BUILD)/tb_alu.vvp +VEC=$(ALU_VECTORS) \
	  +NVEC=$$(wc -l < $(ALU_VECTORS)) | tee $(BUILD)/block_alu.log
	@grep -q "PASS" $(BUILD)/block_alu.log

# The clock monitor's "system clock stopped" branch cannot be reached
# from software on the subsystem -- the software would have to stop the
# clock it runs on -- so it gets a bench that owns the clock generator.
$(BUILD)/tb_clkmon.vvp: rtl/common/cdriscv_32s_20_sync.sv rtl/common/cdriscv_32s_20_cfg_parity.sv \
                        rtl/safety/cdriscv_32s_20_clkmon.sv \
                        verif/block/clkmon/tb_clkmon.sv | $(BUILD)
	$(IVERILOG) -g2012 -o $@ -s tb_clkmon $^

block-clkmon: $(BUILD)/tb_clkmon.vvp
	$(VVP) $(BUILD)/tb_clkmon.vvp | tee $(BUILD)/block_clkmon.log
	@grep -q "PASS" $(BUILD)/block_clkmon.log

ECC_PATTERNS ?= 200

$(BUILD)/tb_ecc.vvp: rtl/core/cdriscv_32s_20_pkg.sv rtl/safety/cdriscv_32s_20_ecc_secded.sv \
                     verif/block/ecc/tb_ecc.sv | $(BUILD)
	$(IVERILOG) -g2012 -o $@ -s tb_ecc $^

block-ecc: $(BUILD)/tb_ecc.vvp
	$(VVP) $(BUILD)/tb_ecc.vvp +PATTERNS=$(ECC_PATTERNS) | tee $(BUILD)/block_ecc.log
	@grep -q "PASS" $(BUILD)/block_ecc.log


MD_VECTORS := $(BUILD)/multdiv_vectors.hex
MD_RANDOM  ?= 300

$(MD_VECTORS): verif/block/multdiv/gen_vectors.py | $(BUILD)
	$(PYTHON) $< $@ $(MD_RANDOM)

$(BUILD)/tb_multdiv.vvp: rtl/core/cdriscv_32s_20_pkg.sv rtl/core/cdriscv_32s_20_multdiv.sv \
                         verif/block/multdiv/tb_multdiv.sv | $(BUILD)
	$(IVERILOG) -g2012 -o $@ -s tb_multdiv $^

block-multdiv: $(BUILD)/tb_multdiv.vvp $(MD_VECTORS)
	$(VVP) $(BUILD)/tb_multdiv.vvp +VEC=$(MD_VECTORS) \
	  +NVEC=$$(wc -l < $(MD_VECTORS)) | tee $(BUILD)/block_multdiv.log
	@grep -q "PASS" $(BUILD)/block_multdiv.log


# =====================================================================
# Blocks new in cdriscv-32s-20
# =====================================================================
PKG := rtl/core/cdriscv_32s_20_pkg.sv

$(BUILD)/tb_alu_bitmanip.vvp: $(PKG) rtl/core/cdriscv_32s_20_alu.sv verif/block/alu/tb_alu_bitmanip.sv | $(BUILD)
	$(IVERILOG) -g2012 -o $@ -s tb_alu_bitmanip $^

block-alu-bitmanip: $(BUILD)/tb_alu_bitmanip.vvp
	$(VVP) $< | tee $(BUILD)/block_alu_bitmanip.log
	@grep -q "PASS" $(BUILD)/block_alu_bitmanip.log

$(BUILD)/tb_mult.vvp: $(PKG) rtl/core/cdriscv_32s_20_mult.sv verif/block/mult/tb_mult.sv | $(BUILD)
	$(IVERILOG) -g2012 -o $@ -s tb_mult $^

block-mult: $(BUILD)/tb_mult.vvp
	$(VVP) $< | tee $(BUILD)/block_mult.log
	@grep -q "PASS" $(BUILD)/block_mult.log

$(BUILD)/tb_pmp.vvp: $(PKG) rtl/core/cdriscv_32s_20_pmp.sv verif/block/pmp/tb_pmp.sv | $(BUILD)
	$(IVERILOG) -g2012 -o $@ -s tb_pmp $^

block-pmp: $(BUILD)/tb_pmp.vvp
	$(VVP) $< | tee $(BUILD)/block_pmp.log
	@grep -q "PASS" $(BUILD)/block_pmp.log

$(BUILD)/tb_e2e.vvp: $(PKG) rtl/safety/cdriscv_32s_20_ecc_secded.sv rtl/safety/cdriscv_32s_20_e2e.sv verif/block/e2e/tb_e2e.sv | $(BUILD)
	$(IVERILOG) -g2012 -o $@ -s tb_e2e $^

block-e2e: $(BUILD)/tb_e2e.vvp
	$(VVP) $< | tee $(BUILD)/block_e2e.log
	@grep -q "PASS" $(BUILD)/block_e2e.log

# The link bench: the same generator/checker pair built into the two
# endpoints the subsystem instantiates, attacked over corruptible wires.
# Mutation-validated by scripts/mutate_e2e_link.py.
$(BUILD)/tb_e2e_link.vvp: $(PKG) rtl/safety/cdriscv_32s_20_ecc_secded.sv rtl/safety/cdriscv_32s_20_e2e.sv rtl/safety/cdriscv_32s_20_e2e_link.sv verif/block/e2e_link/tb_e2e_link.sv | $(BUILD)
	$(IVERILOG) -g2012 -o $@ -s tb_e2e_link $^

block-e2e-link: $(BUILD)/tb_e2e_link.vvp
	$(VVP) $< | tee $(BUILD)/block_e2e_link.log
	@grep -q "PASS" $(BUILD)/block_e2e_link.log

$(BUILD)/tb_clint.vvp: $(PKG) rtl/common/cdriscv_32s_20_cfg_parity.sv rtl/periph/cdriscv_32s_20_clint.sv verif/block/clint/tb_clint.sv | $(BUILD)
	$(IVERILOG) -g2012 -o $@ -s tb_clint $^

block-clint: $(BUILD)/tb_clint.vvp
	$(VVP) $< | tee $(BUILD)/block_clint.log
	@grep -q "PASS" $(BUILD)/block_clint.log

$(BUILD)/tb_jtag.vvp: rtl/debug/cdriscv_32s_20_jtag_tap.sv verif/block/jtag/tb_jtag.sv | $(BUILD)
	$(IVERILOG) -g2012 -o $@ -s tb_jtag $^

$(BUILD)/tb_dbg.vvp: rtl/common/cdriscv_32s_20_sync.sv \
                    rtl/debug/cdriscv_32s_20_dbg_bridge.sv \
                    rtl/debug/cdriscv_32s_20_dbg_win.sv \
                    verif/block/dbg/tb_dbg.sv | $(BUILD)
	$(IVERILOG) -g2012 -o $@ -s tb_dbg $^

block-dbg: $(BUILD)/tb_dbg.vvp
	$(VVP) $< | tee $(BUILD)/block_dbg.log
	@grep -q "PASS" $(BUILD)/block_dbg.log

block-jtag: $(BUILD)/tb_jtag.vvp
	$(VVP) $< | tee $(BUILD)/block_jtag.log
	@grep -q "PASS" $(BUILD)/block_jtag.log

# The decompressor bench dumps all 65 536 halfwords; check_decompress.py
# cross-checks every one against binutils built for this variant's ISA.
$(BUILD)/tb_decompress.vvp: rtl/core/cdriscv_32s_20_decompress.sv verif/block/decompress/tb_decompress.sv | $(BUILD)
	$(IVERILOG) -g2012 -o $@ -s tb_decompress $^

block-decompress: $(BUILD)/tb_decompress.vvp
	$(VVP) $< | tee $(BUILD)/block_decompress.log
	@test -s $(BUILD)/decompress_dump.txt || { echo "no dump produced"; exit 1; }
	python3 scripts/check_decompress.py | tee $(BUILD)/block_decompress_check.log
	@grep -q "^  PASS" $(BUILD)/block_decompress_check.log

# The Zcmp bench dumps the full micro-op sequence of every flagged
# encoding; check_zcmp.py replays each dump against a Spike commit log
# generated from binutils-assembled cm.* mnemonics.
$(BUILD)/tb_zcmp.vvp: rtl/core/cdriscv_32s_20_decompress.sv rtl/core/cdriscv_32s_20_zcmp.sv verif/block/zcmp/tb_zcmp.sv | $(BUILD)
	$(IVERILOG) -g2012 -o $@ -s tb_zcmp $^

block-zcmp: $(BUILD)/tb_zcmp.vvp
	$(VVP) $< | tee $(BUILD)/block_zcmp.log
	@test -s $(BUILD)/zcmp_dump.txt || { echo "no dump produced"; exit 1; }
	SPIKE=$(SPIKE) python3 scripts/check_zcmp.py | tee $(BUILD)/block_zcmp_check.log
	@grep -q "^  PASS" $(BUILD)/block_zcmp_check.log

$(BUILD)/tb_if_align.vvp: rtl/core/cdriscv_32s_20_if_align.sv rtl/core/cdriscv_32s_20_decompress.sv verif/block/if_align/tb_if_align.sv | $(BUILD)
	$(IVERILOG) -g2012 -o $@ -s tb_if_align $^

block-if-align: $(BUILD)/tb_if_align.vvp
	$(VVP) $< | tee $(BUILD)/block_if_align.log
	@grep -q "PASS" $(BUILD)/block_if_align.log

# ---------------------------------------------------------------------
# Equivalence against the frozen variant-1 reference in verif/ref/.
# Those files are never synthesised and never edited -- see
# verif/ref/README.md.
# ---------------------------------------------------------------------
REF := verif/ref/cdriscv_pkg.sv

$(BUILD)/tb_decoder_equiv.vvp: $(REF) $(PKG) verif/ref/cdriscv_decoder.sv rtl/core/cdriscv_32s_20_decoder.sv verif/block/decoder/tb_decoder_equiv.sv | $(BUILD)
	$(IVERILOG) -g2012 -o $@ -s tb_decoder_equiv $^

block-decoder-equiv: $(BUILD)/tb_decoder_equiv.vvp
	$(VVP) $< +niter=1000000 | tee $(BUILD)/block_decoder_equiv.log
	@grep -q "PASS" $(BUILD)/block_decoder_equiv.log

$(BUILD)/tb_csr_equiv.vvp: $(REF) $(PKG) verif/ref/cdriscv_counter64.sv verif/ref/cdriscv_cfg_parity.sv verif/ref/cdriscv_csr.sv rtl/common/cdriscv_32s_20_counter64.sv rtl/common/cdriscv_32s_20_cfg_parity.sv rtl/core/cdriscv_32s_20_csr.sv verif/block/csr/tb_csr_equiv.sv | $(BUILD)
	$(IVERILOG) -g2012 -o $@ -s tb_csr_equiv $^

block-csr-equiv: $(BUILD)/tb_csr_equiv.vvp
	$(VVP) $< | tee $(BUILD)/block_csr_equiv.log
	@grep -q "PASS" $(BUILD)/block_csr_equiv.log

block-20: block-alu-bitmanip block-mult block-pmp block-e2e block-e2e-link block-clint block-jtag block-dbg \
          block-decompress block-zcmp block-if-align block-decoder-equiv block-csr-equiv

block: block-alu block-ecc block-multdiv block-clkmon block-20

# ------------------------------------------------- core co-simulation
# Runs one program on Spike and on the RTL and compares the retired
# instruction streams.  SPIKE can be overridden; the default is where
# scripts/build_spike.sh installs it.
SPIKE      ?= /headless/verif-tools/spike/bin/spike
COSIM_ARCH := rv32imc_zba_zbb_zbs_zicsr_zifencei_zcb_zcmp
COSIM_SRC  := verif/core/cosim_isa.S
COSIM_LD   := verif/core/link_cosim.ld

$(BUILD)/cosim_isa.elf: $(COSIM_SRC) $(COSIM_LD) | $(BUILD)
	$(CC) -march=$(COSIM_ARCH) -mabi=$(ABI) -nostdlib -nostartfiles \
	  -T $(COSIM_LD) -o $@ $(COSIM_SRC)
	$(OBJDUMP) -d $@ > $(BUILD)/cosim_isa.dis

$(BUILD)/cosim_isa.hex: $(BUILD)/cosim_isa.elf
	$(OBJCOPY) -O binary $< $(BUILD)/cosim_isa.bin
	$(PYTHON) scripts/mkimage.py $(BUILD)/cosim_isa.bin $@

$(BUILD)/tb_cosim.vvp: $(RTL) verif/core/tb_cosim.sv | $(BUILD)
	$(IVERILOG) -g2012 -o $@ -s tb_cosim $(RTL) verif/core/tb_cosim.sv

# Verilator build of the same bench.  About 90 times faster than Icarus
# on this design (0.19 s against 17.8 s for a 200k cycle run), which is
# what makes a co-simulation of any real length affordable.  The lint
# waivers do not apply here because this is a build, not a lint run.
COSIM_RUNNER ?= $(BUILD)/obj_cosim/tb_cosim_vl

$(COSIM_RUNNER): $(RTL) verif/core/tb_cosim.sv | $(BUILD)
	$(VERILATOR) --binary --timing -sv --timescale 1ns/1ps \
	  -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
	  -Wno-SYNCASYNCNET \
	  --top-module tb_cosim -o $(notdir $(COSIM_RUNNER)) \
	  -Mdir $(BUILD)/obj_cosim $(RTL) verif/core/tb_cosim.sv

RANDOM_SEEDS ?= 50
RANDOM_LEN   ?= 400
# Each program's body is wrapped in a bounded outer loop, so a small
# image executes many instructions.  The body is not repeated work: the
# registers carry over, so every iteration starts from a different
# state, and the loop exercises the fetch redirect path hard.
RANDOM_LOOPS ?= 20
# Grants held off on this share of cycles; 0 keeps the memories always
# ready, which is the case every other test already covers.
RANDOM_STALL ?= 0

# Random program regression against Spike.  Failing seeds are kept in
# build/random and the runner prints the command to reproduce one.
# The same comparison with memory grants held off on a third of cycles.
# Back-pressure must change the timing and nothing else, and comparing
# against Spike is what checks that.  It is also the only thing that
# exercises the wait-for-grant paths in the LSU and the fetch stage,
# because the TCM always grants immediately.
COSIM_STALL ?= 35

cosim-stall: $(COSIM_RUNNER) $(BUILD)/cosim_isa.hex
	SPIKE=$(SPIKE) VVP=$(VVP) $(PYTHON) verif/core/cosim.py \
	  $(BUILD)/cosim_isa.elf --hex $(BUILD)/cosim_isa.hex \
	  --vvp $(COSIM_RUNNER) --count 5000 --stall $(COSIM_STALL)

cosim-random: $(COSIM_RUNNER)
	SPIKE=$(SPIKE) VVP=$(VVP) $(PYTHON) verif/core/random_regress.py \
	  --seeds $(RANDOM_SEEDS) --count $(RANDOM_LEN) \
	  --loops $(RANDOM_LOOPS) --stall $(RANDOM_STALL) --vvp $(COSIM_RUNNER)

cosim: $(COSIM_RUNNER) $(BUILD)/cosim_isa.hex
	SPIKE=$(SPIKE) VVP=$(VVP) $(PYTHON) verif/core/cosim.py \
	  $(BUILD)/cosim_isa.elf --hex $(BUILD)/cosim_isa.hex \
	  --vvp $(COSIM_RUNNER) --count 5000

# The same comparison under Icarus, as an independent second opinion on
# the simulator itself.  Slow: use it on the directed program, not on a
# regression.
cosim-iverilog: $(BUILD)/tb_cosim.vvp $(BUILD)/cosim_isa.hex
	SPIKE=$(SPIKE) VVP=$(VVP) $(PYTHON) verif/core/cosim.py \
	  $(BUILD)/cosim_isa.elf --hex $(BUILD)/cosim_isa.hex \
	  --vvp $(BUILD)/tb_cosim.vvp --count 5000

# --------------------------------------------------- register walk
$(BUILD)/regwalk_test.elf: verif/core/regwalk_test.S tb/sw/link.ld | $(BUILD)
	$(CC) -march=$(ARCH) -mabi=$(ABI) -nostdlib -nostartfiles \
	  -T tb/sw/link.ld -o $@ verif/core/regwalk_test.S

$(BUILD)/regwalk_test.bin: $(BUILD)/regwalk_test.elf
	$(OBJCOPY) -O binary --only-section=.text $< $@

# The registers and modes the functional tests never reach: timer
# prescaler and roll-over, interrupt controller edge mode and claim,
# watchdog window mode and a wrong key, the safety controller's pin
# registers, and the CSRs no program happens to read.
regwalk: $(BUILD)/tb_cdriscv_subsys.vvp $(BUILD)/regwalk_test.hex \
         $(BUILD)/dtcm_zero.hex
	$(VVP) $(BUILD)/tb_cdriscv_subsys.vvp \
	  +ITCM_HEX=$(BUILD)/regwalk_test.hex \
	  +DTCM_HEX=$(BUILD)/dtcm_zero.hex \
	  +MAX_CYCLES=200000 | tee $(BUILD)/regwalk.log
	@grep -q "PASS" $(BUILD)/regwalk.log

# -------------------------------------------------------- AMS tests
$(BUILD)/ams_test.elf: verif/core/ams_test.S tb/sw/link.ld | $(BUILD)
	$(CC) -march=$(ARCH) -mabi=$(ABI) -nostdlib -nostartfiles \
	  -T tb/sw/link.ld -o $@ verif/core/ams_test.S

$(BUILD)/ams_test.bin: $(BUILD)/ams_test.elf
	$(OBJCOPY) -O binary --only-section=.text $< $@

# Limit registers, range checking, the conversion time-out, the trim
# output and the analog test bus.  The time-out is provoked by setting
# the limit below the bench ADC model's latency, so no bench change is
# needed for it.
ams: $(BUILD)/tb_cdriscv_subsys.vvp $(BUILD)/ams_test.hex \
     $(BUILD)/dtcm_zero.hex
	$(VVP) $(BUILD)/tb_cdriscv_subsys.vvp \
	  +ITCM_HEX=$(BUILD)/ams_test.hex \
	  +DTCM_HEX=$(BUILD)/dtcm_zero.hex \
	  +MAX_CYCLES=300000 | tee $(BUILD)/ams.log
	@grep -q "PASS" $(BUILD)/ams.log

# ------------------------------------------------------- trap tests
$(BUILD)/rdback_test.elf: verif/core/rdback_test.S tb/sw/link.ld | $(BUILD)
	$(CC) -march=$(ARCH) -mabi=$(ABI) -nostdlib -nostartfiles \
	  -T tb/sw/link.ld -o $@ verif/core/rdback_test.S

$(BUILD)/rdback_test.bin: $(BUILD)/rdback_test.elf
	$(OBJCOPY) -O binary --only-section=.text $< $@

# Every peripheral read arm, and an unmapped offset in every slot.  A
# read arm that decodes to the wrong register is invisible to a test
# that only ever writes.
rdback: $(BUILD)/tb_cdriscv_subsys.vvp $(BUILD)/rdback_test.hex \
        $(BUILD)/dtcm_zero.hex
	$(VVP) $(BUILD)/tb_cdriscv_subsys.vvp \
	  +ITCM_HEX=$(BUILD)/rdback_test.hex \
	  +DTCM_HEX=$(BUILD)/dtcm_zero.hex \
	  +MAX_CYCLES=300000 | tee $(BUILD)/rdback.log
	@grep -q "PASS" $(BUILD)/rdback.log

$(BUILD)/fence_csr_test.elf: verif/core/fence_csr_test.S tb/sw/link.ld | $(BUILD)
	$(CC) -march=$(ARCH) -mabi=$(ABI) -nostdlib -nostartfiles \
	  -T tb/sw/link.ld -o $@ verif/core/fence_csr_test.S

$(BUILD)/fence_csr_test.bin: $(BUILD)/fence_csr_test.elf
	$(OBJCOPY) -O binary --only-section=.text $< $@

# FENCE, FENCE.I and the writable CSRs.  FENCE.I is exercised over real
# self-modifying code -- a store into the I-TCM, then a call -- because
# a test that never changes an instruction would pass on a core that
# ignored the instruction entirely.
fence: $(BUILD)/tb_cdriscv_subsys.vvp $(BUILD)/fence_csr_test.hex \
       $(BUILD)/dtcm_zero.hex
	$(VVP) $(BUILD)/tb_cdriscv_subsys.vvp \
	  +ITCM_HEX=$(BUILD)/fence_csr_test.hex \
	  +DTCM_HEX=$(BUILD)/dtcm_zero.hex \
	  +MAX_CYCLES=100000 | tee $(BUILD)/fence.log
	@grep -q "PASS" $(BUILD)/fence.log

$(BUILD)/trap_test.elf: verif/core/trap_test.S tb/sw/link.ld | $(BUILD)
	$(CC) -march=$(ARCH) -mabi=$(ABI) -nostdlib -nostartfiles \
	  -T tb/sw/link.ld -o $@ verif/core/trap_test.S

$(BUILD)/trap_test.bin: $(BUILD)/trap_test.elf
	$(OBJCOPY) -O binary --only-section=.text $< $@

$(BUILD)/pmp_test.elf: verif/core/pmp_test.S tb/sw/link.ld | $(BUILD)
	$(CC) -march=$(ARCH) -mabi=$(ABI) -nostdlib -nostartfiles \
	  -T tb/sw/link.ld -o $@ verif/core/pmp_test.S

$(BUILD)/pmp_test.bin: $(BUILD)/pmp_test.elf
	$(OBJCOPY) -O binary --only-section=.text $< $@

# Every exception cause the core can raise, with mcause and mtval
# checked for each, plus the illegal encodings a valid program never
# contains.
trap: $(BUILD)/tb_cdriscv_subsys.vvp $(BUILD)/trap_test.hex \
      $(BUILD)/dtcm_zero.hex
	$(VVP) $(BUILD)/tb_cdriscv_subsys.vvp \
	  +ITCM_HEX=$(BUILD)/trap_test.hex \
	  +DTCM_HEX=$(BUILD)/dtcm_zero.hex \
	  +MAX_CYCLES=100000 | tee $(BUILD)/trap.log
	@grep -q "PASS" $(BUILD)/trap.log

# ------------------------------------------------- Zcmp directed test
$(BUILD)/zcmp_test.elf: verif/core/zcmp_test.S tb/sw/link.ld | $(BUILD)
	$(CC) -march=$(ARCH) -mabi=$(ABI) -nostdlib -nostartfiles \
	  -T tb/sw/link.ld -o $@ verif/core/zcmp_test.S

$(BUILD)/zcmp_test.bin: $(BUILD)/zcmp_test.elf
	$(OBJCOPY) -O binary --only-section=.text $< $@

# The sequence semantics the co-simulation cannot see: single
# retirement (minstret), traps mid-sequence with sp untouched, and the
# interrupt-at-boundary rule under a swept CLINT deadline.
zcmp: $(BUILD)/tb_cdriscv_subsys.vvp $(BUILD)/zcmp_test.hex \
      $(BUILD)/dtcm_zero.hex
	$(VVP) $(BUILD)/tb_cdriscv_subsys.vvp \
	  +ITCM_HEX=$(BUILD)/zcmp_test.hex \
	  +DTCM_HEX=$(BUILD)/dtcm_zero.hex \
	  +MAX_CYCLES=100000 | tee $(BUILD)/zcmp.log
	@grep -q "PASS" $(BUILD)/zcmp.log

# ------------------------------------------------- PMP directed test
# The rest of the regression proves PMP does not fire (every region
# resets to OFF).  This proves it does, and in both directions: an
# unlocked entry must NOT bind machine mode, a locked one must.
pmp: $(BUILD)/tb_cdriscv_subsys.vvp $(BUILD)/pmp_test.hex \
     $(BUILD)/dtcm_zero.hex
	$(VVP) $(BUILD)/tb_cdriscv_subsys.vvp \
	  +ITCM_HEX=$(BUILD)/pmp_test.hex \
	  +DTCM_HEX=$(BUILD)/dtcm_zero.hex \
	  +MAX_CYCLES=100000 | tee $(BUILD)/pmp.log
	@grep -q "PASS" $(BUILD)/pmp.log

# ------------------------------------------------- reaction tests
$(BUILD)/reaction_test.elf: verif/safety/reaction_test.S tb/sw/link.ld | $(BUILD)
	$(CC) -march=$(ARCH) -mabi=$(ABI) -nostdlib -nostartfiles \
	  -T tb/sw/link.ld -o $@ verif/safety/reaction_test.S

$(BUILD)/reaction_test.bin: $(BUILD)/reaction_test.elf
	$(OBJCOPY) -O binary --only-section=.text $< $@

# Configures the clock monitor through its registers, checks the safety
# controller lock, and takes a reset request -- which restarts the core,
# so the program recognises its own second boot from a marker left in a
# peripheral register.
reaction: $(BUILD)/tb_cdriscv_subsys.vvp $(BUILD)/reaction_test.hex \
          $(BUILD)/dtcm_zero.hex
	$(VVP) $(BUILD)/tb_cdriscv_subsys.vvp \
	  +ITCM_HEX=$(BUILD)/reaction_test.hex \
	  +DTCM_HEX=$(BUILD)/dtcm_zero.hex \
	  +MAX_CYCLES=500000 | tee $(BUILD)/reaction.log
	@grep -q "PASS" $(BUILD)/reaction.log

# ------------------------------------------------- peripheral tests
$(BUILD)/periph_test.elf: verif/core/periph_test.S tb/sw/link.ld | $(BUILD)
	$(CC) -march=$(ARCH) -mabi=$(ABI) -nostdlib -nostartfiles \
	  -T tb/sw/link.ld -o $@ verif/core/periph_test.S

$(BUILD)/periph_test.bin: $(BUILD)/periph_test.elf
	$(OBJCOPY) -O binary --only-section=.text $< $@

# The memory BIST sweeps every word, so this one takes about 100k
# cycles rather than the few hundred the other tests need.
periph: $(BUILD)/tb_cdriscv_subsys.vvp $(BUILD)/periph_test.hex \
        $(BUILD)/dtcm_zero.hex
	$(VVP) $(BUILD)/tb_cdriscv_subsys.vvp \
	  +ITCM_HEX=$(BUILD)/periph_test.hex \
	  +DTCM_HEX=$(BUILD)/dtcm_zero.hex \
	  +MAX_CYCLES=2000000 | tee $(BUILD)/periph.log
	@grep -q "PASS" $(BUILD)/periph.log

# ------------------------------------------------------ safety tests
$(BUILD)/safety_test.elf: verif/safety/safety_test.S tb/sw/link.ld | $(BUILD)
	$(CC) -march=$(ARCH) -mabi=$(ABI) -nostdlib -nostartfiles \
	  -T tb/sw/link.ld -o $@ verif/safety/safety_test.S

$(BUILD)/safety_test.bin: $(BUILD)/safety_test.elf
	$(OBJCOPY) -O binary --only-section=.text $< $@

$(BUILD)/dtcm_zero.bin: | $(BUILD)
	head -c $$(( $(TCM_WORDS) * 4 )) /dev/zero > $@

$(BUILD)/tb_safety.vvp: $(RTL) verif/safety/tb_safety.sv | $(BUILD)
	$(IVERILOG) -g2012 -o $@ -s tb_safety $(RTL) verif/safety/tb_safety.sv

# Bench half: faults forced inside the checker core and a system clock
# that misbehaves -- neither reachable from software.
safety-bench: $(BUILD)/tb_safety.vvp $(BUILD)/safety_test.hex
	$(VVP) $(BUILD)/tb_safety.vvp +ITCM_HEX=$(BUILD)/safety_test.hex \
	  | tee $(BUILD)/safety_bench.log
	@grep -q "PASS" $(BUILD)/safety_bench.log

safety: safety-sw safety-bench

safety-sw: $(BUILD)/tb_cdriscv_subsys.vvp $(BUILD)/safety_test.hex \
        $(BUILD)/dtcm_zero.hex
	$(VVP) $(BUILD)/tb_cdriscv_subsys.vvp \
	  +ITCM_HEX=$(BUILD)/safety_test.hex \
	  +DTCM_HEX=$(BUILD)/dtcm_zero.hex \
	  +MAX_CYCLES=20000 | tee $(BUILD)/safety.log
	@grep -q "PASS" $(BUILD)/safety.log

# -------------------------------------------------------------- coverage
# Line coverage over the stimulus that exists: the directed ISA program,
# a spread of random programs, and the two subsystem level tests.
COV_SEEDS ?= 1000 1001 1002 1003 1004 1005 1006 1007

COVER_SV := verif/cover/cdriscv_32s_20_cover.sv

$(BUILD)/obj_cov/tb_cosim_cov: $(RTL) verif/core/tb_cosim.sv $(COVER_SV) | $(BUILD)
	$(VERILATOR) --binary --timing -sv --timescale 1ns/1ps --coverage \
	  --coverage-user \
	  -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
	  -Wno-SYNCASYNCNET \
	  --top-module tb_cosim -o tb_cosim_cov -Mdir $(BUILD)/obj_cov \
	  $(RTL) verif/core/tb_cosim.sv $(COVER_SV)

$(BUILD)/obj_syscov/tb_sys_cov: $(RTL) $(TB) $(COVER_SV) | $(BUILD)
	$(VERILATOR) --binary --timing -sv --timescale 1ns/1ps --coverage \
	  --coverage-user \
	  -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
	  -Wno-SYNCASYNCNET -Wno-WIDTHTRUNC \
	  --top-module $(TB_TOP) -o tb_sys_cov -Mdir $(BUILD)/obj_syscov \
	  $(RTL) $(TB) $(COVER_SV)

# Every simulation below is joined to its `mv` with && rather than `;`.
# With a semicolon the recipe keeps the coverage of a run that failed:
# the simulation exits non-zero, the status is dropped, the .dat is
# collected anyway and lands in the merge.  Coverage measured from a
# failing test is not coverage.
#
# The && alone is NOT enough (finding, verification_findings_20.md
# section 17): tb_cdriscv_subsys reports FAIL by $display and exits 0
# through $finish, so the exit status only filters crashes.  Every run
# below therefore also captures its log and greps the verdict, the way
# the pmp/zcmp runs were added -- a bench printing FAIL but exiting 0
# must be excluded from the merge, not silently counted.  The cosim
# runs have no PASS verdict (the Spike comparison happens in `make
# cosim`), so their guard is the absence of the failure words the bench
# can print: TIMEOUT, FAULT, ASSERTION.
# The clock monitor bench runs under Icarus like the other block
# benches, but coverage is measured only from the Verilator builds, so
# without a Verilator build of it the report goes on showing lines as
# uncovered that are in fact tested.  A coverage report that
# understates is no more useful than one that overstates.
$(BUILD)/obj_cmcov/tb_clkmon_cov: rtl/common/cdriscv_32s_20_sync.sv \
                                  rtl/common/cdriscv_32s_20_cfg_parity.sv \
                                  rtl/safety/cdriscv_32s_20_clkmon.sv \
                                  verif/block/clkmon/tb_clkmon.sv | $(BUILD)
	$(VERILATOR) --binary --timing -sv --timescale 1ns/1ps --coverage \
	  -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
	  -Wno-SYNCASYNCNET \
	  --top-module tb_clkmon -o tb_clkmon_cov -Mdir $(BUILD)/obj_cmcov \
	  rtl/common/cdriscv_32s_20_sync.sv rtl/common/cdriscv_32s_20_cfg_parity.sv \
	  rtl/safety/cdriscv_32s_20_clkmon.sv \
	  verif/block/clkmon/tb_clkmon.sv

# The tck-domain blocks (jtag_tap, dbg_bridge, dbg_win) cannot be
# exercised from the system bench -- nothing in it drives tck.  Their
# block benches own the tck generator, so the same argument as the
# clock monitor applies: without Verilator builds of them the report
# shows their lines as uncovered when they are in fact tested.  The
# merge is safe because verilator_coverage keys line points by source
# file and line, exactly as it already does for sync.sv, which appears
# in the clkmon build and every subsystem build.
$(BUILD)/obj_jtagcov/tb_jtag_cov: rtl/debug/cdriscv_32s_20_jtag_tap.sv \
                                  verif/block/jtag/tb_jtag.sv | $(BUILD)
	$(VERILATOR) --binary --timing -sv --timescale 1ns/1ps --coverage \
	  -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
	  -Wno-SYNCASYNCNET \
	  --top-module tb_jtag -o tb_jtag_cov -Mdir $(BUILD)/obj_jtagcov \
	  rtl/debug/cdriscv_32s_20_jtag_tap.sv verif/block/jtag/tb_jtag.sv

$(BUILD)/obj_dbgcov/tb_dbg_cov: rtl/common/cdriscv_32s_20_sync.sv \
                                rtl/debug/cdriscv_32s_20_dbg_bridge.sv \
                                rtl/debug/cdriscv_32s_20_dbg_win.sv \
                                verif/block/dbg/tb_dbg.sv | $(BUILD)
	$(VERILATOR) --binary --timing -sv --timescale 1ns/1ps --coverage \
	  -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
	  -Wno-SYNCASYNCNET \
	  --top-module tb_dbg -o tb_dbg_cov -Mdir $(BUILD)/obj_dbgcov \
	  rtl/common/cdriscv_32s_20_sync.sv \
	  rtl/debug/cdriscv_32s_20_dbg_bridge.sv \
	  rtl/debug/cdriscv_32s_20_dbg_win.sv \
	  verif/block/dbg/tb_dbg.sv

# The safety bench is where the mechanisms live that software cannot
# provoke -- register file parity, a failing BIST, a watchdog reset.  It
# runs under Icarus like the other benches, so without a Verilator build
# of it those cover points read as never hit even though they are
# tested.  Same argument as the clock monitor bench.
$(BUILD)/obj_sftycov/tb_safety_cov: $(RTL) verif/safety/tb_safety.sv $(COVER_SV) | $(BUILD)
	$(VERILATOR) --binary --timing -sv --timescale 1ns/1ps --coverage \
	  --coverage-user \
	  -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
	  -Wno-SYNCASYNCNET -Wno-WIDTHTRUNC \
	  --top-module tb_safety -o tb_safety_cov -Mdir $(BUILD)/obj_sftycov \
	  $(RTL) verif/safety/tb_safety.sv $(COVER_SV)

coverage: $(BUILD)/obj_cov/tb_cosim_cov $(BUILD)/obj_syscov/tb_sys_cov \
          $(BUILD)/obj_sftycov/tb_safety_cov \
          $(BUILD)/obj_cmcov/tb_clkmon_cov \
          $(BUILD)/obj_jtagcov/tb_jtag_cov $(BUILD)/obj_dbgcov/tb_dbg_cov \
          $(BUILD)/cosim_isa.hex $(BUILD)/safety_test.hex \
          $(BUILD)/periph_test.hex $(BUILD)/reaction_test.hex \
          $(BUILD)/trap_test.hex $(BUILD)/ams_test.hex \
          $(BUILD)/fence_csr_test.hex $(BUILD)/rdback_test.hex \
          $(BUILD)/safety_test.hex \
          $(BUILD)/pmp_test.hex $(BUILD)/zcmp_test.hex \
          $(BUILD)/regwalk_test.hex $(BUILD)/dtcm_zero.hex sw
	@# The tb_cosim_cov soaks end by cycle-cap TIMEOUT by design: the
	@# workload completes and parks (WFI/spin), and the stall variants can
	@# never reach MAXRETIRE under 90 % back-pressure.  The exit guard
	@# therefore greps for FAULT|ASSERTION only -- adding TIMEOUT to it
	@# rejects every healthy soak (found the hard way, 2026-09-02).
	@mkdir -p $(BUILD)/cov && rm -f $(BUILD)/cov/*.dat
	@./$(BUILD)/obj_cov/tb_cosim_cov +HEX=$(BUILD)/cosim_isa.hex \
	  +MAXRETIRE=100000 +QUIET > $(BUILD)/cov/isa_cov.log 2>&1 && \
	  ! grep -qE "FAULT|ASSERTION" $(BUILD)/cov/isa_cov.log && \
	  mv coverage.dat $(BUILD)/cov/cov_isa.dat
	@for p in 15 35 70 90; do \
	  ./$(BUILD)/obj_cov/tb_cosim_cov +HEX=$(BUILD)/cosim_isa.hex \
	    +MAXRETIRE=100000 +STALL=$$p +QUIET \
	    > $(BUILD)/cov/isa_stall$${p}_cov.log 2>&1 && \
	  ! grep -qE "FAULT|ASSERTION" $(BUILD)/cov/isa_stall$${p}_cov.log && \
	  mv coverage.dat $(BUILD)/cov/cov_isa_stall$$p.dat || exit 1; \
	done
	@for s in $(COV_SEEDS); do \
	  if [ -f $(BUILD)/random/rand_$$s.hex ]; then \
	    ./$(BUILD)/obj_cov/tb_cosim_cov +HEX=$(BUILD)/random/rand_$$s.hex \
	      +MAXRETIRE=100000 +QUIET > $(BUILD)/cov/r$${s}_cov.log 2>&1 && \
	    ! grep -qE "FAULT|ASSERTION" $(BUILD)/cov/r$${s}_cov.log && \
	    mv coverage.dat $(BUILD)/cov/cov_r$$s.dat || exit 1; \
	  fi; done
	@./$(BUILD)/obj_syscov/tb_sys_cov +ITCM_HEX=$(BUILD)/prog.itcm.hex \
	  +DTCM_HEX=$(BUILD)/prog.dtcm.hex +MAX_CYCLES=20000 \
	  > $(BUILD)/cov/smoke_cov.log 2>&1 && \
	  grep -q "\[TB\] PASS" $(BUILD)/cov/smoke_cov.log && \
	  mv coverage.dat $(BUILD)/cov/cov_smoke.dat
	@./$(BUILD)/obj_syscov/tb_sys_cov +ITCM_HEX=$(BUILD)/safety_test.hex \
	  +DTCM_HEX=$(BUILD)/dtcm_zero.hex +MAX_CYCLES=20000 \
	  > $(BUILD)/cov/safety_cov.log 2>&1 && \
	  grep -q "\[TB\] PASS" $(BUILD)/cov/safety_cov.log && \
	  mv coverage.dat $(BUILD)/cov/cov_safety.dat
	@./$(BUILD)/obj_syscov/tb_sys_cov +ITCM_HEX=$(BUILD)/periph_test.hex \
	  +DTCM_HEX=$(BUILD)/dtcm_zero.hex +MAX_CYCLES=2000000 \
	  > $(BUILD)/cov/periph_cov.log 2>&1 && \
	  grep -q "\[TB\] PASS" $(BUILD)/cov/periph_cov.log && \
	  mv coverage.dat $(BUILD)/cov/cov_periph.dat
	@./$(BUILD)/obj_syscov/tb_sys_cov +ITCM_HEX=$(BUILD)/reaction_test.hex \
	  +DTCM_HEX=$(BUILD)/dtcm_zero.hex +MAX_CYCLES=500000 \
	  > $(BUILD)/cov/reaction_cov.log 2>&1 && \
	  grep -q "\[TB\] PASS" $(BUILD)/cov/reaction_cov.log && \
	  mv coverage.dat $(BUILD)/cov/cov_reaction.dat
	@./$(BUILD)/obj_syscov/tb_sys_cov +ITCM_HEX=$(BUILD)/rdback_test.hex \
	  +DTCM_HEX=$(BUILD)/dtcm_zero.hex +MAX_CYCLES=300000 \
	  > $(BUILD)/cov/rdback_cov.log 2>&1 && \
	  grep -q "\[TB\] PASS" $(BUILD)/cov/rdback_cov.log && \
	  mv coverage.dat $(BUILD)/cov/cov_rdback.dat
	@./$(BUILD)/obj_syscov/tb_sys_cov +ITCM_HEX=$(BUILD)/fence_csr_test.hex \
	  +DTCM_HEX=$(BUILD)/dtcm_zero.hex +MAX_CYCLES=100000 \
	  > $(BUILD)/cov/fence_cov.log 2>&1 && \
	  grep -q "\[TB\] PASS" $(BUILD)/cov/fence_cov.log && \
	  mv coverage.dat $(BUILD)/cov/cov_fence.dat
	@./$(BUILD)/obj_syscov/tb_sys_cov +ITCM_HEX=$(BUILD)/trap_test.hex \
	  +DTCM_HEX=$(BUILD)/dtcm_zero.hex +MAX_CYCLES=100000 \
	  > $(BUILD)/cov/trap_cov.log 2>&1 && \
	  grep -q "\[TB\] PASS" $(BUILD)/cov/trap_cov.log && \
	  mv coverage.dat $(BUILD)/cov/cov_trap.dat
	@./$(BUILD)/obj_syscov/tb_sys_cov +ITCM_HEX=$(BUILD)/ams_test.hex \
	  +DTCM_HEX=$(BUILD)/dtcm_zero.hex +MAX_CYCLES=300000 \
	  > $(BUILD)/cov/ams_cov.log 2>&1 && \
	  grep -q "\[TB\] PASS" $(BUILD)/cov/ams_cov.log && \
	  mv coverage.dat $(BUILD)/cov/cov_ams.dat
	@./$(BUILD)/obj_syscov/tb_sys_cov +ITCM_HEX=$(BUILD)/regwalk_test.hex \
	  +DTCM_HEX=$(BUILD)/dtcm_zero.hex +MAX_CYCLES=200000 \
	  > $(BUILD)/cov/regwalk_cov.log 2>&1 && \
	  grep -q "\[TB\] PASS" $(BUILD)/cov/regwalk_cov.log && \
	  mv coverage.dat $(BUILD)/cov/cov_regwalk.dat
	@./$(BUILD)/obj_syscov/tb_sys_cov +ITCM_HEX=$(BUILD)/pmp_test.hex \
	  +DTCM_HEX=$(BUILD)/dtcm_zero.hex +MAX_CYCLES=100000 \
	  > $(BUILD)/cov/pmp_cov.log 2>&1 && \
	  grep -q "\[TB\] PASS" $(BUILD)/cov/pmp_cov.log && \
	  mv coverage.dat $(BUILD)/cov/cov_pmp.dat
	@./$(BUILD)/obj_syscov/tb_sys_cov +ITCM_HEX=$(BUILD)/zcmp_test.hex \
	  +DTCM_HEX=$(BUILD)/dtcm_zero.hex +MAX_CYCLES=100000 \
	  > $(BUILD)/cov/zcmp_cov.log 2>&1 && \
	  grep -q "\[TB\] PASS" $(BUILD)/cov/zcmp_cov.log && \
	  mv coverage.dat $(BUILD)/cov/cov_zcmp.dat
	@./$(BUILD)/obj_cmcov/tb_clkmon_cov > $(BUILD)/cov/clkmon_cov.log 2>&1 && \
	  grep -q "PASS" $(BUILD)/cov/clkmon_cov.log && \
	  mv coverage.dat $(BUILD)/cov/cov_clkmon.dat
	@./$(BUILD)/obj_jtagcov/tb_jtag_cov > $(BUILD)/cov/jtag_cov.log 2>&1 && \
	  grep -q "PASS" $(BUILD)/cov/jtag_cov.log && \
	  mv coverage.dat $(BUILD)/cov/cov_jtag.dat
	@./$(BUILD)/obj_dbgcov/tb_dbg_cov > $(BUILD)/cov/dbg_cov.log 2>&1 && \
	  grep -q "PASS" $(BUILD)/cov/dbg_cov.log && \
	  mv coverage.dat $(BUILD)/cov/cov_dbg.dat
	@./$(BUILD)/obj_sftycov/tb_safety_cov +ITCM_HEX=$(BUILD)/safety_test.hex \
	  > $(BUILD)/cov/safetybench_cov.log 2>&1 && \
	  grep -q "\[tb_safety\] PASS" $(BUILD)/cov/safetybench_cov.log && \
	  mv coverage.dat $(BUILD)/cov/cov_safetybench.dat
	verilator_coverage --write $(BUILD)/cov/merged.dat $(BUILD)/cov/cov_*.dat
	@rm -rf $(BUILD)/cov/ann_line $(BUILD)/cov/ann_tog
	verilator_coverage --filter-type line --annotate $(BUILD)/cov/ann_line \
	  --annotate-min 1 $(BUILD)/cov/merged.dat > /dev/null
	verilator_coverage --filter-type toggle --annotate $(BUILD)/cov/ann_tog \
	  --annotate-min 1 $(BUILD)/cov/merged.dat > /dev/null
	@$(PYTHON) scripts/coverage_report.py $(BUILD)/cov/ann_line \
	  "line coverage" | tee $(BUILD)/coverage.txt
	@echo "" | tee -a $(BUILD)/coverage.txt
	@$(PYTHON) scripts/coverage_report.py $(BUILD)/cov/ann_tog \
	  "toggle coverage" | head -3 | tee -a $(BUILD)/coverage.txt
	@echo "" | tee -a $(BUILD)/coverage.txt
	@$(PYTHON) scripts/funccov_report.py $(BUILD)/cov/merged.dat \
	  | tee -a $(BUILD)/coverage.txt

# Workload D is workload A plus the mitigation the safety manual
# recommends: re-read every configuration register each iteration and
# raise the software fault on a mismatch.  Running the same fault list
# against A and D measures what that advice is worth -- V30.
fi-check: $(BUILD)/tb_fi.vvp $(BUILD)/fi_workload_check.hex $(BUILD)/dtcm_zero.hex
	$(PYTHON) scripts/fi_campaign.py --runs $(FI_RUNS) --seed $(FI_SEED) \
	  --hex $(BUILD)/fi_workload_check.hex --golden f095470a \
	  --golden-cfg fffffcfd_00010000_000021e4_00000000 \
	  --sw-detect bad0c0de \
	  --ibase 76 --ispan 70 --min-cycle 200 --max-cycle 9000 \
	  --name "D: arithmetic and memory, with a configuration check" \
	  | tee $(BUILD)/fi_campaign_check.txt

# ------------------------------------------------- gate level (O8)
# Synthesis to real IHP SG13G2 standard cells, then the *same* block
# benches re-run against the netlist.  Passing on the RTL and passing
# on the gates are different claims: synthesis restructures logic,
# re-encodes state and drops anything it can prove unreachable, and the
# coverage waivers in verif/coverage_waivers.md are written against the
# RTL.
#
# This is a **functional** gate level simulation and not a timing one.
# Every delay in the SG13G2 Verilog models is (0.0,0.0) -- they are
# placeholders for back-annotation -- so what this checks is that the
# netlist computes what the RTL computed and that nothing goes X.
# Timing needs static timing analysis against the same library, which
# is a separate job and is not done.
GATE_PDK   ?= /foss/pdks/ihp-sg13g2/libs.ref/sg13g2_stdcell
GATE_LIB   ?= $(GATE_PDK)/lib/sg13g2_stdcell_typ_1p20V_25C.lib
GATE_CELLS := $(BUILD)/gate/sg13g2_cells.v
GATE_UDP   := $(BUILD)/gate/sg13g2_udp.v

$(BUILD)/gate:
	mkdir -p $(BUILD)/gate

# Icarus rejects the models as shipped -- "ifnone with an
# edge-sensitive path is not supported" -- and the blocks it chokes on
# carry no information, every delay in them being zero.
$(GATE_CELLS): $(GATE_PDK)/verilog/sg13g2_stdcell.v | $(BUILD)/gate
	$(PYTHON) scripts/strip_specify.py $< $@

$(GATE_UDP): $(GATE_PDK)/verilog/sg13g2_udp.v | $(BUILD)/gate
	$(PYTHON) scripts/strip_specify.py $< $@

GATE_PKG := rtl/core/cdriscv_32s_20_pkg.sv

define gate_synth
	$(YOSYS) -p "plugin -i slang; \
	  read_slang --top $(1) $(GATE_PKG) $(2); \
	  synth -top $(1) -flatten; \
	  dfflibmap -liberty $(GATE_LIB); \
	  abc -liberty $(GATE_LIB); \
	  opt_clean; \
	  write_verilog -noattr $@; \
	  stat -liberty $(GATE_LIB)" -l $(BUILD)/gate/$(1)_synth.log
	@grep -E "Chip area for module" $(BUILD)/gate/$(1)_synth.log
endef

$(BUILD)/gate/cdriscv_32s_20_alu_gate.v: $(GATE_PKG) rtl/core/cdriscv_32s_20_alu.sv | $(BUILD)/gate
	$(call gate_synth,cdriscv_32s_20_alu,rtl/core/cdriscv_32s_20_alu.sv)

$(BUILD)/gate/cdriscv_32s_20_multdiv_gate.v: $(GATE_PKG) rtl/core/cdriscv_32s_20_multdiv.sv | $(BUILD)/gate
	$(call gate_synth,cdriscv_32s_20_multdiv,rtl/core/cdriscv_32s_20_multdiv.sv)

# The SEC-DED file holds two independent modules, encoder and decoder,
# so each gets its own synthesis run and the bench compiles both.
$(BUILD)/gate/cdriscv_32s_20_ecc_enc_gate.v: $(GATE_PKG) rtl/safety/cdriscv_32s_20_ecc_secded.sv | $(BUILD)/gate
	$(call gate_synth,cdriscv_32s_20_ecc_enc,rtl/safety/cdriscv_32s_20_ecc_secded.sv)

$(BUILD)/gate/cdriscv_32s_20_ecc_dec_gate.v: $(GATE_PKG) rtl/safety/cdriscv_32s_20_ecc_secded.sv | $(BUILD)/gate
	$(call gate_synth,cdriscv_32s_20_ecc_dec,rtl/safety/cdriscv_32s_20_ecc_secded.sv)

$(BUILD)/gate/tb_alu_gate.vvp: $(BUILD)/gate/cdriscv_32s_20_alu_gate.v $(GATE_CELLS) \
                               $(GATE_UDP) verif/block/alu/tb_alu.sv
	$(IVERILOG) -g2012 -o $@ -s tb_alu $(GATE_PKG) $^

$(BUILD)/gate/tb_multdiv_gate.vvp: $(BUILD)/gate/cdriscv_32s_20_multdiv_gate.v $(GATE_CELLS) \
                                   $(GATE_UDP) verif/block/multdiv/tb_multdiv.sv
	$(IVERILOG) -g2012 -o $@ -s tb_multdiv $(GATE_PKG) $^

$(BUILD)/gate/tb_ecc_gate.vvp: $(BUILD)/gate/cdriscv_32s_20_ecc_enc_gate.v \
                               $(BUILD)/gate/cdriscv_32s_20_ecc_dec_gate.v $(GATE_CELLS) \
                               $(GATE_UDP) verif/block/ecc/tb_ecc.sv
	$(IVERILOG) -g2012 -o $@ -s tb_ecc $(GATE_PKG) $^

gate-alu: $(BUILD)/gate/tb_alu_gate.vvp $(ALU_VECTORS)
	$(VVP) $< +VEC=$(ALU_VECTORS) +NVEC=$$(wc -l < $(ALU_VECTORS)) \
	  | tee $(BUILD)/gate/alu.log
	@grep -q "PASS" $(BUILD)/gate/alu.log

# +NOWHITEBOX: the acc_q[32] invariant is an assertion about an RTL
# signal that synthesis is entitled to remove -- and does, having
# reached the same conclusion the invariant states.  See V16 in
# verification_findings.md.
gate-multdiv: $(BUILD)/gate/tb_multdiv_gate.vvp $(MD_VECTORS)
	$(VVP) $< +VEC=$(MD_VECTORS) +NVEC=$$(wc -l < $(MD_VECTORS)) +NOWHITEBOX \
	  | tee $(BUILD)/gate/multdiv.log
	@grep -q "PASS" $(BUILD)/gate/multdiv.log

gate-ecc: $(BUILD)/gate/tb_ecc_gate.vvp
	$(VVP) $< +PATTERNS=$(ECC_PATTERNS) | tee $(BUILD)/gate/ecc.log
	@grep -q "PASS" $(BUILD)/gate/ecc.log

# W2a says the state machine `default:` arms must stay because they
# recover from an upset, and that the argument has to be re-made against
# the netlist since synthesis may optimise an unreachable state away.
# This is that check, on real cells.
$(BUILD)/gate/tb_gate_fsm.vvp: $(BUILD)/gate/cdriscv_32s_20_multdiv_gate.v $(GATE_CELLS) \
                               $(GATE_UDP) verif/gate/tb_gate_fsm.sv
	$(IVERILOG) -g2012 -o $@ -s tb_gate_fsm $(GATE_PKG) $^

gate-fsm: $(BUILD)/gate/tb_gate_fsm.vvp
	$(VVP) $< | tee $(BUILD)/gate/fsm.log
	@grep -q "PASS" $(BUILD)/gate/fsm.log

# ---- the whole subsystem, memories black-boxed -------------------
# The TCMs are 4096 x 39 arrays.  Synthesised as logic they become a
# third of a million flip-flops -- a first attempt mapped 325107 before
# it was killed -- and in silicon they are compiled SRAM macros that a
# netlist instantiates rather than contains.  So synthesis reads a
# black box stub in place of the real module, and simulation binds the
# real one back: memory behaves as at RTL, everything around it is
# gates.
#
# Marking the real module `blackbox` inside yosys does not work: the
# slang front end specialises parameterised modules, so the instances
# are $paramod\cdriscv_32s_20_tcm\... and the command matches nothing.
# Silently -- which is why the first run looked slow rather than wrong.
GATE_RTL := $(filter-out rtl/bus/cdriscv_32s_20_tcm.sv,$(RTL))

$(BUILD)/gate/cdriscv_32s_20_subsys_gate.v: $(RTL) verif/gate/cdriscv_32s_20_tcm_bb.sv | $(BUILD)/gate
	$(YOSYS) -p "plugin -i slang; \
	  read_slang --top $(TOP) verif/gate/cdriscv_32s_20_tcm_bb.sv $(GATE_RTL); \
	  synth -top $(TOP) -flatten; \
	  dfflibmap -liberty $(GATE_LIB); \
	  abc -liberty $(GATE_LIB); \
	  opt_clean; \
	  write_verilog -noattr $@; \
	  stat -liberty $(GATE_LIB)" -l $(BUILD)/gate/subsys_synth.log
	@grep -E "Chip area for module|cells to .sg13g2_dfrbpq" $(BUILD)/gate/subsys_synth.log

# -DGATE_LEVEL drops the parameter overrides (a netlist is one
# configuration, not a parameterisable module) and the one white box
# reference the bench makes into the safety controller.  The memory
# preload still works: the TCMs are black boxes, so dut.u_itcm.mem is
# still a real hierarchical path.
$(BUILD)/gate/tb_subsys_gate.vvp: $(BUILD)/gate/cdriscv_32s_20_subsys_gate.v $(GATE_CELLS) \
                                  $(GATE_UDP) $(TB) rtl/bus/cdriscv_32s_20_tcm.sv
	$(IVERILOG) -g2012 -DGATE_LEVEL -o $@ -s $(TB_TOP) \
	  $(GATE_PKG) rtl/bus/cdriscv_32s_20_tcm.sv rtl/safety/cdriscv_32s_20_ecc_secded.sv \
	  $(BUILD)/gate/cdriscv_32s_20_subsys_gate.v $(GATE_UDP) $(GATE_CELLS) $(TB)

gate-subsys: $(BUILD)/gate/tb_subsys_gate.vvp $(BUILD)/prog.itcm.hex \
             $(BUILD)/safety_test.hex $(BUILD)/trap_test.hex \
             $(BUILD)/fence_csr_test.hex $(BUILD)/dtcm_zero.hex
	@rm -f $(BUILD)/gate/subsys.log
	@for t in "prog.itcm 20000" "safety_test 20000" "trap_test 100000" \
	          "fence_csr_test 100000"; do \
	  set -- $$t; \
	  if [ "$$1" = "prog.itcm" ]; then d=$(BUILD)/prog.dtcm.hex; \
	  else d=$(BUILD)/dtcm_zero.hex; fi; \
	  echo "--- $$1 ---" | tee -a $(BUILD)/gate/subsys.log; \
	  $(VVP) $< +ITCM_HEX=$(BUILD)/$$1.hex +DTCM_HEX=$$d \
	    +MAX_CYCLES=$$2 2>/dev/null | grep -E "^\[TB\] (PASS|FAIL)" \
	    | tee -a $(BUILD)/gate/subsys.log || exit 1; \
	done
	@if grep -q FAIL $(BUILD)/gate/subsys.log; then \
	  echo "gate-subsys: FAIL"; exit 1; else echo "gate-subsys: all programs pass"; fi

$(BUILD)/gate/cdriscv_32s_20_apb_bridge_gate.v: $(GATE_PKG) rtl/bus/cdriscv_32s_20_apb_bridge.sv | $(BUILD)/gate
	$(call gate_synth,cdriscv_32s_20_apb_bridge,rtl/bus/cdriscv_32s_20_apb_bridge.sv)

$(BUILD)/gate/tb_gate_fsm_apb.vvp: $(BUILD)/gate/cdriscv_32s_20_apb_bridge_gate.v $(GATE_CELLS) \
                                   $(GATE_UDP) verif/gate/tb_gate_fsm_apb.sv
	$(IVERILOG) -g2012 -o $@ -s tb_gate_fsm_apb $(GATE_PKG) $^

gate-fsm-apb: $(BUILD)/gate/tb_gate_fsm_apb.vvp
	$(VVP) $< | tee $(BUILD)/gate/fsm_apb.log
	@grep -q "PASS" $(BUILD)/gate/fsm_apb.log

# The LSU's bench ties data_gnt_i and data_rvalid_i high.  Without them
# the machine sits for ever in a legal state waiting for a bus response
# and the check reports a recovery failure that is nothing of the kind.
verif/gate/tb_fsm_cdriscv_lsu.sv: rtl/core/cdriscv_32s_20_lsu.sv scripts/gen_fsm_bench.py
	$(PYTHON) scripts/gen_fsm_bench.py $< cdriscv_32s_20_lsu state_q 3 $@ \
	  data_gnt_i,data_rvalid_i

$(BUILD)/gate/cdriscv_32s_20_lsu_gate.v: $(GATE_PKG) rtl/core/cdriscv_32s_20_lsu.sv | $(BUILD)/gate
	$(call gate_synth,cdriscv_32s_20_lsu,rtl/core/cdriscv_32s_20_lsu.sv)

$(BUILD)/gate/tb_fsm_cdriscv_lsu.vvp: $(BUILD)/gate/cdriscv_32s_20_lsu_gate.v $(GATE_CELLS) \
                                      $(GATE_UDP) verif/gate/tb_fsm_cdriscv_lsu.sv
	$(IVERILOG) -g2012 -o $@ -s tb_fsm_cdriscv_lsu $(GATE_PKG) $^

gate-fsm-lsu: $(BUILD)/gate/tb_fsm_cdriscv_lsu.vvp
	$(VVP) $< | tee $(BUILD)/gate/fsm_lsu.log
	@grep -q "PASS" $(BUILD)/gate/fsm_lsu.log

# The BIST is synthesised at Depth=16.  At the real 4096 a forced state
# restarts a march over the whole array and the settle window would have
# to be tens of thousands of cycles; the state machine is the same
# either way.
$(BUILD)/gate/cdriscv_32s_20_mbist_gate.v: $(GATE_PKG) rtl/safety/cdriscv_32s_20_mbist.sv | $(BUILD)/gate
	$(YOSYS) -p "plugin -i slang; \
	  read_slang --top cdriscv_32s_20_mbist -G Depth=16 $(GATE_PKG) rtl/safety/cdriscv_32s_20_mbist.sv; \
	  synth -top cdriscv_32s_20_mbist -flatten; \
	  dfflibmap -liberty $(GATE_LIB); \
	  abc -liberty $(GATE_LIB); \
	  opt_clean; \
	  write_verilog -noattr $@" -l $(BUILD)/gate/mbist_synth.log

$(BUILD)/gate/tb_fsm_cdriscv_mbist.vvp: $(BUILD)/gate/cdriscv_32s_20_mbist_gate.v $(GATE_CELLS) \
                                        $(GATE_UDP) verif/gate/tb_fsm_cdriscv_mbist.sv
	$(IVERILOG) -g2012 -o $@ -s tb_fsm_cdriscv_mbist $(GATE_PKG) $^

gate-fsm-mbist: $(BUILD)/gate/tb_fsm_cdriscv_mbist.vvp
	$(VVP) $< | tee $(BUILD)/gate/fsm_mbist.log
	@grep -q "PASS" $(BUILD)/gate/fsm_mbist.log

$(BUILD)/gate/cdriscv_32s_20_ams_if_gate.v: $(GATE_PKG) rtl/common/cdriscv_32s_20_sync.sv \
                                     rtl/common/cdriscv_32s_20_cfg_parity.sv \
                                     rtl/periph/cdriscv_32s_20_ams_if.sv | $(BUILD)/gate
	$(YOSYS) -p "plugin -i slang; \
	  read_slang --top cdriscv_32s_20_ams_if $(GATE_PKG) rtl/common/cdriscv_32s_20_sync.sv \
	    rtl/common/cdriscv_32s_20_cfg_parity.sv rtl/periph/cdriscv_32s_20_ams_if.sv; \
	  synth -top cdriscv_32s_20_ams_if -flatten; \
	  dfflibmap -liberty $(GATE_LIB); abc -liberty $(GATE_LIB); opt_clean; \
	  write_verilog -noattr $@" -l $(BUILD)/gate/ams_synth.log

$(BUILD)/gate/tb_fsm_cdriscv_ams_if.vvp: $(BUILD)/gate/cdriscv_32s_20_ams_if_gate.v \
                                         $(GATE_CELLS) $(GATE_UDP) \
                                         verif/gate/tb_fsm_cdriscv_ams_if.sv
	$(IVERILOG) -g2012 -o $@ -s tb_fsm_cdriscv_ams_if $(GATE_PKG) $^

gate-fsm-ams: $(BUILD)/gate/tb_fsm_cdriscv_ams_if.vvp
	$(VVP) $< | tee $(BUILD)/gate/fsm_ams.log
	@grep -q "PASS" $(BUILD)/gate/fsm_ams.log

CORE_RTL := rtl/core/cdriscv_32s_20_pkg.sv rtl/common/cdriscv_32s_20_sync.sv \
            rtl/common/cdriscv_32s_20_cfg_parity.sv rtl/common/cdriscv_32s_20_counter64.sv \
            rtl/core/cdriscv_32s_20_alu.sv rtl/core/cdriscv_32s_20_decoder.sv \
            rtl/core/cdriscv_32s_20_regfile.sv rtl/core/cdriscv_32s_20_multdiv.sv \
            rtl/core/cdriscv_32s_20_lsu.sv rtl/core/cdriscv_32s_20_csr.sv \
            rtl/core/cdriscv_32s_20_if_stage.sv rtl/core/cdriscv_32s_20_core.sv

$(BUILD)/gate/cdriscv_32s_20_core_gate.v: $(CORE_RTL) | $(BUILD)/gate
	$(YOSYS) -p "plugin -i slang; \
	  read_slang --top cdriscv_32s_20_core $(CORE_RTL); \
	  synth -top cdriscv_32s_20_core -flatten; \
	  dfflibmap -liberty $(GATE_LIB); abc -liberty $(GATE_LIB); opt_clean; \
	  write_verilog -noattr $@" -l $(BUILD)/gate/core_synth.log

$(BUILD)/gate/tb_fsm_cdriscv_core.vvp: $(BUILD)/gate/cdriscv_32s_20_core_gate.v \
                                       $(GATE_CELLS) $(GATE_UDP) \
                                       verif/gate/tb_fsm_cdriscv_core.sv
	$(IVERILOG) -g2012 -o $@ -s tb_fsm_cdriscv_core $(GATE_PKG) $^

gate-fsm-core: $(BUILD)/gate/tb_fsm_cdriscv_core.vvp
	$(VVP) $< | tee $(BUILD)/gate/fsm_core.log
	@grep -q "PASS" $(BUILD)/gate/fsm_core.log

gate: gate-alu gate-multdiv gate-ecc gate-fsm gate-fsm-apb gate-fsm-lsu \
      gate-fsm-mbist gate-fsm-ams gate-fsm-core gate-subsys

# ------------------------------------------------- RISCOF (O1)
# The architectural test suite is fetched, not vendored -- see
# verif/riscof/README.md, which also records why this does not yet
# produce a result.
# riscv-arch-test 3.5.3, not a current release: from 3.6.0 onward env/arch_test.h
# wraps its .align directives in ".option rvc", so the assembler pads with c.nop
# and that padding lands in the executable stream.  An RV32I core must trap on a
# 16-bit encoding -- and Spike traps at the same address.  See verif/riscof/README.md.
RISCOF_SUITE := verif/riscof/riscv-arch-test/riscv-test-suite

# A separate build with a larger instruction memory: the architectural
# tests do not fit in the 4096 words the subsystem defaults to.
# The architectural tests need far more memory than any other bench
# here.  jal-01.S spans 437928 words because JAL has a plus/minus 1 MiB
# range and the test exercises the extremes; beq-01.S needs 57296.  At
# too small a size the image is silently truncated at load and the
# symptom is a bus error around cycle 90, which says nothing about the
# cause.
RISCOF_ITCM ?= 524288

$(BUILD)/tb_cosim_arch.vvp: $(RTL) verif/core/tb_cosim.sv | $(BUILD)
	$(IVERILOG) -g2012 -Ptb_cosim.ItcmWords=$(RISCOF_ITCM) -o $@ -s tb_cosim \
	  $(RTL) verif/core/tb_cosim.sv

# ------------------------------------------------- gate + SDF (O8)
# The placed-and-repaired netlist with its own SDF, real cell and
# estimated interconnect delays, at the 20 ns target clock.  The
# netlist and SDF come out of `make fmax`; the cell models keep their
# specify blocks (only the ifnone paths Icarus rejects are removed),
# and the SRAM macros simulate as the vendor behavioural model.
# `=` not `:=`: SRAM_PDK is defined further down in the fmax section,
# and an immediate assignment here would capture it empty.
SRAM_V = $(SRAM_PDK)/verilog

$(BUILD)/gate/sg13g2_cells_sdf.v: $(GATE_PDK)/verilog/sg13g2_stdcell.v \
                                  scripts/sdf_specify_fixup.py | $(BUILD)/gate
	$(PYTHON) scripts/sdf_specify_fixup.py $< $@

$(BUILD)/gate/tb_sdf_subsys.vvp: $(BUILD)/gate/cdriscv_32s_20_subsys_pd_final.v \
                                 $(BUILD)/gate/sg13g2_cells_sdf.v $(GATE_UDP) \
                                 verif/gate/tb_sdf_subsys.sv
	$(IVERILOG) -g2012 -gspecify -ginterconnect -DFUNCTIONAL -o $@ -s tb_sdf_subsys \
	  $(BUILD)/gate/cdriscv_32s_20_subsys_pd_final.v \
	  $(BUILD)/gate/sg13g2_cells_sdf.v $(GATE_UDP) \
	  $(SRAM_V)/RM_IHPSG13_1P_2048x64_c2_bm_bist.v \
	  $(SRAM_V)/RM_IHPSG13_1P_core_behavioral_bm_bist.v \
	  verif/gate/tb_sdf_subsys.sv

$(BUILD)/gate/cdriscv_32s_20_subsys_pd_sim.sdf: $(BUILD)/gate/cdriscv_32s_20_subsys_pd.sdf \
                                         scripts/sdf_sim_filter.py
	$(PYTHON) scripts/sdf_sim_filter.py $< $@

# The O8 architectural subset: every suite is represented, every
# signature compared word-for-word against the Spike reference riscof
# recorded.  Tests must fit the 16K TCMs; the big ones (jal's megabyte
# spans) are covered at RTL by `make riscof` and cannot be gate tests.
GATE_ARCH_TESTS := I/add-01 I/sub-01 I/xor-01 I/sltu-01 I/jalr-01 \
                   I/lw-align-01 I/sw-align-01 M/mul-01 M/div-01 \
                   privilege/misalign-lh-01 privilege/ebreak Zifencei/Fencei

gate-arch: $(BUILD)/gate/tb_sdf_subsys.vvp $(BUILD)/gate/cdriscv_32s_20_subsys_pd_sim.sdf
	scripts/gate_arch_subset.sh $(GATE_ARCH_TESTS) \
	  | tee $(BUILD)/gate/gate_arch.log

gate-sdf: $(BUILD)/gate/tb_sdf_subsys.vvp $(BUILD)/gate/cdriscv_32s_20_subsys_pd_sim.sdf sw
	$(VVP) $(BUILD)/gate/tb_sdf_subsys.vvp \
	  +ITCM_HEX=$(BUILD)/prog.itcm.hex \
	  +DTCM_HEX=$(BUILD)/prog.dtcm.hex \
	  +SDF=$(BUILD)/gate/cdriscv_32s_20_subsys_pd_sim.sdf \
	  | tee $(BUILD)/gate/sdf_smoke.log
	@grep -q "PASS" $(BUILD)/gate/sdf_smoke.log

riscof: $(BUILD)/tb_cosim_arch.vvp
	@test -d $(RISCOF_SUITE) || { \
	  echo "riscv-arch-test not present: see verif/riscof/README.md"; \
	  exit 1; }
	cd verif/riscof && riscof testlist --config=config.ini \
	  --suite=riscv-arch-test/riscv-test-suite/ \
	  --env=riscv-arch-test/riscv-test-suite/env
	# Drop the pmp group.  Those tests gate on "verify (PMP['implemented'])",
	# and riscof only evaluates "check" clauses when selecting tests, so all 42
	# are selected on any RV32 I+Zicsr core.  This core implements no PMP and
	# has no U mode.  See verif/riscof/upstream-issues.md.
	cd verif/riscof && python3 -c "import yaml,sys; \
	  d=yaml.safe_load(open('riscof_work/test_list.yaml')); \
	  k=[t for t in d if '/pmp/' in d[t]['test_path']]; \
	  [d.pop(t) for t in k]; \
	  yaml.safe_dump(d, open('riscof_work/test_list_filtered.yaml','w')); \
	  sys.stderr.write('riscof: dropped %d pmp tests, running %d\\n' % (len(k), len(d)))"
	cd verif/riscof && riscof run --config=config.ini \
	  --suite=riscv-arch-test/riscv-test-suite/ \
	  --env=riscv-arch-test/riscv-test-suite/env --no-browser \
	  --testfile=riscof_work/test_list_filtered.yaml

# ------------------------------------------------- static timing (O8)
# OpenSTA against the same SG13G2 library the netlist is mapped to.
#
# The STA netlist is built separately from the simulation one for two
# reasons, both of them about what OpenSTA's structural Verilog reader
# will accept: `opt_clean -purge` removes the flattened hierarchical
# debug wires it cannot parse, and boot_addr_i is tied to a constant so
# that every flop maps to a library cell.  See V18 in
# verification_findings.md for why that tie is needed and what it means.
$(BUILD)/gate/cdriscv_32s_20_subsys_sta.v: $(RTL) verif/gate/cdriscv_32s_20_tcm_bb.sv | $(BUILD)/gate
	$(YOSYS) -p "plugin -i slang; \
	  read_slang --top $(TOP) verif/gate/cdriscv_32s_20_tcm_bb.sv $(GATE_RTL); \
	  connect -set boot_addr_i 32'h00000000; \
	  synth -top $(TOP) -flatten; \
	  dfflibmap -liberty $(GATE_LIB); \
	  abc -liberty $(GATE_LIB); \
	  opt_clean -purge; \
	  write_verilog -noattr $@" -l $(BUILD)/gate/subsys_sta_synth.log
	@grep -E "cells to .sg13g2_dfrbpq" $(BUILD)/gate/subsys_sta_synth.log
	@if grep -q "^  reg " $@; then \
	  echo "STA netlist still has behavioural registers -- not fully mapped"; \
	  exit 1; fi

$(BUILD)/gate/cdriscv_32s_20_subsys_sta_fix.v: $(BUILD)/gate/cdriscv_32s_20_subsys_sta.v
	$(PYTHON) scripts/sta_netlist_fixup.py $< $@


# ------------------------------------------------- placed timing (V38)
# Same RTL, but the TCM storage is mapped to four real IHP SRAM macros
# (verif/gate/cdriscv_32s_20_tcm_macro.sv) so the ECC logic and the array
# access are both in the timing picture, then OpenROAD floorplans,
# places and buffers the netlist before asking for slack.  `make sta`
# stays as the quick unbuffered check; this is the number to quote.
SRAM_PDK  ?= $(dir $(patsubst %/,%,$(GATE_PDK)))sg13g2_sram
OPENROAD  ?= /foss/tools/openroad/bin/openroad

$(BUILD)/gate/cdriscv_32s_20_subsys_pd.v: $(RTL) verif/gate/cdriscv_32s_20_tcm_macro.sv | $(BUILD)/gate
	$(YOSYS) -p "plugin -i slang; \
	  read_slang --top $(TOP) verif/gate/cdriscv_32s_20_tcm_macro.sv $(GATE_RTL); \
	  connect -set boot_addr_i 32'h00000000; \
	  synth -top $(TOP) -flatten; \
	  dfflibmap -liberty $(GATE_LIB); \
	  abc -liberty $(GATE_LIB); \
	  opt_clean -purge; \
	  write_verilog -noattr $@" -l $(BUILD)/gate/subsys_pd_synth.log

fmax: $(BUILD)/gate/cdriscv_32s_20_subsys_pd.v verif/sta/openroad_fmax.tcl
	GATE_PDK=$(GATE_PDK) SRAM_PDK=$(SRAM_PDK) GATE_NETLIST=$< \
	  $(OPENROAD) -no_init -exit verif/sta/openroad_fmax.tcl \
	  2>&1 | tee $(BUILD)/gate/fmax.log | tail -40

sta: $(BUILD)/gate/cdriscv_32s_20_subsys_sta_fix.v verif/sta/cdriscv_32s_20_subsys.sdc
	GATE_LIB=$(GATE_LIB) GATE_NETLIST=$< \
	  sta -no_splash -exit verif/sta/run_sta.tcl 2>&1 \
	  | grep -v "^Warning 198" | tee $(BUILD)/gate/sta.log
	@echo ""
	@$(PYTHON) scripts/sta_path_split.py $(BUILD)/gate/sta.log \
	  | tee -a $(BUILD)/gate/sta.log

# ------------------------------------------------- fault injection
FI_RUNS ?= 300
FI_SEED ?= 7

$(BUILD)/fi_workload%.elf: verif/fi/fi_workload%.S tb/sw/link.ld | $(BUILD)
	$(CC) -march=$(ARCH) -mabi=$(ABI) -nostdlib -nostartfiles \
	  -T tb/sw/link.ld -o $@ $<

$(BUILD)/fi_workload.elf: verif/fi/fi_workload.S tb/sw/link.ld | $(BUILD)
	$(CC) -march=$(ARCH) -mabi=$(ABI) -nostdlib -nostartfiles \
	  -T tb/sw/link.ld -o $@ verif/fi/fi_workload.S

$(BUILD)/fi_workload%.bin: $(BUILD)/fi_workload%.elf
	$(OBJCOPY) -O binary --only-section=.text $< $@

$(BUILD)/fi_workload.bin: $(BUILD)/fi_workload.elf
	$(OBJCOPY) -O binary --only-section=.text $< $@

$(BUILD)/tb_fi.vvp: $(RTL) verif/fi/tb_fi.sv | $(BUILD)
	$(IVERILOG) -g2012 -o $@ -s tb_fi $(RTL) verif/fi/tb_fi.sv

# Single event upsets across a named fault list, classified into
# detected / silent-ok / silent data corruption / hang.  The SDC count
# is the one that matters: a fault that changes the result and reports
# nothing is what a safety mechanism exists to prevent.
# fi-check (workload D) was missing from this list and silently never
# re-ran on the new RTL while the FMEDA claimed it had (2026-09-04).
fi: fi-arith fi-trap fi-mem fi-check fi-e2e fi-clint fi-pmp fi-zcmp fi-dbg

# --golden-cfg is the safety configuration signature from a fault-free
# run.  Without it a fault that switches a detector off is reported as
# silent-ok, which is the most misleading label available.  All goldens
# below were re-measured on THIS variant's RTL (the compressed-code
# layout moved every address, and the CLINT owns MTIP now); the
# signature has grown a fourth word, the PMP array fold.
fi-arith: $(BUILD)/tb_fi.vvp $(BUILD)/fi_workload.hex $(BUILD)/dtcm_zero.hex
	$(PYTHON) scripts/fi_campaign.py --runs $(FI_RUNS) --seed $(FI_SEED) \
	  --golden-cfg 00000001_ffffffff_ff0000d0_00000000 \
	  | tee $(BUILD)/fi_campaign.txt

# Workload B exists because workload A reported mepc and mstatus.MIE as
# never detected, which said nothing about the design: A takes no traps
# and enables no interrupts, so those bits are dead state for the whole
# run.  B traps every iteration and runs the machine timer, which makes
# them live.  IBASE/ISPAN are B's own live code window.
fi-trap: $(BUILD)/tb_fi.vvp $(BUILD)/fi_workload_trap.hex $(BUILD)/dtcm_zero.hex
	$(PYTHON) scripts/fi_campaign.py --runs $(FI_RUNS) --seed $(FI_SEED) \
	  --hex $(BUILD)/fi_workload_trap.hex --golden 7ed54dd1 \
	  --golden-cfg 00000001_ffffffff_ff000104_00000000 \
	  --ibase 57 --ispan 53 --min-cycle 200 --max-cycle 4500 \
	  --name "B: traps and interrupts (CLINT MTIP)" \
	  | tee $(BUILD)/fi_campaign_trap.txt

# Workload C is almost nothing but loads and stores, at every width and
# alignment.  It exists to settle one row: the LSU address offset was
# detected once in thirty two on both A and B, and those two bits are
# live only while an access is in flight.  Raise the exposure and see
# whether detection follows -- that is what separates narrow exposure
# from a real gap.
fi-mem: $(BUILD)/tb_fi.vvp $(BUILD)/fi_workload_mem.hex $(BUILD)/dtcm_zero.hex
	$(PYTHON) scripts/fi_campaign.py --runs $(FI_RUNS) --seed $(FI_SEED) \
	  --hex $(BUILD)/fi_workload_mem.hex --golden 02576cb6 \
	  --golden-cfg 00000001_ffffffff_ff0000dc_00000000 \
	  --ibase 43 --ispan 31 --min-cycle 150 --max-cycle 2300 \
	  --name "C: dense sub-word memory traffic" \
	  | tee $(BUILD)/fi_campaign_mem.txt

# ---- variant 2 mechanisms: inject where detection is claimed --------
# Systematic sweeps, not random draws: every wire bit of the E2E links
# at least once, every PMP array bit, every CLINT counter bit.  The
# sweep spec is printed into each report so the coverage claim carries
# its own fault list.

# E2E: transients on the wires BETWEEN the link endpoints, during live
# beats (the bench holds each force for exactly one clock).  Workload C
# because it has the densest data traffic at every width.  Target 38 is
# the byte-enable wires -- the former gap in the fold, which measured
# as ALL 10 SDCs of this sweep and was closed on 2026-09-02 by folding
# be into the check ({data, addr, be}); the acceptance criterion is now
# ZERO SDC, with the be injections in the detected column.  The I-TCM
# write link is not separately swept: no workload writes code, and the
# slave-side endpoint is the same module proven by block-e2e-link.
fi-e2e: $(BUILD)/tb_fi.vvp $(BUILD)/fi_workload_mem.hex $(BUILD)/dtcm_zero.hex
	$(PYTHON) scripts/fi_campaign.py --seed $(FI_SEED) \
	  --hex $(BUILD)/fi_workload_mem.hex --golden 02576cb6 \
	  --golden-cfg 00000001_ffffffff_ff0000dc_00000000 \
	  --sweep 34:72:2,35:32:2,36:40:2,37:40:2,38:4:8 \
	  --ibase 43 --ispan 31 --min-cycle 150 --max-cycle 2300 \
	  --name "E2E links: every wire bit, live traffic (workload C)" \
	  | tee $(BUILD)/fi_campaign_e2e.txt

# CLINT: mtimecmp/msip/prescaler are inside the CLINT's own cfg-parity
# fold and must report as configuration parity; mtime is hardware-
# updated, correctly outside the fold, and its upsets are UNDETECTED BY
# DESIGN -- the row exists to measure that honestly, and the watchdog
# argument for bounding it lives in the FMEDA notes.  Workload B is the
# one that keeps the machine timer live.
fi-clint: $(BUILD)/tb_fi.vvp $(BUILD)/fi_workload_trap.hex $(BUILD)/dtcm_zero.hex
	$(PYTHON) scripts/fi_campaign.py --seed $(FI_SEED) \
	  --hex $(BUILD)/fi_workload_trap.hex --golden 7ed54dd1 \
	  --golden-cfg 00000001_ffffffff_ff000104_00000000 \
	  --sweep 27:64:3,28:64:3,29:17:3 \
	  --ibase 57 --ispan 53 --min-cycle 200 --max-cycle 4500 \
	  --name "CLINT: mtime / mtimecmp / msip+prescaler (workload B)" \
	  | tee $(BUILD)/fi_campaign_clint.txt

# PMP: the protection arrays carry configuration parity since
# 2026-09-02 (u_pmp_par in the CSR file), added because this campaign
# measured 90.8 % of PMP-array SEUs as latent when the guard folded
# mtvec only.  The deposits land in the MAIN core only; every flip --
# exercised region or not -- must now report as FLT_CFG_PAR within
# cycles, with lockstep still backstopping anything that reaches an
# access decision.  The cfg signature's PMP fold stays as the bench's
# independent check on the mechanism.  Workload E keeps a locked
# deny-all region live by probing it every iteration.
fi-pmp: $(BUILD)/tb_fi.vvp $(BUILD)/fi_workload_pmp.hex $(BUILD)/dtcm_zero.hex
	$(PYTHON) scripts/fi_campaign.py --seed $(FI_SEED) \
	  --hex $(BUILD)/fi_workload_pmp.hex --golden bff14962 \
	  --golden-cfg 00000101_ffffffff_ff0000e4_04000370 \
	  --sweep 30:64:3,31:256:1 \
	  --ibase 36 --ispan 36 --min-cycle 250 --max-cycle 2800 \
	  --name "E: PMP arrays under live denials (workload E)" \
	  | tee $(BUILD)/fi_campaign_pmp.txt

# Zcmp: the sequencer's step counter and the held encoding, flipped
# MID-SEQUENCE in the main core (the bench defers each deposit to the
# first cycle ST_SEQ is active; a window that never meets one reports
# not-injected).  Lockstep is the mechanism under test.
fi-zcmp: $(BUILD)/tb_fi.vvp $(BUILD)/fi_workload_zcmp.hex $(BUILD)/dtcm_zero.hex
	$(PYTHON) scripts/fi_campaign.py --seed $(FI_SEED) \
	  --hex $(BUILD)/fi_workload_zcmp.hex --golden 081c5530 \
	  --golden-cfg 00000001_ffffffff_ff0000f4_00000000 \
	  --sweep 32:5:24,33:64:2 \
	  --ibase 24 --ispan 44 --min-cycle 200 --max-cycle 5400 \
	  --name "F: Zcmp sequences, mid-sequence upsets (workload F)" \
	  | tee $(BUILD)/fi_campaign_zcmp.txt

# JTAG/debug: the observation window is read-only by construction --
# nothing in dbg_bridge/dbg_win can reach the core, the bus or the
# memories, and the TAP itself is held in reset while trst_ni is low
# (the in-mission state).  This small sweep backs that structural
# argument with a measurement; the expected result is 100 % silent-ok.
fi-dbg: $(BUILD)/tb_fi.vvp $(BUILD)/fi_workload.hex $(BUILD)/dtcm_zero.hex
	$(PYTHON) scripts/fi_campaign.py --seed $(FI_SEED) \
	  --golden-cfg 00000001_ffffffff_ff0000d0_00000000 \
	  --sweep 39:8:8 \
	  --min-cycle 200 --max-cycle 2400 \
	  --name "JTAG/debug observation state (workload A)" \
	  | tee $(BUILD)/fi_campaign_dbg.txt

# --------------------------------------------------------------- formal
# Bounded model check of the fetch stage.  Depth is a variable because
# the cost climbs steeply: the properties reason over 32-bit PCs, and
# the solver time per step grows with depth.  FORMAL_DEPTH=20 is the
# routine setting; a deeper run is worth doing before any release.
FORMAL_DEPTH ?= 20
SBY          ?= sby

formal: formal-if formal-ecc formal-bus formal-dec formal-lsu formal-safety

formal-if: | $(BUILD)
	$(SBY) -f -d $(BUILD)/fv_if verif/formal/if_stage.sby bmc \
	  | tee $(BUILD)/formal_if.log
	@grep -q "DONE (PASS" $(BUILD)/formal_if.log

formal-ecc: | $(BUILD)
	$(SBY) -f -d $(BUILD)/fv_ecc verif/formal/ecc.sby bmc \
	  | tee $(BUILD)/formal_ecc.log
	@grep -q "DONE (PASS" $(BUILD)/formal_ecc.log

# The interconnect's risk is bookkeeping, not arithmetic: a misrouted
# response hands one master another's data, which looks plausible and
# is wrong.  Read through yosys-slang, because the built-in frontend
# cannot parse the address decode function.
formal-bus: | $(BUILD)
	$(SBY) -f -d $(BUILD)/fv_bus verif/formal/bus.sby bmc \
	  | tee $(BUILD)/formal_bus.log
	@grep -q "DONE (PASS" $(BUILD)/formal_bus.log

# The decoder is combinational, so this quantifies over every one of the
# 2^32 instruction encodings: an instruction the decoder rejects must
# have no architectural effect at all -- no register write, no memory
# access, no control transfer, no CSR access, no system side effect.
formal-dec: | $(BUILD)
	$(SBY) -f -d $(BUILD)/fv_dec verif/formal/decoder.sby bmc \
	  | tee $(BUILD)/formal_dec.log
	@grep -q "DONE (PASS" $(BUILD)/formal_dec.log

# The LSU drives its bus outputs combinationally from the core's
# request, so the core owes it stability.  That obligation is an
# assumption in the wrapper, stated rather than implied.
formal-lsu: | $(BUILD)
	$(SBY) -f -d $(BUILD)/fv_lsu verif/formal/lsu.sby bmc \
	  | tee $(BUILD)/formal_lsu.log
	@grep -q "DONE (PASS" $(BUILD)/formal_lsu.log

# A latched fault does not go away by itself, and a locked
# configuration stays locked.  Both are claims the safety manual makes;
# this is where they are checked.
formal-safety: | $(BUILD)
	$(SBY) -f -d $(BUILD)/fv_safety verif/formal/safety.sby bmc \
	  | tee $(BUILD)/formal_safety.log
	@grep -q "DONE (PASS" $(BUILD)/formal_safety.log

# ---------------------------------------------------------------- ecc
ecc:
	$(PYTHON) scripts/gen_secded.py

# --------------------------------------------------------------- synth
# Structural check, not a real hardening run: the TCMs are cut down to
# SYNTH_TCM_WORDS because the behavioural arrays would otherwise map to
# a few hundred thousand flip-flops and dominate everything.  What this
# target is for is objective O5 -- no inferred latches, no combinational
# loops -- plus a logic area figure to track.
SYNTH_TCM_WORDS ?= 64

# yosys-slang rather than the built-in Verilog frontend: the latter
# does not accept a package import in the module header.  slang is also
# the strictest of the three front-ends this project uses, so it is a
# useful third opinion after Verilator and Icarus.
synth: | $(BUILD)
	$(YOSYS) -p "plugin -i slang; \
	             read_slang --top $(TOP) \
	               -G ItcmWords=$(SYNTH_TCM_WORDS) \
	               -G DtcmWords=$(SYNTH_TCM_WORDS) \
	               $(RTL); \
	             synth -top $(TOP); \
	             stat" -l $(BUILD)/synth.log
	@echo "--- structural checks (objective O5) ---"
	@if grep -qiE "inferring latch|combinational loop|found logic loop" $(BUILD)/synth.log; then \
	  grep -iE "inferring latch|combinational loop|found logic loop" $(BUILD)/synth.log; \
	  echo "FAIL: latch or loop inferred"; exit 1; fi
	@if grep -qE '\$$_DLATCH_' $(BUILD)/synth.log; then \
	  echo "FAIL: latch cells in the mapped netlist"; exit 1; fi
	@echo "no latches, no combinational loops"
	@grep -E "^ +[0-9]+ (wires|cells)$$" $(BUILD)/synth.log | tail -2
	@grep -cE '\$$_(DFF|ALDFF)' $(BUILD)/synth.log | \
	  xargs -I{} echo "flip-flop cell types: {}"

$(BUILD):
	mkdir -p $(BUILD)

clean:
	rm -rf $(BUILD) obj_dir *.vcd

# TCM equivalence: the behavioural 39-bit array against the split-macro
# mapping (2x 2048x32 data + 1x 4096x8 check bits) driven from identical
# stimulus.  LVS compares the layout against the netlist that produced
# it and so cannot see a consistently mis-wired parity macro; this can.
# Validated by mutation -- rotating, dropping or misaligning a parity
# bit, or swapping the data banks, each produces thousands of
# mismatches (V49).
TCM_SRAM_V = $(SRAM_PDK)/verilog
$(BUILD)/tb_tcm_equiv.vvp: rtl/core/cdriscv_32s_20_pkg.sv rtl/safety/cdriscv_32s_20_ecc_secded.sv \
        rtl/bus/cdriscv_32s_20_tcm.sv verif/block/tcm/cdriscv_32s_20_tcm_mac.sv \
        $(TCM_SRAM_V)/RM_IHPSG13_1P_core_behavioral_bm_bist.v \
        $(TCM_SRAM_V)/RM_IHPSG13_1P_2048x32_c2_bm_bist.v \
        $(TCM_SRAM_V)/RM_IHPSG13_1P_4096x8_c3_bm_bist.v \
        verif/block/tcm/tb_tcm_equiv.sv | $(BUILD)
	$(IVERILOG) -g2012 -o $@ -s tb_tcm_equiv $^

block-tcm: $(BUILD)/tb_tcm_equiv.vvp
	$(VVP) $(BUILD)/tb_tcm_equiv.vvp | tee $(BUILD)/block_tcm.log
	@grep -q "PASS" $(BUILD)/block_tcm.log


# IF-stage equivalence: the original read-pointer against the replicated
# one (V50).  yosys equiv_induct cannot prove this -- replication changes
# the state encoding, so equiv_make has no counterpart to pair the new
# flops against -- so the design is checked by simulation instead, and
# the bench is mutation-validated.
$(BUILD)/tb_if_equiv.vvp: rtl/core/cdriscv_32s_20_pkg.sv verif/block/if_stage/cdriscv_32s_20_if_stage_gold.sv \
        rtl/core/cdriscv_32s_20_if_stage.sv verif/block/if_stage/tb_if_equiv.sv | $(BUILD)
	$(IVERILOG) -g2012 -o $@ -s tb_if_equiv $^

block-if-equiv: $(BUILD)/tb_if_equiv.vvp
	$(VVP) $(BUILD)/tb_if_equiv.vvp | tee $(BUILD)/block_if_equiv.log
	@grep -q "PASS" $(BUILD)/block_if_equiv.log
