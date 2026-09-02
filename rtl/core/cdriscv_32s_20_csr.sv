// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s-20 -- machine-mode CSR file.
//
// Variant 1's CSR file plus the PMP registers and a halfword-aligned
// mepc.  As with the decoder, the property that matters is that the
// additions leave variant 1's behaviour alone, and tb_v2_csr checks
// that by running both files in lockstep on identical stimulus.
//
// Three deliberate differences from variant 1, and no others:
//
//   1. misa reports B and C as well as I and M.  Variant 2 implements
//      Zba/Zbb/Zbs and Zca/Zcb, and misa is how software asks.
//   2. mepc keeps bit 1.  With IALIGN = 16 a trap can be taken on an
//      instruction at a halfword address, so forcing mepc[1] to zero --
//      which variant 1 does, correctly, for IALIGN = 32 -- would return
//      from the trap to the wrong instruction.  Bit 0 is still forced
//      to zero.  Variant 1's waiver V0-A5 named mepc[1:0] as "the exact
//      bit that changes if Zca is added"; this is that change.
//   3. The PMP CSRs exist: pmpcfg0/1 and pmpaddr0..7 for eight regions.
//
// PMP WARL rules implemented here, which are the parts that are easy to
// get wrong and are what the bench aims at:
//
//   * a locked region (cfg.L) makes its cfg byte AND its pmpaddr
//     read-only until reset -- not just the cfg byte
//   * for a TOR region i, pmpaddr[i-1] is the *lower* bound, so locking
//     region i must also lock pmpaddr[i-1].  Missing this is a real
//     hole: the region stays locked while its base can still be moved.
//   * cfg bits [6:5] are reserved and read as zero
//   * the R=0, W=1 combination is reserved; a write requesting it is
//     ignored for that byte rather than stored
//
// pmpcfg2/3 are decoded but hold nothing: eight regions fill pmpcfg0
// and pmpcfg1 only.  They read as zero and ignore writes, which is what
// WARL permits and what software probing the region count expects.
//
// STATUS: block-verified (doc/variant_status.md, section 2) and
// instantiated by the subsystem.  No signoff gate is met in this
// repository -- see README.md.  NOT qualified for safety-critical use.

`default_nettype none

module cdriscv_32s_20_csr
  import cdriscv_32s_20_pkg::*;
#(
    parameter logic [31:0] HartId    = 32'h0000_0000,
    parameter logic [31:0] MVendorId = 32'h0000_0000,
    parameter logic [31:0] MArchId   = 32'h0000_0000,
    parameter logic [31:0] MImpId    = 32'h0000_0001
) (
    input  logic        clk_i,
    input  logic        rst_ni,

    input  logic        access_i,
    input  csr_op_e     op_i,
    input  logic [11:0] addr_i,
    input  logic [31:0] wdata_i,
    input  logic        rd_is_x0_i,
    input  logic        rs1_is_x0_i,
    output logic [31:0] rdata_o,
    output logic        illegal_o,
    input  logic        commit_i,

    input  logic        trap_i,
    input  logic        trap_is_irq_i,
    input  logic [4:0]  trap_cause_i,
    input  logic [31:0] trap_pc_i,
    input  logic [31:0] trap_val_i,
    input  logic        mret_i,

    input  logic        irq_soft_i,
    input  logic        irq_timer_i,
    input  logic        irq_ext_i,

    input  logic        evt_rf_par_err_i,
    input  logic        evt_illegal_i,
    input  logic        evt_bus_err_i,
    input  logic        evt_lockstep_i,

    input  logic        instr_retired_i,

    output logic [31:0] mtvec_o,
    output logic        cfg_err_o,
    output logic [31:0] mepc_o,
    output logic        irq_pending_o,
    output logic        irq_wake_o,
    output logic [4:0]  irq_cause_o,
    output logic        mstatus_mie_o,

    output logic        sw_fault_o,
    output logic        fault_out_en_o,

    // to cdriscv_32s_20_pmp
    output logic [7:0]  pmp_cfg_o  [PMP_REGIONS],
    output logic [31:0] pmp_addr_o [PMP_REGIONS]
);

  // ------------------------------------------------------------------
  // Registers
  // ------------------------------------------------------------------
  logic        mstatus_mie_q, mstatus_mpie_q;
  logic [31:0] mie_q;
  logic [31:0] mtvec_q;
  logic [31:0] mscratch_q;
  logic [31:0] mepc_q;
  logic        mcause_irq_q;
  logic [4:0]  mcause_code_q;
  logic [31:0] mtval_q;
  logic [63:0] mcycle_q;
  logic [63:0] minstret_q;
  logic [31:0] msafestat_q;
  logic [31:0] msafectrl_q;

  logic [7:0]  pmpcfg_q  [PMP_REGIONS];
  logic [31:0] pmpaddr_q [PMP_REGIONS];

  // ------------------------------------------------------------------
  // Interrupt pending / enable
  // ------------------------------------------------------------------
  logic [31:0] mip;

  always_comb begin
    mip                  = 32'b0;
    mip[IRQ_M_SOFT]      = irq_soft_i;
    mip[IRQ_M_TIMER]     = irq_timer_i;
    mip[IRQ_M_EXT]       = irq_ext_i;
  end

  logic [31:0] irq_active;
  assign irq_active = mip & mie_q;
  assign irq_wake_o = |irq_active;

  always_comb begin
    irq_pending_o = 1'b0;
    irq_cause_o   = IRQ_M_EXT;
    if (mstatus_mie_q) begin
      if (irq_active[IRQ_M_EXT]) begin
        irq_pending_o = 1'b1;
        irq_cause_o   = IRQ_M_EXT;
      end else if (irq_active[IRQ_M_SOFT]) begin
        irq_pending_o = 1'b1;
        irq_cause_o   = IRQ_M_SOFT;
      end else if (irq_active[IRQ_M_TIMER]) begin
        irq_pending_o = 1'b1;
        irq_cause_o   = IRQ_M_TIMER;
      end
    end
  end

  // ------------------------------------------------------------------
  // misa: MXL = 1, extensions I, M, B
  // ------------------------------------------------------------------
  // Bit 1 is B (Zba + Zbb + Zbs) and bit 8 is I, bit 12 is M.
  //
  // Bit 2 (C) is set: cdriscv_32s_20_if_align is in the fetch path, so
  // the core can deliver compressed instructions.
  //
  // It was set once before that was true, and the Spike co-simulation
  // caught it on its first run -- the model read 0x40001102 where the
  // RTL returned 0x40001106.  misa reports what is implemented, not what
  // is written, and the CSR bench asserts the two move together.
  localparam logic [31:0] MISA_VALUE = {2'b01, 4'b0, 26'h000_1106};

  // ------------------------------------------------------------------
  // PMP register read multiplexing
  // ------------------------------------------------------------------
  // pmpcfg0 packs regions 0..3, pmpcfg1 regions 4..7.  Bits [6:5] of
  // each byte are reserved and stored as zero, so the read is a plain
  // concatenation.
  logic [31:0] pmpcfg0_rd, pmpcfg1_rd;
  assign pmpcfg0_rd = {pmpcfg_q[3], pmpcfg_q[2], pmpcfg_q[1], pmpcfg_q[0]};
  assign pmpcfg1_rd = {pmpcfg_q[7], pmpcfg_q[6], pmpcfg_q[5], pmpcfg_q[4]};

  logic        is_pmpaddr;
  logic [2:0]  pmpaddr_idx;
  assign is_pmpaddr  = (addr_i[11:3] == CSR_PMPADDR0[11:3]);
  assign pmpaddr_idx = addr_i[2:0];

  // ------------------------------------------------------------------
  // Read
  // ------------------------------------------------------------------
  logic [31:0] mstatus_rd;
  assign mstatus_rd = {19'b0, 2'b11 /*MPP*/, 3'b0, mstatus_mpie_q, 3'b0, mstatus_mie_q, 3'b0};

  logic read_illegal;

  always_comb begin
    rdata_o      = 32'b0;
    read_illegal = 1'b0;
    if (is_pmpaddr) begin
      rdata_o = pmpaddr_q[pmpaddr_idx];
    end else begin
      unique case (addr_i)
        CSR_MSTATUS:   rdata_o = mstatus_rd;
        CSR_MISA:      rdata_o = MISA_VALUE;
        CSR_MIE:       rdata_o = mie_q;
        CSR_MTVEC:     rdata_o = mtvec_q;
        CSR_MSCRATCH:  rdata_o = mscratch_q;
        CSR_MEPC:      rdata_o = mepc_q;
        CSR_MCAUSE:    rdata_o = {mcause_irq_q, 26'b0, mcause_code_q};
        CSR_MTVAL:     rdata_o = mtval_q;
        CSR_MIP:       rdata_o = mip;
        CSR_MCYCLE,
        CSR_CYCLE:     rdata_o = mcycle_q[31:0];
        CSR_MCYCLEH,
        CSR_CYCLEH:    rdata_o = mcycle_q[63:32];
        CSR_MINSTRET,
        CSR_INSTRET:   rdata_o = minstret_q[31:0];
        CSR_MINSTRETH,
        CSR_INSTRETH:  rdata_o = minstret_q[63:32];
        CSR_MVENDORID: rdata_o = MVendorId;
        CSR_MARCHID:   rdata_o = MArchId;
        CSR_MIMPID:    rdata_o = MImpId;
        CSR_MHARTID:   rdata_o = HartId;
        CSR_MSAFESTAT: rdata_o = msafestat_q;
        CSR_MSAFECTRL: rdata_o = msafectrl_q;
        CSR_PMPCFG0:   rdata_o = pmpcfg0_rd;
        CSR_PMPCFG1:   rdata_o = pmpcfg1_rd;
        CSR_PMPCFG2,
        CSR_PMPCFG3:   rdata_o = 32'b0;    // no regions there
        default:       read_illegal = 1'b1;
      endcase
    end
  end

  // ------------------------------------------------------------------
  // Write value and legality
  // ------------------------------------------------------------------
  logic        csr_we;
  logic [31:0] csr_wdata;

  always_comb begin
    unique case (op_i)
      CSR_RW:  csr_wdata = wdata_i;
      CSR_RS:  csr_wdata = rdata_o |  wdata_i;
      CSR_RC:  csr_wdata = rdata_o & ~wdata_i;
      default: csr_wdata = rdata_o;
    endcase
  end

  logic write_requested;
  always_comb begin
    unique case (op_i)
      CSR_RW:       write_requested = 1'b1;
      CSR_RS,
      CSR_RC:       write_requested = ~rs1_is_x0_i;
      default:      write_requested = 1'b0;
    endcase
  end

  logic write_to_ro;
  assign write_to_ro = write_requested && (addr_i[11:10] == 2'b11);

  assign illegal_o = access_i && (read_illegal || write_to_ro);
  assign csr_we    = access_i && commit_i && write_requested && !illegal_o;

  logic unused_rd_is_x0;
  assign unused_rd_is_x0 = rd_is_x0_i;

  // ------------------------------------------------------------------
  // PMP write helpers
  // ------------------------------------------------------------------
  // A pmpaddr is writable unless its own region is locked, or the next
  // region is locked and uses TOR -- in which case this address is that
  // region's lower bound and locking it must lock the bound too.
  function automatic logic pmpaddr_writable(input int unsigned idx);
    logic locked_self, locked_by_tor;
    begin
      locked_self   = pmpcfg_q[idx][7];
      locked_by_tor = 1'b0;
      if (idx + 1 < PMP_REGIONS)
        locked_by_tor = pmpcfg_q[idx+1][7] &&
                        (pmpcfg_q[idx+1][4:3] == PMP_TOR);
      pmpaddr_writable = !locked_self && !locked_by_tor;
    end
  endfunction

  // A cfg byte is stored with reserved bits cleared; the reserved
  // R=0/W=1 combination is refused and leaves the byte unchanged.
  function automatic logic [7:0] pmpcfg_next(input logic [7:0] cur,
                                             input logic [7:0] req);
    begin
      if (cur[7])                          pmpcfg_next = cur;  // locked
      else if (!req[0] && req[1])          pmpcfg_next = cur;  // R=0,W=1
      else                                 pmpcfg_next = {req[7], 2'b00, req[4:0]};
    end
  endfunction

  // ------------------------------------------------------------------
  // Update
  // ------------------------------------------------------------------
  logic [31:0] safety_evt;
  always_comb begin
    safety_evt                 = 32'b0;
    safety_evt[0]              = evt_rf_par_err_i;
    safety_evt[1]              = evt_illegal_i;
    safety_evt[2]              = evt_bus_err_i;
    safety_evt[3]              = evt_lockstep_i;
  end

  integer pi;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mstatus_mie_q  <= 1'b0;
      mstatus_mpie_q <= 1'b0;
      mie_q          <= 32'b0;
      mtvec_q        <= 32'b0;
      mscratch_q     <= 32'b0;
      mepc_q         <= 32'b0;
      mcause_irq_q   <= 1'b0;
      mcause_code_q  <= 5'b0;
      mtval_q        <= 32'b0;
      msafestat_q    <= 32'b0;
      msafectrl_q    <= 32'b0;
      for (pi = 0; pi < PMP_REGIONS; pi = pi + 1) begin
        pmpcfg_q[pi]  <= 8'b0;
        pmpaddr_q[pi] <= 32'b0;
      end
    end else begin
      msafestat_q <= msafestat_q | safety_evt;

      if (csr_we) begin
        if (is_pmpaddr) begin
          if (pmpaddr_writable({29'b0, pmpaddr_idx}))
            pmpaddr_q[pmpaddr_idx] <= csr_wdata;
        end else begin
          unique case (addr_i)
            CSR_MSTATUS: begin
              mstatus_mie_q  <= csr_wdata[3];
              mstatus_mpie_q <= csr_wdata[7];
            end
            CSR_MIE:       mie_q         <= csr_wdata & 32'h0000_0888;
            CSR_MTVEC:     mtvec_q       <= {csr_wdata[31:2], 1'b0, csr_wdata[0]};
            CSR_MSCRATCH:  mscratch_q    <= csr_wdata;
            // IALIGN = 16: bit 1 is significant, bit 0 is not.
            CSR_MEPC:      mepc_q        <= {csr_wdata[31:1], 1'b0};
            CSR_MCAUSE: begin
              mcause_irq_q  <= csr_wdata[31];
              mcause_code_q <= csr_wdata[4:0];
            end
            CSR_MTVAL:     mtval_q       <= csr_wdata;
            CSR_MSAFESTAT: msafestat_q   <= (msafestat_q & ~csr_wdata) | safety_evt;
            CSR_PMPCFG0: begin
              pmpcfg_q[0] <= pmpcfg_next(pmpcfg_q[0], csr_wdata[7:0]);
              pmpcfg_q[1] <= pmpcfg_next(pmpcfg_q[1], csr_wdata[15:8]);
              pmpcfg_q[2] <= pmpcfg_next(pmpcfg_q[2], csr_wdata[23:16]);
              pmpcfg_q[3] <= pmpcfg_next(pmpcfg_q[3], csr_wdata[31:24]);
            end
            CSR_PMPCFG1: begin
              pmpcfg_q[4] <= pmpcfg_next(pmpcfg_q[4], csr_wdata[7:0]);
              pmpcfg_q[5] <= pmpcfg_next(pmpcfg_q[5], csr_wdata[15:8]);
              pmpcfg_q[6] <= pmpcfg_next(pmpcfg_q[6], csr_wdata[23:16]);
              pmpcfg_q[7] <= pmpcfg_next(pmpcfg_q[7], csr_wdata[31:24]);
            end
            default: ;   // pmpcfg2/3 land here: decoded, no storage
          endcase
        end
      end

      msafectrl_q <= 32'b0;
      msafectrl_q[0] <= (csr_we && (addr_i == CSR_MSAFECTRL)) ? csr_wdata[0] : msafectrl_q[0];
      msafectrl_q[1] <= csr_we && (addr_i == CSR_MSAFECTRL) && csr_wdata[1];

      if (trap_i) begin
        mstatus_mpie_q <= mstatus_mie_q;
        mstatus_mie_q  <= 1'b0;
        mepc_q         <= {trap_pc_i[31:1], 1'b0};
        mcause_irq_q   <= trap_is_irq_i;
        mcause_code_q  <= trap_cause_i;
        mtval_q        <= trap_val_i;
      end else if (mret_i) begin
        mstatus_mie_q  <= mstatus_mpie_q;
        mstatus_mpie_q <= 1'b1;
      end
    end
  end

  assign mtvec_o        = mtvec_q;
  assign mepc_o         = mepc_q;
  assign mstatus_mie_o  = mstatus_mie_q;
  assign sw_fault_o     = msafectrl_q[1];
  assign fault_out_en_o = msafectrl_q[0];

  for (genvar g = 0; g < PMP_REGIONS; g++) begin : g_pmp_out
    assign pmp_cfg_o[g]  = pmpcfg_q[g];
    assign pmp_addr_o[g] = pmpaddr_q[g];
  end

  cdriscv_32s_20_counter64 u_mcycle (
      .clk_i   (clk_i),
      .rst_ni  (rst_ni),
      .inc_i   (1'b1),
      .wr_lo_i (csr_we && (addr_i == CSR_MCYCLE)),
      .wr_hi_i (csr_we && (addr_i == CSR_MCYCLEH)),
      .wdata_i (csr_wdata),
      .q_o     (mcycle_q)
  );

  cdriscv_32s_20_counter64 u_minstret (
      .clk_i   (clk_i),
      .rst_ni  (rst_ni),
      .inc_i   (instr_retired_i),
      .wr_lo_i (csr_we && (addr_i == CSR_MINSTRET)),
      .wr_hi_i (csr_we && (addr_i == CSR_MINSTRETH)),
      .wdata_i (csr_wdata),
      .q_o     (minstret_q)
  );

  // ------------------------------------------------------------------
  // Configuration parity
  // ------------------------------------------------------------------
  // Two groups behind one cfg_err_o (the core exports a single
  // fault_cfg_par_o, which the subsystem folds into CFG_SRC bit 6 --
  // "the core's CSR file"; finer attribution would need a port, and
  // the reaction is identical either way):
  //
  //  * mtvec, guarded since V37;
  //  * the PMP arrays (pmpcfg0/1 storage + pmpaddr0..7), added
  //    2026-09-02.  The fault campaign measured 90.8 % of PMP-array
  //    SEUs as LATENT (407 of 448, verification_findings_20.md
  //    section 18): a flip silently rewrites protection that nothing
  //    consumes until much later, which is exactly the quasi-static
  //    fault class this mechanism exists for.  Separate instance, so a
  //    frequent mtvec rewrite never re-baselines the PMP fold.
  //
  // Both folds run over the STORED arrays (pmpcfg_q / pmpaddr_q), not
  // the written value: pmpcfg writes are WARL-masked on the way in
  // (bits [6:5] dropped, R=0/W=1 and locked bytes rejected), so parity
  // over csr_wdata would disagree with the register it claims to
  // guard.  cfg_parity captures one cycle AFTER the write pulse, from
  // cfg_i itself, which makes the stored-value property structural.
  // The wr pulse covers every architectural write that can touch the
  // group -- including a fully-locked no-op write, which harmlessly
  // re-captures the unchanged parity.  pmpcfg2/3 hold no storage and
  // are excluded.
  logic mtvec_par_err, pmp_par_err;
  logic [40*PMP_REGIONS-1:0] pmp_par_flat;

  cdriscv_32s_20_cfg_parity #(.Width(32)) u_cfg_par (
      .clk_i  (clk_i),
      .rst_ni (rst_ni),
      .cfg_i  (mtvec_q),
      .wr_i   (csr_we && (addr_i == CSR_MTVEC)),
      .err_o  (mtvec_par_err)
  );

  always_comb begin
    pmp_par_flat = '0;
    for (int i = 0; i < PMP_REGIONS; i++) begin
      pmp_par_flat[8*i +: 8] = pmpcfg_q[i];
      pmp_par_flat[8*PMP_REGIONS + 32*i +: 32] = pmpaddr_q[i];
    end
  end

  cdriscv_32s_20_cfg_parity #(.Width(40*PMP_REGIONS)) u_pmp_par (
      .clk_i  (clk_i),
      .rst_ni (rst_ni),
      .cfg_i  (pmp_par_flat),
      .wr_i   (csr_we && (is_pmpaddr ||
                          (addr_i == CSR_PMPCFG0) || (addr_i == CSR_PMPCFG1))),
      .err_o  (pmp_par_err)
  );

  assign cfg_err_o = mtvec_par_err || pmp_par_err;

endmodule

`default_nettype wire
