// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// Formal properties for cdriscv_32s_20_decompress, composed with the
// 32-bit decoder it feeds.
//
// decoder_fv.sv proves, over every one of the 2^32 encodings, that an
// instruction the decoder rejects has no architectural effect.  Its
// p_only_32bit relies on compression being handled *before* the decoder,
// by cdriscv_32s_20_decompress.  This file closes that gap: the
// decompressor is purely combinational, so a depth-2 BMC quantifies over
// every one of the 2^16 halfwords, and the decompressor -> decoder pair
// is checked in series exactly as cdriscv_32s_20_if_align wires it.
//
// What is proved, for every 16-bit input:
//
//   1. Composed illegal-has-no-effect.  If the decompressor rejects the
//      halfword, or recognises it as a Zcmp sequence (which it does not
//      expand), or the decoder rejects the expansion, then the decoder
//      outputs show no architectural effect: no LSU, mult/div, branch,
//      jump, CSR or system side effect, and no register-file write except
//      to x0.  The x0 allowance is deliberate and is stated rather than
//      hidden: the decompressor's contract is that anything it does not
//      expand comes out as the inert nop `addi x0,x0,0` (32'h0000_0013),
//      which the decoder legitimately decodes with rf_we=1, rd=0 -- a
//      write to x0 is, by definition of x0, no effect.  The core then
//      also kills the instruction (instr_illegal_c -> take_exc, so
//      `retire && rf_we_dec` never fires) -- that gating is sequential
//      and outside this combinational proof.  p_rejected_is_nop pins the
//      nop itself so the allowance cannot widen.
//
//   2. Consistency.  Everything the decompressor calls legal (and every
//      Zcmp nop) is a 32-bit encoding (bits [1:0] == 2'b11) that the
//      decoder does NOT flag illegal.  The decompressor never hands the
//      decoder something it rejects, so the only illegal-instruction
//      source for a compressed word is the decompressor's own flag, and
//      mtval (= the raw halfword, per the core) is always the right one.
//
//   3. RVC mapping pins.  A selection of expansions asserted against the
//      32-bit forms derived from the RISC-V Unprivileged ISA (C extension
//      chapter, RV32C tables, and the Zcb section), written out field by
//      field from the *specification's* bit tables, not copied from the
//      RTL: c.addi, c.addi4spn, c.lw, c.lwsp, c.swsp, c.jal, c.j, c.beqz,
//      c.jr, c.ebreak, and Zcb c.lbu, c.not, c.sext.b, c.mul.  These pin
//      the mapping so the proof is not only about the illegal path.
//
// Quadrant 3 (bits [1:0] == 2'b11) is NOT a compressed instruction.  The
// aligner still presents such halfwords to the decompressor (hw is wired
// unconditionally) and discards the result, and the RTL flags them
// illegal with the nop on instr_o.  That is asserted here (p_q3_illegal,
// covered by p_rejected_is_nop), not assumed away: the properties hold
// over the full 2^16 with no restriction on the input.
//
// There are NO assumes in this file.  Nothing in the decompressor's
// contract restricts its input -- if_align feeds it every halfword it
// sees -- so any assume would be unjustified and would make the proof
// weaker than the RTL's actual exposure.
//
// Zcmp (cm.push / cm.pop / cm.popret / cm.popretz / cm.mvsa01 /
// cm.mva01s) is only *recognised* here (zcmp_o); its execution is the
// multi-cycle sequencer cdriscv_32s_20_zcmp, which is sequential and out
// of scope for an exhaustive depth-2 proof.  It stays covered by
// simulation (block-zcmp against Spike; the fi-zcmp sweep).

`default_nettype none

module decompress_fv
  import cdriscv_32s_20_pkg::*;
(
    input  logic        clk_i,
    input  logic [15:0] instr_i
);

  // ------------------------------------------------------------------
  // DUT 1: the decompressor
  // ------------------------------------------------------------------
  logic [31:0] exp;         // 32-bit expansion
  logic        c_illegal;   // decompressor rejects the halfword
  logic        c_zcmp;      // legal Zcmp sequence instruction (not expanded)

  cdriscv_32s_20_decompress u_decompress (
      .instr_i   (instr_i),
      .instr_o   (exp),
      .illegal_o (c_illegal),
      .zcmp_o    (c_zcmp)
  );

  // ------------------------------------------------------------------
  // DUT 2: the decoder, fed by the expansion, same configuration as the
  // core instantiates (RV32M and RV32B on -- Zcb's c.sext.b / c.zext.h
  // expand to Zbb ops and c.mul to M, so the decoder must have both).
  // ------------------------------------------------------------------
  logic [4:0]  rs1_addr, rs2_addr, rd_addr;
  logic        rf_we, rs1_used, rs2_used;
  alu_op_e     alu_op;
  op_a_sel_e   op_a_sel;
  op_b_sel_e   op_b_sel;
  logic [31:0] imm;
  wb_sel_e     wb_sel;
  logic        md_req;
  md_op_e      md_op;
  logic        lsu_req, lsu_we, lsu_sign_ext;
  logic [1:0]  lsu_size;
  logic        branch, jump, jalr;
  logic        csr_access, csr_imm;
  csr_op_e     csr_op;
  logic [11:0] csr_addr;
  logic        ecall, ebreak, mret, wfi, fence, fencei;
  logic        d_illegal;   // decoder rejects the expansion

  cdriscv_32s_20_decoder #(.RV32M(1'b1), .RV32B(1'b1)) u_decoder (
      .instr_i         (exp),
      .rs1_addr_o      (rs1_addr),
      .rs2_addr_o      (rs2_addr),
      .rd_addr_o       (rd_addr),
      .rf_we_o         (rf_we),
      .rs1_used_o      (rs1_used),
      .rs2_used_o      (rs2_used),
      .alu_op_o        (alu_op),
      .op_a_sel_o      (op_a_sel),
      .op_b_sel_o      (op_b_sel),
      .imm_o           (imm),
      .wb_sel_o        (wb_sel),
      .md_req_o        (md_req),
      .md_op_o         (md_op),
      .lsu_req_o       (lsu_req),
      .lsu_we_o        (lsu_we),
      .lsu_size_o      (lsu_size),
      .lsu_sign_ext_o  (lsu_sign_ext),
      .branch_o        (branch),
      .jump_o          (jump),
      .jalr_o          (jalr),
      .csr_access_o    (csr_access),
      .csr_op_o        (csr_op),
      .csr_addr_o      (csr_addr),
      .csr_imm_o       (csr_imm),
      .ecall_o         (ecall),
      .ebreak_o        (ebreak),
      .mret_o          (mret),
      .wfi_o           (wfi),
      .fence_o         (fence),
      .fencei_o        (fencei),
      .illegal_instr_o (d_illegal)
  );

  // ------------------------------------------------------------------
  // Expected 32-bit forms, from the RISC-V specification's field tables.
  //
  // Naming follows the spec: for each RVC format the immediate bits are
  // taken from the instruction positions the spec's encoding table gives
  // them, then assembled into the base-ISA I/S/B/J field layout.  Every
  // one of these was written from the spec tables independently of the
  // RTL's imm_* wires; if the two disagree, the assertion fails and the
  // counterexample says which.
  // ------------------------------------------------------------------
  localparam logic [6:0] OP_LOAD   = 7'b0000011;
  localparam logic [6:0] OP_STORE  = 7'b0100011;
  localparam logic [6:0] OP_OPIMM  = 7'b0010011;
  localparam logic [6:0] OP_OP     = 7'b0110011;
  localparam logic [6:0] OP_BRANCH = 7'b1100011;
  localparam logic [6:0] OP_JALR   = 7'b1100111;
  localparam logic [6:0] OP_JAL    = 7'b1101111;

  localparam logic [31:0] NOP = 32'h0000_0013;   // addi x0, x0, 0

  // register fields per the RVC formats
  logic [4:0] f_rd;    // CI / CR: instr[11:7]  (also rs1)
  logic [4:0] f_rs2;   // CR / CSS: instr[6:2]
  logic [4:0] f_rs1p;  // CL / CS / CB / CA: x8 + instr[9:7]
  logic [4:0] f_rdp;   // CL / CIW / CA: x8 + instr[4:2]  (also rs2')
  assign f_rd   = instr_i[11:7];
  assign f_rs2  = instr_i[6:2];
  assign f_rs1p = {2'b01, instr_i[9:7]};
  assign f_rdp  = {2'b01, instr_i[4:2]};

  // CI immediate: imm[5] = instr[12], imm[4:0] = instr[6:2], sign-extended
  logic [11:0] ci_imm;
  assign ci_imm = {{6{instr_i[12]}}, instr_i[12], instr_i[6:2]};

  // CIW (c.addi4spn) nzuimm: [5:4] = instr[12:11], [9:6] = instr[10:7],
  // [2] = instr[6], [3] = instr[5]; bits [1:0] are zero.
  logic [11:0] ciw_imm;
  assign ciw_imm = {2'b00, instr_i[10:7], instr_i[12:11], instr_i[5], instr_i[6], 2'b00};

  // CL / CS (c.lw / c.sw) uimm: [5:3] = instr[12:10], [2] = instr[6],
  // [6] = instr[5]; bits [1:0] zero.
  logic [11:0] cl_imm;
  assign cl_imm = {5'b0, instr_i[5], instr_i[12:10], instr_i[6], 2'b00};

  // c.lwsp uimm: [5] = instr[12], [4:2] = instr[6:4], [7:6] = instr[3:2]
  logic [11:0] lwsp_imm;
  assign lwsp_imm = {4'b0, instr_i[3:2], instr_i[12], instr_i[6:4], 2'b00};

  // c.swsp uimm: [5:2] = instr[12:9], [7:6] = instr[8:7]
  logic [11:0] swsp_imm;
  assign swsp_imm = {4'b0, instr_i[8:7], instr_i[12:9], 2'b00};

  // CJ offset, from the spec table imm[11|4|9:8|10|6|7|3:1|5] at
  // instr[12:2]:
  //   instr[12] = off[11]   instr[11] = off[4]    instr[10:9] = off[9:8]
  //   instr[8]  = off[10]   instr[7]  = off[6]    instr[6]    = off[7]
  //   instr[5:3]= off[3:1]  instr[2]  = off[5]
  // Sign-extended to the 21-bit J-type range.
  logic [20:0] cj_off;
  assign cj_off = {{9{instr_i[12]}},                 // off[20:12]
                   instr_i[12],                      // off[11]
                   instr_i[8],                       // off[10]
                   instr_i[10:9],                    // off[9:8]
                   instr_i[6],                       // off[7]
                   instr_i[7],                       // off[6]
                   instr_i[2],                       // off[5]
                   instr_i[11],                      // off[4]
                   instr_i[5:3],                     // off[3:1]
                   1'b0};                            // off[0]

  // CB offset, from imm[8|4:3] at instr[12:10] and imm[7:6|2:1|5] at
  // instr[6:2]; sign-extended to the 13-bit B-type range.
  logic [12:0] cb_off;
  assign cb_off = {{4{instr_i[12]}},                 // off[12:9]
                   instr_i[12],                      // off[8]
                   instr_i[6:5],                     // off[7:6]
                   instr_i[2],                       // off[5]
                   instr_i[11:10],                   // off[4:3]
                   instr_i[4:3],                     // off[2:1]
                   1'b0};                            // off[0]

  // base-ISA format assemblers
  function automatic logic [31:0] fmt_i(logic [11:0] im, logic [4:0] rs1,
                                        logic [2:0] f3, logic [4:0] rd,
                                        logic [6:0] op);
    return {im, rs1, f3, rd, op};
  endfunction

  function automatic logic [31:0] fmt_s(logic [11:0] im, logic [4:0] rs2,
                                        logic [4:0] rs1, logic [2:0] f3,
                                        logic [6:0] op);
    return {im[11:5], rs2, rs1, f3, im[4:0], op};
  endfunction

  function automatic logic [31:0] fmt_r(logic [6:0] f7, logic [4:0] rs2,
                                        logic [4:0] rs1, logic [2:0] f3,
                                        logic [4:0] rd, logic [6:0] op);
    return {f7, rs2, rs1, f3, rd, op};
  endfunction

  function automatic logic [31:0] fmt_b(logic [12:0] off, logic [4:0] rs2,
                                        logic [4:0] rs1, logic [2:0] f3);
    return {off[12], off[10:5], rs2, rs1, f3, off[4:1], off[11], OP_BRANCH};
  endfunction

  function automatic logic [31:0] fmt_j(logic [20:0] off, logic [4:0] rd);
    return {off[20], off[10:1], off[11], off[19:12], rd, OP_JAL};
  endfunction

  // opcode-class selectors (quadrant = instr[1:0], funct3 = instr[15:13])
  logic q0, q1, q2, q3;
  logic [2:0] cf3;
  assign q0  = (instr_i[1:0] == 2'b00);
  assign q1  = (instr_i[1:0] == 2'b01);
  assign q2  = (instr_i[1:0] == 2'b10);
  assign q3  = (instr_i[1:0] == 2'b11);
  assign cf3 = instr_i[15:13];

  // ------------------------------------------------------------------
  // Properties
  // ------------------------------------------------------------------
  always @(posedge clk_i) begin

    // ---- 1. composed illegal-has-no-effect ---------------------------
    // Antecedent: rejected by either half of the pair, or a Zcmp word
    // that the decompressor deliberately does not expand.
    if (c_illegal || c_zcmp || d_illegal) begin
      p_illegal_no_rf:   assert (!rf_we || (rd_addr == 5'd0));   // x0 only
      p_illegal_no_lsu:  assert (!lsu_req);
      p_illegal_no_md:   assert (!md_req);
      p_illegal_no_ctrl: assert (!branch && !jump && !jalr);
      p_illegal_no_csr:  assert (!csr_access && (csr_op == CSR_NONE));
      p_illegal_no_sys:  assert (!ecall && !ebreak && !mret && !wfi &&
                                 !fence && !fencei);
    end

    // The decompressor's own contract for whatever it does not expand:
    // the inert nop, exactly.  This is what makes the x0 allowance
    // above tight -- the only register write a rejected word can ever
    // produce is addi x0,x0,0.
    if (c_illegal || c_zcmp)
      p_rejected_is_nop: assert (exp == NOP);

    // A word is never both a legal Zcmp and illegal.
    p_zcmp_excl_illegal: assert (!(c_zcmp && c_illegal));

    // ---- 2. consistency: legal expansions are accepted downstream -----
    if (!c_illegal) begin
      p_legal_is_32bit:  assert (exp[1:0] == 2'b11);
      p_legal_decodes:   assert (!d_illegal);
    end
    // Stronger and also true: the decoder never rejects anything the
    // decompressor emits, legal or not (rejected words are the nop).
    p_pair_never_decoder_illegal: assert (!d_illegal);

    // ---- quadrant 3 and the all-zero word ------------------------------
    // A halfword with [1:0] == 11 is the low half of a 32-bit
    // instruction, never a compressed one; if_align never consumes the
    // decompressor's result for it, and the RTL flags it anyway.
    p_q3_illegal:   assert (!q3 || c_illegal);
    // The all-zero halfword is a defined illegal encoding (erased flash).
    p_zero_illegal: assert ((instr_i != 16'h0000) || c_illegal);

    // ---- 3. RVC mapping pins, derived from the specification ----------

    // c.addi rd, nzimm   (CI, Q1 funct3=000) -> addi rd, rd, imm
    // rd=x0 is c.nop (imm=0) or a HINT; nzimm=0 with rd!=0 is a HINT.
    // All are required to execute as no-ops, and addi rd,rd,0 / addi
    // x0,x0,imm are exactly that, so the whole row is legal.
    if (q1 && cf3 == 3'b000) begin
      p_map_c_addi:       assert (!c_illegal);
      p_map_c_addi_form:  assert (exp == fmt_i(ci_imm, f_rd, 3'b000, f_rd, OP_OPIMM));
    end

    // c.addi4spn rd', nzuimm  (CIW, Q0 funct3=000) -> addi rd', x2, nzuimm
    // nzuimm == 0 is reserved (and instr==0 is the illegal word).
    if (q0 && cf3 == 3'b000) begin
      if (instr_i[12:5] == 8'b0) begin
        p_map_c_addi4spn_rsv: assert (c_illegal);
      end else begin
        p_map_c_addi4spn:      assert (!c_illegal);
        p_map_c_addi4spn_form: assert (exp == fmt_i(ciw_imm, 5'd2, 3'b000, f_rdp, OP_OPIMM));
      end
    end

    // c.lw rd', uimm(rs1')  (CL, Q0 funct3=010) -> lw rd', uimm(rs1')
    if (q0 && cf3 == 3'b010) begin
      p_map_c_lw:       assert (!c_illegal);
      p_map_c_lw_form:  assert (exp == fmt_i(cl_imm, f_rs1p, 3'b010, f_rdp, OP_LOAD));
    end

    // c.lwsp rd, uimm(x2)  (CI, Q2 funct3=010) -> lw rd, uimm(x2); rd=x0 reserved
    if (q2 && cf3 == 3'b010) begin
      if (f_rd == 5'd0) begin
        p_map_c_lwsp_rsv:  assert (c_illegal);
      end else begin
        p_map_c_lwsp:      assert (!c_illegal);
        p_map_c_lwsp_form: assert (exp == fmt_i(lwsp_imm, 5'd2, 3'b010, f_rd, OP_LOAD));
      end
    end

    // c.swsp rs2, uimm(x2)  (CSS, Q2 funct3=110) -> sw rs2, uimm(x2)
    if (q2 && cf3 == 3'b110) begin
      p_map_c_swsp:      assert (!c_illegal);
      p_map_c_swsp_form: assert (exp == fmt_s(swsp_imm, f_rs2, 5'd2, 3'b010, OP_STORE));
    end

    // c.jal offset  (CJ, Q1 funct3=001, RV32 only) -> jal x1, offset
    if (q1 && cf3 == 3'b001) begin
      p_map_c_jal:       assert (!c_illegal);
      p_map_c_jal_form:  assert (exp == fmt_j(cj_off, 5'd1));
    end

    // c.j offset  (CJ, Q1 funct3=101) -> jal x0, offset
    if (q1 && cf3 == 3'b101) begin
      p_map_c_j:         assert (!c_illegal);
      p_map_c_j_form:    assert (exp == fmt_j(cj_off, 5'd0));
    end

    // c.beqz rs1', offset  (CB, Q1 funct3=110) -> beq rs1', x0, offset
    if (q1 && cf3 == 3'b110) begin
      p_map_c_beqz:      assert (!c_illegal);
      p_map_c_beqz_form: assert (exp == fmt_b(cb_off, 5'd0, f_rs1p, 3'b000));
    end

    // c.jr rs1  (CR, Q2 funct4=1000, rs2=0) -> jalr x0, 0(rs1); rs1=x0 reserved
    if (q2 && cf3 == 3'b100 && !instr_i[12] && f_rs2 == 5'd0) begin
      if (f_rd == 5'd0) begin
        p_map_c_jr_rsv:  assert (c_illegal);
      end else begin
        p_map_c_jr:      assert (!c_illegal);
        p_map_c_jr_form: assert (exp == fmt_i(12'b0, f_rd, 3'b000, 5'd0, OP_JALR));
      end
    end

    // c.ebreak  (CR, Q2 funct4=1001, rd=0, rs2=0: 16'h9002) -> ebreak
    if (instr_i == 16'h9002) begin
      p_map_c_ebreak:      assert (!c_illegal);
      p_map_c_ebreak_form: assert (exp == 32'h0010_0073);
      p_map_c_ebreak_dec:  assert (ebreak);   // and the decoder sees it as one
    end

    // Zcb c.lbu rd', uimm(rs1')  (CLB, Q0 funct6=100000)
    //   uimm[0] = instr[6], uimm[1] = instr[5]  -> lbu rd', uimm(rs1')
    if (q0 && instr_i[15:10] == 6'b100000) begin
      p_map_c_lbu:       assert (!c_illegal);
      p_map_c_lbu_form:  assert (exp == fmt_i({10'b0, instr_i[5], instr_i[6]},
                                              f_rs1p, 3'b100, f_rdp, OP_LOAD));
    end

    // Zcb c.not rd'/rs1'  (Q1 funct6=100111, [6:5]=11, [4:2]=101)
    //   -> xori rd', rd', -1
    if (q1 && instr_i[15:10] == 6'b100111 && instr_i[6:2] == 5'b11101) begin
      p_map_c_not:       assert (!c_illegal);
      p_map_c_not_form:  assert (exp == fmt_i(12'hfff, f_rs1p, 3'b100, f_rs1p, OP_OPIMM));
    end

    // Zcb c.sext.b rd'/rs1'  (Q1 funct6=100111, [6:5]=11, [4:2]=001)
    //   -> sext.b rd', rd'  = OP-IMM funct3=001, imm[11:0] = 0110000_00100
    if (q1 && instr_i[15:10] == 6'b100111 && instr_i[6:2] == 5'b11001) begin
      p_map_c_sext_b:      assert (!c_illegal);
      p_map_c_sext_b_form: assert (exp == fmt_r(7'b0110000, 5'b00100, f_rs1p,
                                                3'b001, f_rs1p, OP_OPIMM));
    end

    // Zcb c.mul rd'/rs1', rs2'  (Q1 funct6=100111, [6:5]=10)
    //   -> mul rd', rd', rs2'  (funct7 = 0000001)
    if (q1 && instr_i[15:10] == 6'b100111 && instr_i[6:5] == 2'b10) begin
      p_map_c_mul:       assert (!c_illegal);
      p_map_c_mul_form:  assert (exp == fmt_r(7'b0000001, f_rdp, f_rs1p,
                                              3'b000, f_rs1p, OP_OP));
      p_map_c_mul_dec:   assert (md_req);     // and the decoder routes it to M
    end

    // Zcb c.zext.w (Q1 funct6=100111, [6:2]=11100) is RV64-only: reserved
    // on RV32 and must trap.
    if (q1 && instr_i[15:10] == 6'b100111 && instr_i[6:2] == 5'b11100)
      p_map_c_zext_w_rsv: assert (c_illegal);

    // RV64-only shamt[5] on c.slli / c.srli / c.srai must trap on RV32.
    if (q2 && cf3 == 3'b000 && instr_i[12])
      p_map_c_slli_rv64_rsv: assert (c_illegal);
    if (q1 && cf3 == 3'b100 && instr_i[11] == 1'b0 && instr_i[12])
      p_map_c_srxi_rv64_rsv: assert (c_illegal);
  end

endmodule

`default_nettype wire
