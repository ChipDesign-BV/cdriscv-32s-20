// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s-20 -- Zca / Zcb decompressor.
//
// Expands a 16-bit compressed instruction into the equivalent 32-bit
// one.  Purely combinational and stateless: everything in Zca and Zcb
// has an exact 32-bit equivalent, so the whole extension reduces to a
// decode table and the pipeline never learns that compression exists.
//
// Zcmp is NOT expanded here, and cannot be: cm.push / cm.pop /
// cm.popret move a register LIST to or from the stack, which is several
// memory accesses and a stack adjustment -- a variable-length sequence,
// not a 32-bit instruction.  This module therefore only *recognises*
// the Zcmp encodings (zcmp_o; instr_o stays a nop for them) and the
// core runs the sequence from its ST_SEQ state, reading the step table
// in cdriscv_32s_20_zcmp.  Reserved Zcmp code points (rlist < 4,
// cm.mvsa01 with r1s' == r2s', the unassigned funct5 values) stay
// illegal here.
//
// The immediates are where this goes wrong.  Every RVC format scrambles
// its immediate bits differently and no two are alike, so each is
// written out bit by bit against the specification's own field tables
// rather than shifted or masked cleverly.  The bench checks all 65 536
// encodings against an independent model.
//
// illegal_o is raised for: the all-zero word (a defined illegal
// encoding, and what a fetch from erased memory looks like), reserved
// encodings, and RV64-only forms that must trap on RV32.
//
// STATUS: block-verified (doc/variant_status.md, section 2) and
// instantiated by the subsystem.  No signoff gate is met in this
// repository -- see README.md.  NOT qualified for safety-critical use.

`default_nettype none

module cdriscv_32s_20_decompress (
    input  logic [15:0] instr_i,
    output logic [31:0] instr_o,
    output logic        illegal_o,
    output logic        zcmp_o        // a (legal) Zcmp sequence instruction
);

  // ---- register fields ------------------------------------------------
  logic [4:0] rd, rs1, rs2, rdp, rs1p, rs2p;
  assign rd   = instr_i[11:7];
  assign rs1  = instr_i[11:7];
  assign rs2  = instr_i[6:2];
  assign rdp  = {2'b01, instr_i[4:2]};    // x8..x15
  assign rs1p = {2'b01, instr_i[9:7]};
  assign rs2p = {2'b01, instr_i[4:2]};

  // ---- immediates, one per RVC format ---------------------------------
  logic [31:0] imm_ciw, imm_cl, imm_ci, imm_ci16, imm_clui;
  logic [31:0] imm_cj, imm_cb, imm_lwsp, imm_swsp;
  logic [4:0]  shamt;

  // CIW  (c.addi4spn): nzuimm[5:4|9:6|2|3], scaled by 4
  assign imm_ciw  = {22'b0, instr_i[10:7], instr_i[12:11], instr_i[5], instr_i[6], 2'b00};
  // CL/CS (c.lw/c.sw): uimm[5:3|2|6], scaled by 4
  assign imm_cl   = {25'b0, instr_i[5], instr_i[12:10], instr_i[6], 2'b00};
  // CI   (c.addi/c.li/c.andi): imm[5|4:0], sign extended
  assign imm_ci   = {{26{instr_i[12]}}, instr_i[12], instr_i[6:2]};
  // c.addi16sp: nzimm[9|4|6|8:7|5], scaled by 16
  assign imm_ci16 = {{22{instr_i[12]}}, instr_i[12], instr_i[4:3],
                     instr_i[5], instr_i[2], instr_i[6], 4'b0000};
  // c.lui: nzimm[17|16:12]
  assign imm_clui = {{14{instr_i[12]}}, instr_i[12], instr_i[6:2], 12'b0};
  // CJ (c.j/c.jal): imm[11|4|9:8|10|6|7|3:1|5]
  assign imm_cj   = {{20{instr_i[12]}}, instr_i[12], instr_i[8], instr_i[10:9],
                     instr_i[6], instr_i[7], instr_i[2], instr_i[11],
                     instr_i[5:3], 1'b0};
  // CB (c.beqz/c.bnez): imm[8|4:3|7:6|2:1|5]
  assign imm_cb   = {{23{instr_i[12]}}, instr_i[12], instr_i[6:5], instr_i[2],
                     instr_i[11:10], instr_i[4:3], 1'b0};
  // c.lwsp: uimm[5|4:2|7:6]
  assign imm_lwsp = {24'b0, instr_i[3:2], instr_i[12], instr_i[6:4], 2'b00};
  // c.swsp: uimm[5:2|7:6]
  assign imm_swsp = {24'b0, instr_i[8:7], instr_i[12:9], 2'b00};
  assign shamt    = instr_i[6:2];

  // ---- 32-bit instruction builders ------------------------------------
  function automatic logic [31:0] i_type(logic [31:0] immv, logic [4:0] s1,
                                         logic [2:0] f3, logic [4:0] d,
                                         logic [6:0] op);
    return {immv[11:0], s1, f3, d, op};
  endfunction

  function automatic logic [31:0] s_type(logic [31:0] immv, logic [4:0] s2,
                                         logic [4:0] s1, logic [2:0] f3,
                                         logic [6:0] op);
    return {immv[11:5], s2, s1, f3, immv[4:0], op};
  endfunction

  function automatic logic [31:0] r_type(logic [6:0] f7, logic [4:0] s2,
                                         logic [4:0] s1, logic [2:0] f3,
                                         logic [4:0] d, logic [6:0] op);
    return {f7, s2, s1, f3, d, op};
  endfunction

  function automatic logic [31:0] b_type(logic [31:0] immv, logic [4:0] s2,
                                         logic [4:0] s1, logic [2:0] f3);
    return {immv[12], immv[10:5], s2, s1, f3, immv[4:1], immv[11], 7'h63};
  endfunction

  function automatic logic [31:0] j_type(logic [31:0] immv, logic [4:0] d);
    return {immv[20], immv[10:1], immv[11], immv[19:12], d, 7'h6f};
  endfunction

  // ---- the decode table -------------------------------------------------
  always_comb begin
    instr_o   = 32'h0000_0013;      // nop, so an unexpanded word is inert
    illegal_o = 1'b0;
    zcmp_o    = 1'b0;

    unique case (instr_i[1:0])

      // ================================================= quadrant 0
      2'b00 : begin
        unique case (instr_i[15:13])
          3'b000 : begin                       // c.addi4spn
            if (instr_i[12:5] == 8'b0) illegal_o = 1'b1;   // reserved
            else instr_o = i_type(imm_ciw, 5'd2, 3'b000, rdp, 7'h13);
          end
          3'b010 : instr_o = i_type(imm_cl, rs1p, 3'b010, rs2p, 7'h03); // c.lw
          3'b110 : instr_o = s_type(imm_cl, rs2p, rs1p, 3'b010, 7'h23); // c.sw
          // ---- Zcb ----
          3'b100 : begin
            unique case (instr_i[12:10])
              3'b000 : instr_o = i_type({30'b0, instr_i[5], instr_i[6]},   // c.lbu
                                        rs1p, 3'b100, rs2p, 7'h03);
              3'b001 : if (instr_i[6])                                     // c.lh
                         instr_o = i_type({30'b0, instr_i[5], 1'b0},
                                          rs1p, 3'b001, rs2p, 7'h03);
                       else                                                // c.lhu
                         instr_o = i_type({30'b0, instr_i[5], 1'b0},
                                          rs1p, 3'b101, rs2p, 7'h03);
              3'b010 : instr_o = s_type({30'b0, instr_i[5], instr_i[6]},   // c.sb
                                        rs2p, rs1p, 3'b000, 7'h23);
              3'b011 : if (instr_i[6]) illegal_o = 1'b1;
                       else instr_o = s_type({30'b0, instr_i[5], 1'b0},    // c.sh
                                             rs2p, rs1p, 3'b001, 7'h23);
              default : illegal_o = 1'b1;
            endcase
          end
          default : illegal_o = 1'b1;          // FP loads/stores: not in Zca
        endcase
      end

      // ================================================= quadrant 1
      2'b01 : begin
        unique case (instr_i[15:13])
          3'b000 : instr_o = i_type(imm_ci, rd, 3'b000, rd, 7'h13);  // c.nop/c.addi
          3'b001 : instr_o = j_type(imm_cj, 5'd1);                   // c.jal (RV32)
          3'b010 : begin                                             // c.li
            // rd=x0 is a HINT, and the spec requires HINTs to execute as
            // no-ops rather than trap.  Expanding to addi x0,x0,imm does
            // exactly that -- the write is discarded because x0 is x0.
            instr_o = i_type(imm_ci, 5'd0, 3'b000, rd, 7'h13);
          end
          3'b011 : begin
            if (rd == 5'd2) begin                                    // c.addi16sp
              if (imm_ci16[9:0] == 10'b0 && instr_i[12] == 1'b0) illegal_o = 1'b1;
              else instr_o = i_type(imm_ci16, 5'd2, 3'b000, 5'd2, 7'h13);
            end else begin                                            // c.lui
              // Only nzimm == 0 is reserved.  rd == x0 with a non-zero
              // immediate is a HINT and must execute as a no-op, so it
              // expands to lui x0 -- a write to x0, which is one.  This
              // used to trap, the same defect already fixed on c.li,
              // c.slli, c.mv and c.add.
              if (instr_i[12] == 1'b0 && instr_i[6:2] == 5'b0) illegal_o = 1'b1;
              else instr_o = {imm_clui[31:12], rd, 7'h37};
            end
          end
          3'b100 : begin
            unique case (instr_i[11:10])
              // shamt[5] (instr[12]) is RV64-only; on RV32 the encoding is
              // reserved and must trap.  c.slli in quadrant 2 already did
              // this -- these two silently dropped the bit and shifted by
              // shamt[4:0] instead.
              2'b00 : if (instr_i[12]) illegal_o = 1'b1;                        // c.srli
                      else instr_o = r_type(7'h00, shamt, rs1p, 3'b101, rs1p, 7'h13);
              2'b01 : if (instr_i[12]) illegal_o = 1'b1;                        // c.srai
                      else instr_o = r_type(7'h20, shamt, rs1p, 3'b101, rs1p, 7'h13);
              2'b10 : instr_o = i_type(imm_ci, rs1p, 3'b111, rs1p, 7'h13);       // c.andi
              2'b11 : begin
                if (instr_i[12] == 1'b0) begin
                  unique case (instr_i[6:5])
                    2'b00 : instr_o = r_type(7'h20, rs2p, rs1p, 3'b000, rs1p, 7'h33); // c.sub
                    2'b01 : instr_o = r_type(7'h00, rs2p, rs1p, 3'b100, rs1p, 7'h33); // c.xor
                    2'b10 : instr_o = r_type(7'h00, rs2p, rs1p, 3'b110, rs1p, 7'h33); // c.or
                    2'b11 : instr_o = r_type(7'h00, rs2p, rs1p, 3'b111, rs1p, 7'h33); // c.and
                    default : illegal_o = 1'b1;
                  endcase
                end else begin
                  // ---- Zcb ----
                  // instr[6:5] selects the group and instr[4:2] the member:
                  //   10 -> c.mul rd',rs2'     11 -> the unary ops
                  //   00, 01 -> reserved
                  // This was decoded on instr[6:5] alone, which mapped four
                  // reserved encodings onto real instructions, dropped c.mul
                  // entirely, and gave c.not and c.zext.b the same expansion.
                  unique case (instr_i[6:5])
                    2'b10 : instr_o = r_type(7'h01, rs2p, rs1p, 3'b000, rs1p, 7'h33); // c.mul
                    2'b11 : begin
                      unique case (instr_i[4:2])
                        3'b000 : instr_o = i_type(32'h0ff, rs1p, 3'b111, rs1p, 7'h13);  // c.zext.b
                        3'b001 : instr_o = r_type(7'h30, 5'd4, rs1p, 3'b001, rs1p, 7'h13); // c.sext.b
                        3'b010 : instr_o = r_type(7'h04, 5'd0, rs1p, 3'b100, rs1p, 7'h33); // c.zext.h
                        3'b011 : instr_o = r_type(7'h30, 5'd5, rs1p, 3'b001, rs1p, 7'h13); // c.sext.h
                        3'b101 : instr_o = i_type(32'hfff, rs1p, 3'b100, rs1p, 7'h13);  // c.not
                        // 100 is c.zext.w, RV64 only; 110 and 111 reserved
                        default : illegal_o = 1'b1;
                      endcase
                    end
                    default : illegal_o = 1'b1;                       // 00, 01 reserved
                  endcase
                end
              end
              default : illegal_o = 1'b1;
            endcase
          end
          3'b101 : instr_o = j_type(imm_cj, 5'd0);                    // c.j
          3'b110 : instr_o = b_type(imm_cb, 5'd0, rs1p, 3'b000);      // c.beqz
          3'b111 : instr_o = b_type(imm_cb, 5'd0, rs1p, 3'b001);      // c.bnez
          default : illegal_o = 1'b1;
        endcase
      end

      // ================================================= quadrant 2
      2'b10 : begin
        unique case (instr_i[15:13])
          3'b000 : begin                                              // c.slli
            // shamt[5] set is RV64 only and must trap on RV32.  rd=x0 is
            // a HINT and must NOT trap.
            if (instr_i[12] == 1'b1) illegal_o = 1'b1;
            else instr_o = r_type(7'h00, shamt, rd, 3'b001, rd, 7'h13);
          end
          3'b010 : begin                                              // c.lwsp
            if (rd == 5'd0) illegal_o = 1'b1;
            else instr_o = i_type(imm_lwsp, 5'd2, 3'b010, rd, 7'h03);
          end
          3'b100 : begin
            if (instr_i[12] == 1'b0) begin
              if (rs2 == 5'd0) begin                                  // c.jr
                if (rs1 == 5'd0) illegal_o = 1'b1;
                else instr_o = i_type(32'b0, rs1, 3'b000, 5'd0, 7'h67);
              end else begin                                          // c.mv
                instr_o = r_type(7'h00, rs2, 5'd0, 3'b000, rd, 7'h33); // rd=x0: HINT
              end
            end else begin
              if (rs2 == 5'd0) begin
                if (rs1 == 5'd0) instr_o = 32'h0010_0073;             // c.ebreak
                else             instr_o = i_type(32'b0, rs1, 3'b000, 5'd1, 7'h67); // c.jalr
              end else begin                                          // c.add
                instr_o = r_type(7'h00, rs2, rd, 3'b000, rd, 7'h33);   // rd=x0: HINT
              end
            end
          end
          3'b110 : instr_o = s_type(imm_swsp, rs2, 5'd2, 3'b010, 7'h23); // c.swsp
          // ---- Zcmp ----
          // Flagged, never expanded: the core sequences these from the
          // step table in cdriscv_32s_20_zcmp; instr_o stays the nop.
          3'b101 : begin
            if (instr_i[12:11] == 2'b11 && instr_i[8] == 1'b0) begin
              // cm.push / cm.pop / cm.popretz / cm.popret, selected by
              // instr[10:9].  rlist values 0..3 are reserved (binutils
              // is lax and disassembles them; the spec reserves them,
              // so they trap here, and check_decompress.py carries the
              // commented exception like the shamt[5] ones).
              if (instr_i[7:4] >= 4'd4) zcmp_o = 1'b1;
              else                      illegal_o = 1'b1;
            end else if (instr_i[12:10] == 3'b011 && instr_i[5] == 1'b1) begin
              // cm.mvsa01 (instr[6]=0) / cm.mva01s (instr[6]=1).
              // cm.mvsa01 with r1s' == r2s' is reserved; cm.mva01s with
              // equal fields is legal (both destinations get the same
              // value, no aliasing).
              if (!instr_i[6] && (instr_i[9:7] == instr_i[4:2]))
                illegal_o = 1'b1;
              else
                zcmp_o = 1'b1;
            end else begin
              // funct5 with bit 8 set, and the [6:5] = 00/10 half of
              // the 101011 row (Zcmt's cm.jt/cm.jalt live elsewhere):
              // all reserved or unimplemented here.
              illegal_o = 1'b1;
            end
          end
          default : illegal_o = 1'b1;
        endcase
      end

      // ================================================= not compressed
      default : illegal_o = 1'b1;
    endcase

    // The all-zero halfword is a defined illegal encoding, and is what a
    // fetch from erased or unwritten memory looks like.  Checked last so
    // it cannot be masked by a quadrant-0 decode.
    if (instr_i == 16'h0000) illegal_o = 1'b1;
  end

endmodule
