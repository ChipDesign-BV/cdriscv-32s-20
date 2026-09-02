// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s-20 -- sequential divider (RV32M divide/remainder half).
//
// One restoring divider, 32 cycles.  Deliberately iterative: no wide
// combinational arrays, a short critical path, and a data-independent
// latency (always 32 iterations, also for a division by zero on the
// early-out path) so that execution time stays predictable, which
// matters for the WCET argument of a safety application.
//
// The multiply half this module inherited from cdriscv-32s-10 was
// REMOVED on 2026-09-02 (finding, verification_findings_20.md section
// 17): variant 2 routes every multiply to the single-cycle
// cdriscv_32s_20_mult, so the iterative multiply datapath here was
// dead in-system -- verified logic with no functional observer, i.e.
// pure latent-fault surface for the FMEDA.  The divide/remainder
// datapath is byte-for-byte the one that met cdriscv-32s-10's O1-O7
// gate; only the multiply arms, their sign-correction register and the
// mul iteration step were deleted.
//
// The module keeps its historical name: the core's port map, the file
// lists and the gate-level benches all reference it, and renaming
// would churn every one of them for no behavioural gain.
//
// STRUCTURAL CONTRACT: req_i is only ever asserted with a divide
// operation (operator_i[2] set -- md_op_e keeps the funct3 encoding,
// where bit 2 separates divides from multiplies).  The core enforces
// this structurally: `start_md` is gated by `!md_is_mul` (see
// cdriscv_32s_20_core.sv), so a multiply op can never reach req_i.  A
// simulation-only check below turns that contract into a failure
// rather than a silently-wrong quotient.
//
// Handshake: assert req_i for one cycle while busy_o is low.  valid_o
// pulses for one cycle when result_o is valid.

`default_nettype none

module cdriscv_32s_20_multdiv
  import cdriscv_32s_20_pkg::*;
(
    input  logic        clk_i,
    input  logic        rst_ni,

    input  logic        req_i,
    input  md_op_e      operator_i,
    input  logic [31:0] operand_a_i,
    input  logic [31:0] operand_b_i,
    input  logic        kill_i,        // abort (flush on trap)

    output logic        busy_o,
    output logic        valid_o,
    output logic [31:0] result_o
);

  typedef enum logic [1:0] {
    MD_IDLE,
    MD_COMP,
    MD_FINISH
  } state_e;

  state_e      state_q, state_d;
  logic [5:0]  cnt_q;

  // latched operation attributes
  md_op_e      op_q;
  logic        div_zero_q;    // divisor was zero
  logic [31:0] orig_a_q;      // original (unmodified) operand a
  logic        neg_quot_q;    // negate the quotient
  logic        neg_rem_q;     // negate the remainder

  // datapath registers
  logic [31:0] opa_q;         // divisor
  logic [31:0] num_q;         // dividend
  logic [32:0] acc_q;         // partial remainder
  logic [31:0] quot_q;

  // ------------------------------------------------------------------
  // Operand preparation
  // ------------------------------------------------------------------
  // DIV/REM are signed, DIVU/REMU unsigned; multiplies cannot arrive
  // (see the structural contract in the header).
  logic signed_op;
  assign signed_op = (operator_i == MD_DIV) || (operator_i == MD_REM);

  logic        neg_a, neg_b;
  logic [31:0] abs_a, abs_b;

  assign neg_a = signed_op & operand_a_i[31];
  assign neg_b = signed_op & operand_b_i[31];
  assign abs_a = neg_a ? (~operand_a_i + 32'd1) : operand_a_i;
  assign abs_b = neg_b ? (~operand_b_i + 32'd1) : operand_b_i;

`ifndef SYNTHESIS
  // The structural contract, as a check that runs: a request carrying
  // a multiply encoding means the core's dispatch gate has been broken.
  // (=== so an in-reset X never fires it; no rst_ni term, which would
  // put an async net to synchronous use and trip SYNCASYNCNET.)
  always @(posedge clk_i) begin
    if (req_i === 1'b1 && operator_i[2] === 1'b0)
      $display("[%m] ERROR: multiply operation %0d reached the divider",
               operator_i);
  end
`endif

  // ------------------------------------------------------------------
  // Iteration datapath
  // ------------------------------------------------------------------
  // divide: shift the dividend into the partial remainder, subtract
  // when it fits (restoring division).
  logic [32:0] rem_shifted, rem_sub;
  logic        rem_fits;
  assign rem_shifted = {acc_q[31:0], num_q[31]};
  assign rem_sub     = rem_shifted - {1'b0, opa_q};
  assign rem_fits    = (rem_shifted >= {1'b0, opa_q});

  // ------------------------------------------------------------------
  // Control
  // ------------------------------------------------------------------
  always_comb begin
    state_d = state_q;
    unique case (state_q)
      MD_IDLE:   if (req_i)          state_d = MD_COMP;
      MD_COMP:   if (cnt_q == 6'd31) state_d = MD_FINISH;
      MD_FINISH:                     state_d = MD_IDLE;
      default:                       state_d = MD_IDLE;
    endcase
    if (kill_i) state_d = MD_IDLE;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q    <= MD_IDLE;
      cnt_q      <= '0;
      op_q       <= MD_DIV;
      div_zero_q <= 1'b0;
      orig_a_q   <= '0;
      neg_quot_q <= 1'b0;
      neg_rem_q  <= 1'b0;
      opa_q      <= '0;
      num_q      <= '0;
      acc_q      <= '0;
      quot_q     <= '0;
    end else begin
      state_q <= state_d;

      unique case (state_q)
        MD_IDLE: begin
          cnt_q <= '0;
          if (req_i) begin
            op_q       <= operator_i;
            div_zero_q <= (operand_b_i == 32'b0);
            orig_a_q   <= operand_a_i;
            neg_quot_q <= neg_a ^ neg_b;
            neg_rem_q  <= neg_a;                         // remainder follows the dividend
            opa_q      <= abs_b;                         // divisor
            num_q      <= abs_a;                         // dividend
            acc_q      <= '0;
            quot_q     <= '0;
          end
        end

        MD_COMP: begin
          cnt_q  <= cnt_q + 6'd1;
          acc_q  <= rem_fits ? rem_sub : rem_shifted;
          num_q  <= {num_q[30:0], 1'b0};
          quot_q <= {quot_q[30:0], rem_fits};
        end

        default: ;   // MD_FINISH: results are read combinationally
      endcase
    end
  end

  assign busy_o  = (state_q != MD_IDLE);
  assign valid_o = (state_q == MD_FINISH) && !kill_i;

  // ------------------------------------------------------------------
  // Result selection and sign correction
  // ------------------------------------------------------------------
  logic [31:0] quot_corr, rem_corr;

  assign quot_corr = neg_quot_q ? (~quot_q + 32'd1) : quot_q;
  assign rem_corr  = neg_rem_q  ? (~acc_q[31:0] + 32'd1) : acc_q[31:0];

  always_comb begin
    unique case (op_q)
      MD_DIV, MD_DIVU:        result_o = div_zero_q ? 32'hffff_ffff : quot_corr;
      MD_REM, MD_REMU:        result_o = div_zero_q ? orig_a_q      : rem_corr;
      // Multiply encodings cannot be latched (the structural contract
      // above); this arm is defensive, like every other default here.
      default:                result_o = '0;
    endcase
  end

endmodule
