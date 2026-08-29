// cdriscv-32s-20 file list (Verilator / iverilog / yosys read order)
// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
rtl/core/cdriscv_32s_20_pkg.sv
rtl/common/cdriscv_32s_20_sync.sv
rtl/common/cdriscv_32s_20_cfg_parity.sv
rtl/common/cdriscv_32s_20_counter64.sv
rtl/core/cdriscv_32s_20_alu.sv
rtl/core/cdriscv_32s_20_decoder.sv
rtl/core/cdriscv_32s_20_regfile.sv
rtl/core/cdriscv_32s_20_multdiv.sv
rtl/core/cdriscv_32s_20_lsu.sv
rtl/core/cdriscv_32s_20_pmp.sv
rtl/core/cdriscv_32s_20_csr.sv
rtl/core/cdriscv_32s_20_if_stage.sv
rtl/core/cdriscv_32s_20_core.sv
rtl/safety/cdriscv_32s_20_ecc_secded.sv
rtl/safety/cdriscv_32s_20_lockstep.sv
rtl/safety/cdriscv_32s_20_safety_ctrl.sv
rtl/safety/cdriscv_32s_20_wdog.sv
rtl/safety/cdriscv_32s_20_clkmon.sv
rtl/safety/cdriscv_32s_20_mbist.sv
rtl/bus/cdriscv_32s_20_tcm.sv
rtl/bus/cdriscv_32s_20_bus.sv
rtl/bus/cdriscv_32s_20_apb_bridge.sv
rtl/periph/cdriscv_32s_20_timer.sv
rtl/periph/cdriscv_32s_20_irq_ctrl.sv
rtl/periph/cdriscv_32s_20_ams_if.sv
rtl/cdriscv_32s_20_subsys.sv

// ---------------------------------------------------------------------
// Written and block-verified, NOT yet instantiated by the subsystem.
// They are listed here so lint, elaboration and synthesis cover them;
// see doc/variant_status.md for what each still needs.
// ---------------------------------------------------------------------
rtl/core/cdriscv_32s_20_mult.sv
rtl/core/cdriscv_32s_20_decompress.sv
rtl/core/cdriscv_32s_20_if_align.sv
rtl/periph/cdriscv_32s_20_clint.sv
rtl/safety/cdriscv_32s_20_e2e.sv
rtl/debug/cdriscv_32s_20_jtag_tap.sv
