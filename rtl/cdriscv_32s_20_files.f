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
rtl/safety/cdriscv_32s_20_e2e.sv
rtl/safety/cdriscv_32s_20_e2e_link.sv
rtl/bus/cdriscv_32s_20_tcm.sv
rtl/bus/cdriscv_32s_20_bus.sv
rtl/bus/cdriscv_32s_20_apb_bridge.sv
rtl/periph/cdriscv_32s_20_timer.sv
rtl/periph/cdriscv_32s_20_irq_ctrl.sv
rtl/periph/cdriscv_32s_20_ams_if.sv
rtl/cdriscv_32s_20_subsys.sv

// ---------------------------------------------------------------------
// Modules added by this variant (all instantiated by the subsystem
// since the E2E links went in -- see doc/variant_status.md section 1
// for what each one is).
// ---------------------------------------------------------------------
rtl/core/cdriscv_32s_20_mult.sv
rtl/core/cdriscv_32s_20_decompress.sv
rtl/core/cdriscv_32s_20_zcmp.sv
rtl/core/cdriscv_32s_20_if_align.sv
rtl/periph/cdriscv_32s_20_clint.sv
rtl/periph/cdriscv_32s_20_clint_obi.sv
rtl/debug/cdriscv_32s_20_jtag_tap.sv
rtl/debug/cdriscv_32s_20_dbg_bridge.sv
rtl/debug/cdriscv_32s_20_dbg_win.sv
rtl/boot/cdriscv_32s_20_qspi_boot.sv
