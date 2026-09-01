// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// Functional coverage model (objective O7).
//
// Line and toggle coverage say which of the RTL ran.  They cannot say
// which *situations* were reached, and that is the question a
// verification plan is actually asking.  A design can be at 100 % line
// coverage having never taken an interrupt, never seen a bus error and
// never run a division by zero.
//
// The points below are the situations this plan claims to cover.  They
// are `cover` statements rather than covergroups because Verilator
// implements those and merges them into the same report as line and
// toggle coverage, so one flow measures all three.
//
// Everything is attached with `bind`, which is what makes the internal
// signals reachable: a bind port expression is elaborated in the scope
// of the target module, so `retire` and `trap_cause` can be sampled
// without adding a single port to the RTL.
//
// A point that stays at zero is a hole in the tests, not a defect.  The
// report in verification_findings.md lists which ones are which.

`default_nettype none

// ----------------------------------------------------------------- core
module cdriscv_32s_20_core_cover (
    input logic       clk, rst_n,
    input logic       retire, instr_exec,
    input logic       branch_dec, jump_dec, jalr_dec,
    input logic       lsu_req_dec, lsu_we, lsu_sign_ext,
    input logic [1:0] lsu_size,
    input logic       md_req_dec,
    input logic       csr_access_dec,
    input logic       ecall, ebreak, mret, wfi, fence, fencei,
    input logic       illegal_instr_dec,
    input logic       trap_taken, take_irq, take_exc,
    input logic [4:0] trap_cause,
    input logic       ctrl_transfer,
    // compressed / Zcmp (added 2026-09-01: the model predated the C
    // extension and the ST_SEQ sequencer)
    input logic        instr_compressed, instr_zcmp,
    input logic [31:0] instr_raw,
    input logic        seq_issue,
    // PMP (added 2026-09-01: the model predated the checker).  The
    // match/perm/lock vectors come from inside the two checker
    // instances -- a bind port expression elaborates in the core's
    // scope, so it may reach into them hierarchically.
    input logic        pmp_allow_data,
    input logic        instr_req,
    input logic [7:0]  d_match, d_perm, d_lock,
    input logic [7:0]  f_match, f_perm, f_lock
);
  // Zcmp op class, decoded from the raw halfword with the same field
  // tests as cdriscv_32s_20_zcmp.  Only meaningful under instr_zcmp.
  logic cm_is_mv, cm_is_push, cm_is_pop, cm_is_popret, cm_is_popretz;
  assign cm_is_mv      = (instr_raw[15:10] == 6'b101011) && instr_raw[5];
  assign cm_is_push    = !cm_is_mv && (instr_raw[10:9] == 2'b00);
  assign cm_is_pop     = !cm_is_mv && (instr_raw[10:9] == 2'b01);
  assign cm_is_popretz = !cm_is_mv && (instr_raw[10:9] == 2'b10);
  assign cm_is_popret  = !cm_is_mv && (instr_raw[10:9] == 2'b11);

  // First match wins, replicated from the checker.  If this replica
  // ever drifts from the RTL the points below stop hitting -- a false
  // MISS, never a false hit, which is the safe direction for a monitor.
  function automatic logic [3:0] pmp_win(input logic [7:0] m);
    pmp_win = 4'd8;
    for (int i = 7; i >= 0; i--) if (m[i]) pmp_win = 4'(i);
  endfunction

  logic [3:0] dw, fw;
  assign dw = pmp_win(d_match);
  assign fw = pmp_win(f_match);

  // a data access consulting the data checker this cycle: a load/store
  // issuing from decode, or one memory beat of a Zcmp sequence
  logic d_check;
  assign d_check = (instr_exec && lsu_req_dec) || seq_issue;

  always @(posedge clk) if (rst_n) begin
    // instruction classes actually retired
    cp_retire_branch:   cover (retire && branch_dec);
    cp_branch_taken:    cover (retire && branch_dec &&  ctrl_transfer);
    cp_branch_nottaken: cover (retire && branch_dec && !ctrl_transfer);
    cp_jal:             cover (retire && jump_dec && !jalr_dec);
    cp_jalr:            cover (retire && jalr_dec);
    cp_load:            cover (retire && lsu_req_dec && !lsu_we);
    cp_store:           cover (retire && lsu_req_dec &&  lsu_we);
    cp_muldiv:          cover (retire && md_req_dec);
    cp_csr:             cover (retire && csr_access_dec);

    // load and store at every width, and sign extension on the narrow ones
    cp_lsu_byte:        cover (retire && lsu_req_dec && lsu_size == 2'd0);
    cp_lsu_half:        cover (retire && lsu_req_dec && lsu_size == 2'd1);
    cp_lsu_word:        cover (retire && lsu_req_dec && lsu_size == 2'd2);
    cp_lsu_signed:      cover (retire && lsu_req_dec && !lsu_we && lsu_sign_ext);
    cp_lsu_unsigned:    cover (retire && lsu_req_dec && !lsu_we && !lsu_sign_ext);

    // the system instructions
    cp_ecall:           cover (instr_exec && ecall);
    cp_ebreak:          cover (instr_exec && ebreak);
    cp_mret:            cover (retire && mret);
    cp_wfi:             cover (retire && wfi);
    cp_fence:           cover (retire && fence);
    cp_fencei:          cover (retire && fencei);
    cp_illegal:         cover (instr_exec && illegal_instr_dec);

    // traps, by kind and by cause
    cp_trap:            cover (trap_taken);
    cp_trap_exc:        cover (take_exc);
    cp_trap_irq:        cover (take_irq);
    cp_cause_illegal:   cover (take_exc && trap_cause == 5'd2);
    cp_cause_break:     cover (take_exc && trap_cause == 5'd3);
    cp_cause_ld_fault:  cover (take_exc && trap_cause == 5'd5);
    cp_cause_st_fault:  cover (take_exc && trap_cause == 5'd7);
    cp_cause_ecall_m:   cover (take_exc && trap_cause == 5'd11);
    cp_irq_soft:        cover (take_irq && trap_cause == 5'd3);
    cp_irq_timer:       cover (take_irq && trap_cause == 5'd7);
    cp_irq_ext:         cover (take_irq && trap_cause == 5'd11);

    // compressed execution.  A 16-bit encoding retiring, and each Zcmp
    // op class retiring as ONE instruction (retire in ST_SEQ holds the
    // cm.* at the aligner output, so instr_zcmp/instr_raw are its own).
    cp_c_retire:        cover (retire && instr_compressed);
    cp_zcmp_push:       cover (retire && instr_zcmp && cm_is_push);
    cp_zcmp_pop:        cover (retire && instr_zcmp && cm_is_pop);
    cp_zcmp_popret:     cover (retire && instr_zcmp && cm_is_popret);
    cp_zcmp_popretz:    cover (retire && instr_zcmp && cm_is_popretz);
    cp_zcmp_mv:         cover (retire && instr_zcmp && cm_is_mv);
    // the longest sequence: rlist 15 = {ra, s0-s11}, 13 registers
    cp_zcmp_rlist_max:  cover (retire && instr_zcmp && !cm_is_mv
                               && instr_raw[7:4] == 4'd15);
    // an interrupt arriving with a cm.* as the NEXT retire: taken at
    // the boundary, before the sequence starts -- the deferral point
    cp_irq_zcmp_next:   cover (take_irq && instr_zcmp);

    // PMP.  A data denial trapping (from decode or from a sequence
    // beat), a fetch fault trapping (cause 1: a PMP-injected entry or a
    // fetch bus error -- the injection itself is cp_fetch_denied in the
    // fetch-stage model), and the two rule directions on the winning
    // region: an unlocked region does NOT bind machine mode, a locked
    // one does.
    cp_pmp_data_deny:    cover (take_exc && instr_exec && lsu_req_dec
                                && !pmp_allow_data);
    cp_pmp_seq_deny:     cover (seq_issue && !pmp_allow_data);
    cp_cause_if_fault:   cover (take_exc && trap_cause == 5'd1);
    cp_pmp_d_unlocked_mmode: cover (d_check && (dw != 4'd8)
                                    && !d_perm[dw[2:0]] && !d_lock[dw[2:0]]
                                    && pmp_allow_data);
    cp_pmp_d_locked_deny:    cover (d_check && (dw != 4'd8)
                                    && d_lock[dw[2:0]] && !pmp_allow_data);
    // fetch through a matching unlocked region: the request only issues
    // because M-mode passed through it (a denied word is never requested)
    cp_pmp_f_unlocked_mmode: cover (instr_req && (fw != 4'd8)
                                    && !f_perm[fw[2:0]] && !f_lock[fw[2:0]]);
  end
endmodule

bind cdriscv_32s_20_core cdriscv_32s_20_core_cover u_cover (
    .clk (clk_i), .rst_n (rst_ni),
    .retire (retire), .instr_exec (instr_exec),
    .branch_dec (branch_dec), .jump_dec (jump_dec), .jalr_dec (jalr_dec),
    .lsu_req_dec (lsu_req_dec), .lsu_we (lsu_we), .lsu_sign_ext (lsu_sign_ext),
    .lsu_size (lsu_size), .md_req_dec (md_req_dec),
    .csr_access_dec (csr_access_dec),
    .ecall (ecall), .ebreak (ebreak), .mret (mret), .wfi (wfi),
    .fence (fence), .fencei (fencei),
    .illegal_instr_dec (illegal_instr_dec),
    .trap_taken (trap_taken), .take_irq (take_irq), .take_exc (take_exc),
    .trap_cause (trap_cause), .ctrl_transfer (ctrl_transfer),
    .instr_compressed (instr_compressed), .instr_zcmp (instr_zcmp),
    .instr_raw (instr_raw), .seq_issue (seq_issue),
    .pmp_allow_data (pmp_allow_data), .instr_req (instr_req_o),
    .d_match (u_pmp_data.match), .d_perm (u_pmp_data.perm),
    .d_lock (u_pmp_data.lock),
    .f_match (u_pmp_fetch.match), .f_perm (u_pmp_fetch.perm),
    .f_lock (u_pmp_fetch.lock)
);

// ------------------------------------------------------------ fetch stage
module cdriscv_32s_20_if_cover (
    input logic       clk, rst_n,
    input logic [1:0] occupancy,
    input logic       outstanding_q, discard_q,
    input logic       redirect_i, instr_req_o, instr_gnt_i,
    input logic       fault_inject
);
  always @(posedge clk) if (rst_n) begin
    // the fetch buffer at each depth: the deepened prefetch (V2-P1) is
    // only doing its job if the full state is actually reached
    cp_occ_empty:       cover (occupancy == 2'd0);
    cp_occ_one:         cover (occupancy == 2'd1);
    cp_occ_two:         cover (occupancy == 2'd2);
    // a redirect arriving while a fetch is in flight -- the case that
    // withdrew waiver W1
    cp_redirect_inflight: cover (redirect_i && outstanding_q);
    cp_discard_pending:   cover (discard_q);
    // memory refusing a fetch
    cp_fetch_stalled:     cover (instr_req_o && !instr_gnt_i);
    // PMP refusing a fetch: the denied word never reaches the bus and
    // a faulted entry is injected instead
    cp_fetch_denied:      cover (fault_inject);
  end
endmodule

bind cdriscv_32s_20_if_stage cdriscv_32s_20_if_cover u_cover (
    .clk (clk_i), .rst_n (rst_ni),
    .occupancy (occupancy), .outstanding_q (outstanding_q),
    .discard_q (discard_q), .redirect_i (redirect_i),
    .instr_req_o (instr_req_o), .instr_gnt_i (instr_gnt_i),
    .fault_inject (fault_inject)
);

// ------------------------------------------------------------------ TCM
module cdriscv_32s_20_tcm_cover (
    input logic clk, rst_n,
    input logic ecc_cor_o, ecc_unc_o, err_o, req_i, gnt_o, we_i
);
  always @(posedge clk) if (rst_n) begin
    cp_ecc_corrected:   cover (ecc_cor_o);
    cp_ecc_uncorrected: cover (ecc_unc_o);
    cp_tcm_error:       cover (err_o);
    cp_tcm_backpressure: cover (req_i && !gnt_o);
    cp_tcm_write:       cover (req_i && gnt_o &&  we_i);
    cp_tcm_read:        cover (req_i && gnt_o && !we_i);
  end
endmodule

bind cdriscv_32s_20_tcm cdriscv_32s_20_tcm_cover u_cover (
    .clk (clk_i), .rst_n (rst_ni),
    .ecc_cor_o (ecc_cor_o), .ecc_unc_o (ecc_unc_o), .err_o (err_o),
    .req_i (req_i), .gnt_o (gnt_o), .we_i (we_i)
);

// ------------------------------------------------------- safety controller
module cdriscv_32s_20_safety_cover (
    input logic        clk, rst_n,
    input logic [31:0] status_q, fault_latched,
    input logic        irq_o, reset_req_o, err_pin_o
);
  always @(posedge clk) if (rst_n) begin
    // each fault source latching, one point per source, so a source
    // that no test ever provokes shows up as a hole rather than
    // hiding inside an "any fault" point
    cp_flt_lockstep:  cover (fault_latched[0]);
    cp_flt_itcm_cor:  cover (fault_latched[1]);
    cp_flt_itcm_unc:  cover (fault_latched[2]);
    cp_flt_dtcm_cor:  cover (fault_latched[3]);
    cp_flt_dtcm_unc:  cover (fault_latched[4]);
    cp_flt_rf_parity: cover (fault_latched[5]);
    cp_flt_wdog:      cover (fault_latched[6]);
    cp_flt_clkmon:    cover (fault_latched[7]);
    cp_flt_bus:       cover (fault_latched[8]);
    cp_flt_bist:      cover (fault_latched[9]);
    cp_flt_ams:       cover (fault_latched[10]);
    cp_flt_sw:        cover (fault_latched[11]);
    cp_flt_trap:      cover (fault_latched[12]);
    // the sources added since the model was first written (2026-09-01).
    // cfg parity latches through its own ungated path, so it is
    // sampled from STATUS rather than fault_latched.  FLT_E2E latching
    // is reached through the INJECT register (safety_test check 10);
    // the E2E *checker* detecting a real mismatch is not reachable in a
    // fault-free simulation and is evidenced by block-e2e-link and its
    // mutation run instead -- see verif/coverage_waivers.md W3.
    cp_flt_cfg_par:   cover (status_q[13]);
    cp_flt_e2e:       cover (fault_latched[14]);
    // and each configured reaction actually firing
    cp_react_irq:     cover (irq_o);
    cp_react_reset:   cover (reset_req_o);
    cp_react_pin:     cover (err_pin_o);
    cp_multi_fault:   cover ($countones(status_q) > 1);
  end
endmodule

bind cdriscv_32s_20_safety_ctrl cdriscv_32s_20_safety_cover u_cover (
    .clk (clk_i), .rst_n (rst_ni),
    .status_q (status_q), .fault_latched (fault_latched),
    .irq_o (irq_o), .reset_req_o (reset_req_o), .err_pin_o (err_pin_o)
);

// ----------------------------------------------------------- realigner
// (added 2026-09-01) The straddle is the whole difficulty of 16-bit
// fetch granularity: a 32-bit instruction whose halves live in two
// words, covered by two independent ECC code words.
module cdriscv_32s_20_ifal_cover (
    input logic clk, rst_n,
    input logic accept, emit_straddle, start_straddle, emit_compressed
);
  always @(posedge clk) if (rst_n) begin
    // an instruction straddling a word boundary actually retiring
    // (instr_ready_i is the core's retire, so accept is retirement)
    cp_straddle_retire: cover (accept && emit_straddle);
    cp_straddle_start:  cover (start_straddle);
    cp_c_accept:        cover (accept && emit_compressed);
  end
endmodule

bind cdriscv_32s_20_if_align cdriscv_32s_20_ifal_cover u_cover (
    .clk (clk_i), .rst_n (rst_ni),
    .accept (accept), .emit_straddle (emit_straddle),
    .start_straddle (start_straddle), .emit_compressed (emit_compressed)
);

// ---------------------------------------------------------------- CLINT
// (added 2026-09-01) The level semantics the spec forces, and the
// sub-word reject the adapter exists for.
module cdriscv_32s_20_clint_cover (
    input logic clk, rst_n,
    input logic irq_timer_o, irq_soft_o, req_i, we_i
);
  logic mtip_q;
  always @(posedge clk) begin
    if (!rst_n) mtip_q <= 1'b0;
    else        mtip_q <= irq_timer_o;
  end
  always @(posedge clk) if (rst_n) begin
    // MTIP rising: mtime reached mtimecmp while it was armed
    cp_mtip_rise:   cover (irq_timer_o && !mtip_q);
    cp_msip_high:   cover (irq_soft_o);
    cp_clint_write: cover (req_i &&  we_i);
    cp_clint_read:  cover (req_i && !we_i);
  end
endmodule

bind cdriscv_32s_20_clint cdriscv_32s_20_clint_cover u_cover (
    .clk (clk_i), .rst_n (rst_ni),
    .irq_timer_o (irq_timer_o), .irq_soft_o (irq_soft_o),
    .req_i (req_i), .we_i (we_i)
);

module cdriscv_32s_20_clint_obi_cover (
    input logic clk, rst_n,
    input logic req_i, subword, rvalid_o, err_o
);
  always @(posedge clk) if (rst_n) begin
    // a sub-word access rejected before it reaches the CLINT, and the
    // bus error response that rides back from it
    cp_clint_subword:  cover (req_i && subword);
    cp_clint_err_resp: cover (rvalid_o && err_o);
  end
endmodule

bind cdriscv_32s_20_clint_obi cdriscv_32s_20_clint_obi_cover u_cover (
    .clk (clk_i), .rst_n (rst_ni),
    .req_i (req_i), .subword (subword),
    .rvalid_o (rvalid_o), .err_o (err_o)
);

// ------------------------------------------------------------- watchdog
module cdriscv_32s_20_wdog_cover (
    input logic clk, rst_n,
    input logic sts_timeout_q, sts_badsvc_q, fault_o, reset_req_o
);
  always @(posedge clk) if (rst_n) begin
    cp_wdog_timeout:  cover (sts_timeout_q);
    cp_wdog_badsvc:   cover (sts_badsvc_q);
    cp_wdog_fault:    cover (fault_o);
    cp_wdog_reset:    cover (reset_req_o);
  end
endmodule

bind cdriscv_32s_20_wdog cdriscv_32s_20_wdog_cover u_cover (
    .clk (clk_i), .rst_n (rst_ni),
    .sts_timeout_q (sts_timeout_q), .sts_badsvc_q (sts_badsvc_q),
    .fault_o (fault_o), .reset_req_o (reset_req_o)
);

`default_nettype wire
