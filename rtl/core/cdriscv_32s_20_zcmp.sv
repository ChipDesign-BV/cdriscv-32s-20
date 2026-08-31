// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s-20 -- Zcmp sequence table.
//
// cm.push / cm.pop / cm.popret / cm.popretz / cm.mva01s / cm.mvsa01
// have no 32-bit equivalent: they expand to a VARIABLE-LENGTH sequence
// of loads or stores plus a stack-pointer adjustment (up to 14 steps
// for cm.push {ra, s0-s11}).  The decompressor therefore only FLAGS
// them (zcmp_o) and the core runs them from ST_SEQ, one step per
// micro-operation, reading this table.
//
// This module is purely combinational: given the raw 16-bit encoding
// and a step index it answers "what does step N of this instruction
// do".  Keeping the whole expansion in one stateless table makes it
// directly enumerable by a bench -- verif/block/zcmp/tb_zcmp.sv dumps
// every step of every encoding and scripts/check_zcmp.py replays the
// dump against a Spike commit log, so the table is checked against an
// independent implementation, never against itself.
//
// Step plan (n = number of registers in rlist):
//
//   cm.push     : n stores, sp adjust               (n+1 steps)
//   cm.pop      : n loads,  sp adjust               (n+1 steps)
//   cm.popret   : n loads,  sp adjust + ret         (n+1 steps)
//   cm.popretz  : n loads,  a0 = 0, sp adjust + ret (n+2 steps)
//   cm.mva01s   : a0 = r1s', a1 = r2s'              (2 steps)
//   cm.mvsa01   : r1s' = a0, r2s' = a1              (2 steps)
//
// Memory beats run in DESCENDING address order (the highest-numbered
// register sits just below the incoming sp for push, just below the
// outgoing sp for pop), matching the Zc v1.0 sequence and what Spike
// logs.  The sp write is ALWAYS the final step: a memory beat that
// faults then leaves sp untouched, so mepc = the cm PC restarts the
// whole instruction cleanly -- the spec permits this because the
// memory below the final sp is volatile across the instruction.
//
// Outputs are only meaningful for an encoding the decompressor flags
// as Zcmp (cdriscv_32s_20_decompress.zcmp_o); anything else returns
// arbitrary but deterministic values that the core never consumes.
//
// STATUS: block-verified against Spike/binutils (block-zcmp,
// block-decompress) and instantiated by the core.  No signoff gate is
// met in this repository -- see README.md.  NOT qualified for
// safety-critical use.

`default_nettype none

module cdriscv_32s_20_zcmp (
    input  logic [15:0] instr_i,     // raw cm.* halfword
    input  logic [3:0]  step_i,      // micro-operation index, 0 first

    output logic        mem_o,       // this step is a memory access
    output logic        we_o,        // ... a store (cm.push)
    output logic [4:0]  rs1_o,       // base / move source register
    output logic [4:0]  rs2_o,       // store data register; ra for ret
    output logic [4:0]  rd_o,        // load / move / sp destination
    output logic [31:0] imm_o,       // sp-relative offset, or ALU op B
    output logic        op_a_zero_o, // ALU operand A is zero (a0 = 0)
    output logic        wb_o,        // non-memory step writes rd_o
    output logic        last_o,      // final step: retire here
    output logic        ret_o        // final step redirects to rs2 (ra)
);

  // ---- fields ---------------------------------------------------------
  logic [3:0] rlist;
  logic [1:0] spimm;
  logic [2:0] r1sp, r2sp;
  logic       is_mv, is_mva01s;
  logic       is_push, is_popretz, is_popret;

  assign rlist = instr_i[7:4];
  assign spimm = instr_i[3:2];
  assign r1sp  = instr_i[9:7];
  assign r2sp  = instr_i[4:2];

  // cm.mva01s / cm.mvsa01: funct6 = 101011, instr[5] = 1
  assign is_mv     = (instr_i[15:10] == 6'b101011) && instr_i[5];
  assign is_mva01s = instr_i[6];

  // push family: instr[15:13] = 101, instr[12:11] = 11, instr[8] = 0;
  // instr[10:9] selects 00 push / 01 pop / 10 popretz / 11 popret
  assign is_push    = (instr_i[10:9] == 2'b00);
  assign is_popretz = (instr_i[10:9] == 2'b10);
  assign is_popret  = (instr_i[10:9] == 2'b11);

  // ---- register list and stack adjustment -----------------------------
  // rlist 4..14 encode {ra, s0-s(rlist-5)} = rlist-3 registers; rlist 15
  // is {ra, s0-s11} = 13 registers (12 would encode {ra, s0-s10}+s11 as
  // 14, which does not exist -- 15 skips a count on purpose).
  logic [3:0] n;
  assign n = (rlist == 4'd15) ? 4'd13 : (rlist - 4'd3);

  // Base bytes: 4n rounded up to a 16-byte multiple, plus 16 * spimm.
  logic [7:0] adj;
  always_comb begin
    if      (n <= 4'd4)  adj = 8'd16;
    else if (n <= 4'd8)  adj = 8'd32;
    else if (n <= 4'd12) adj = 8'd48;
    else                 adj = 8'd64;
    adj = adj + {2'b00, spimm, 4'b0000};
  end

  // list[j]: j = 0 -> ra(x1), 1 -> s0(x8), 2 -> s1(x9), 3.. -> s2..s11
  // (x18..x27)
  function automatic logic [4:0] sreg(input logic [3:0] j);
    unique case (j)
      4'd0:    sreg = 5'd1;
      4'd1:    sreg = 5'd8;
      4'd2:    sreg = 5'd9;
      default: sreg = 5'd15 + {1'b0, j};
    endcase
  endfunction

  // s' fields of the mv forms reach s0-s7 only: 0-1 -> x8-x9, 2-7 ->
  // x18-x23
  function automatic logic [4:0] sregp(input logic [2:0] r);
    sregp = (r < 3'd2) ? (5'd8 + {2'b00, r}) : (5'd16 + {2'b00, r});
  endfunction

  // Negative running offset for step i: -(4 * (i + 1))
  logic [31:0] beat_off;
  assign beat_off = {26'b0, step_i, 2'b00} + 32'd4;

  // ---- the table ------------------------------------------------------
  always_comb begin
    mem_o       = 1'b0;
    we_o        = 1'b0;
    rs1_o       = 5'd2;          // sp, except for the moves
    rs2_o       = 5'd0;
    rd_o        = 5'd0;
    imm_o       = 32'b0;
    op_a_zero_o = 1'b0;
    wb_o        = 1'b0;
    last_o      = 1'b0;
    ret_o       = 1'b0;

    if (is_mv) begin
      // Two plain register moves, one per step.  The source sets never
      // overlap the destination sets (a0/a1 against s0-s7), so the two
      // steps cannot alias and their order is architecturally free.
      wb_o   = 1'b1;
      last_o = (step_i != 4'd0);
      if (is_mva01s) begin
        rd_o  = (step_i == 4'd0) ? 5'd10 : 5'd11;
        rs1_o = (step_i == 4'd0) ? sregp(r1sp) : sregp(r2sp);
      end else begin
        rd_o  = (step_i == 4'd0) ? sregp(r1sp) : sregp(r2sp);
        rs1_o = (step_i == 4'd0) ? 5'd10 : 5'd11;
      end
    end else if (is_push) begin
      // Stores first, highest list member at sp-4, descending; the sp
      // write is the LAST step so a faulting store leaves sp untouched
      // and the instruction restartable from mepc.
      if (step_i < n) begin
        mem_o = 1'b1;
        we_o  = 1'b1;
        rs2_o = sreg(n - 4'd1 - step_i);
        imm_o = 32'b0 - beat_off;
      end else begin
        wb_o   = 1'b1;
        last_o = 1'b1;
        rd_o   = 5'd2;
        imm_o  = 32'b0 - {24'b0, adj};
      end
    end else begin
      // pop family: loads from the block just below sp + adj, highest
      // list member first, again descending; then a0 = 0 for popretz;
      // the sp write is again LAST for the same restartability reason.
      if (step_i < n) begin
        mem_o = 1'b1;
        rd_o  = sreg(n - 4'd1 - step_i);
        imm_o = {24'b0, adj} - beat_off;
      end else if (is_popretz && (step_i == n)) begin
        wb_o        = 1'b1;
        op_a_zero_o = 1'b1;
        rd_o        = 5'd10;
      end else begin
        wb_o   = 1'b1;
        last_o = 1'b1;
        rd_o   = 5'd2;
        imm_o  = {24'b0, adj};
        ret_o  = is_popret || is_popretz;
        rs2_o  = 5'd1;                     // ra, read for the redirect
      end
    end
  end

  // The op bits [1:0] are the quadrant (always 10 for a flagged Zcmp
  // encoding) and carry no information here.
  logic unused_ok;
  assign unused_ok = &{1'b1, instr_i[1:0]};

endmodule

`default_nettype wire
