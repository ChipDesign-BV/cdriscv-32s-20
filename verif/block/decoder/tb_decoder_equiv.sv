// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// Equivalence bench for cdriscv_32s_20_decoder against cdriscv_decoder.
//
// Variant 1 is signed off, so the property that matters is not "does
// the new decoder decode bitmanip" -- it is "does adding bitmanip leave
// the base ISA untouched".  A decoder that quietly changed one
// immediate or one rs2_used bit would be caught by nothing here until a
// program misbehaved, so the two decoders are instantiated side by side
// and compared field by field:
//
//   1. variant 1 legal  -> variant 2 must produce an identical control
//                          word, all 24 fields
//   2. variant 1 illegal, variant 2 legal
//                       -> the encoding must be one of the 27 bitmanip
//                          ones AND carry the ALU operator this bench
//                          independently expects
//   3. variant 1 illegal, variant 2 illegal  -> agreed
//
// The bitmanip table below is written from the Zba/Zbb/Zbs encoding
// tables, not from the DUT.  It is the only part of this bench that
// restates something the DUT also knows, and it exists precisely so
// that over-acceptance -- variant 2 calling something legal that is
// neither base nor bitmanip -- is a failure rather than a silent pass.
//
// Stimulus is a directed sweep over every funct7/funct3/rs2 combination
// of OP and OP-IMM (where all the new encodings live and where a
// collision with the base ISA would happen), every opcode, and then
// several million random words.

`default_nettype none
`timescale 1ns/1ps

module tb_decoder_equiv;

  logic [31:0] instr;

  // ---------------- variant 1 (reference) ----------------
  logic [4:0]  a_rs1, a_rs2, a_rd;
  logic        a_rf_we, a_rs1_used, a_rs2_used;
  logic [3:0]  a_alu_op;
  logic [1:0]  a_op_a, a_op_b, a_wb;
  logic [31:0] a_imm;
  logic        a_md_req;
  logic [2:0]  a_md_op;
  logic        a_lsu_req, a_lsu_we, a_lsu_sx;
  logic [1:0]  a_lsu_size;
  logic        a_branch, a_jump, a_jalr;
  logic        a_csr_acc, a_csr_imm;
  logic [1:0]  a_csr_op;
  logic [11:0] a_csr_addr;
  logic        a_ecall, a_ebreak, a_mret, a_wfi, a_fence, a_fencei, a_illegal;

  cdriscv_decoder u_v1 (
      .instr_i(instr),
      .rs1_addr_o(a_rs1), .rs2_addr_o(a_rs2), .rd_addr_o(a_rd),
      .rf_we_o(a_rf_we), .rs1_used_o(a_rs1_used), .rs2_used_o(a_rs2_used),
      .alu_op_o(a_alu_op), .op_a_sel_o(a_op_a), .op_b_sel_o(a_op_b),
      .imm_o(a_imm), .wb_sel_o(a_wb),
      .md_req_o(a_md_req), .md_op_o(a_md_op),
      .lsu_req_o(a_lsu_req), .lsu_we_o(a_lsu_we),
      .lsu_size_o(a_lsu_size), .lsu_sign_ext_o(a_lsu_sx),
      .branch_o(a_branch), .jump_o(a_jump), .jalr_o(a_jalr),
      .csr_access_o(a_csr_acc), .csr_op_o(a_csr_op),
      .csr_addr_o(a_csr_addr), .csr_imm_o(a_csr_imm),
      .ecall_o(a_ecall), .ebreak_o(a_ebreak), .mret_o(a_mret),
      .wfi_o(a_wfi), .fence_o(a_fence), .fencei_o(a_fencei),
      .illegal_instr_o(a_illegal)
  );

  // ---------------- variant 2 (DUT) ----------------
  logic [4:0]  b_rs1, b_rs2, b_rd;
  logic        b_rf_we, b_rs1_used, b_rs2_used;
  logic [5:0]  b_alu_op;
  logic [1:0]  b_op_a, b_op_b, b_wb;
  logic [31:0] b_imm;
  logic        b_md_req;
  logic [2:0]  b_md_op;
  logic        b_lsu_req, b_lsu_we, b_lsu_sx;
  logic [1:0]  b_lsu_size;
  logic        b_branch, b_jump, b_jalr;
  logic        b_csr_acc, b_csr_imm;
  logic [1:0]  b_csr_op;
  logic [11:0] b_csr_addr;
  logic        b_ecall, b_ebreak, b_mret, b_wfi, b_fence, b_fencei, b_illegal;

  cdriscv_32s_20_decoder u_v2 (
      .instr_i(instr),
      .rs1_addr_o(b_rs1), .rs2_addr_o(b_rs2), .rd_addr_o(b_rd),
      .rf_we_o(b_rf_we), .rs1_used_o(b_rs1_used), .rs2_used_o(b_rs2_used),
      .alu_op_o(b_alu_op), .op_a_sel_o(b_op_a), .op_b_sel_o(b_op_b),
      .imm_o(b_imm), .wb_sel_o(b_wb),
      .md_req_o(b_md_req), .md_op_o(b_md_op),
      .lsu_req_o(b_lsu_req), .lsu_we_o(b_lsu_we),
      .lsu_size_o(b_lsu_size), .lsu_sign_ext_o(b_lsu_sx),
      .branch_o(b_branch), .jump_o(b_jump), .jalr_o(b_jalr),
      .csr_access_o(b_csr_acc), .csr_op_o(b_csr_op),
      .csr_addr_o(b_csr_addr), .csr_imm_o(b_csr_imm),
      .ecall_o(b_ecall), .ebreak_o(b_ebreak), .mret_o(b_mret),
      .wfi_o(b_wfi), .fence_o(b_fence), .fencei_o(b_fencei),
      .illegal_instr_o(b_illegal)
  );

  // ------------------------------------------------------------------
  // Independent bitmanip encoding table.  Returns the expected ALU
  // operator, or -1 when the encoding is not a Zba/Zbb/Zbs one.
  // ------------------------------------------------------------------
  function automatic integer exp_bm(input logic [31:0] w);
    logic [6:0] op, f7;
    logic [2:0] f3;
    logic [4:0] r2;
    begin
      op = w[6:0]; f7 = w[31:25]; f3 = w[14:12]; r2 = w[24:20];
      exp_bm = -1;

      if (op == 7'h33) begin                       // OP
        if (f7 == 7'b0010000 && f3 == 3'b010) exp_bm = 16;  // sh1add
        if (f7 == 7'b0010000 && f3 == 3'b100) exp_bm = 17;  // sh2add
        if (f7 == 7'b0010000 && f3 == 3'b110) exp_bm = 18;  // sh3add
        if (f7 == 7'b0100000 && f3 == 3'b111) exp_bm = 20;  // andn
        if (f7 == 7'b0100000 && f3 == 3'b110) exp_bm = 21;  // orn
        if (f7 == 7'b0100000 && f3 == 3'b100) exp_bm = 22;  // xnor
        if (f7 == 7'b0000101 && f3 == 3'b110) exp_bm = 26;  // max
        if (f7 == 7'b0000101 && f3 == 3'b111) exp_bm = 27;  // maxu
        if (f7 == 7'b0000101 && f3 == 3'b100) exp_bm = 28;  // min
        if (f7 == 7'b0000101 && f3 == 3'b101) exp_bm = 29;  // minu
        if (f7 == 7'b0110000 && f3 == 3'b001) exp_bm = 33;  // rol
        if (f7 == 7'b0110000 && f3 == 3'b101) exp_bm = 34;  // ror
        if (f7 == 7'b0000100 && f3 == 3'b100 && r2 == 5'b00000) exp_bm = 32; // zext.h
        if (f7 == 7'b0010100 && f3 == 3'b001) exp_bm = 43;  // bset
        if (f7 == 7'b0100100 && f3 == 3'b001) exp_bm = 40;  // bclr
        if (f7 == 7'b0110100 && f3 == 3'b001) exp_bm = 42;  // binv
        if (f7 == 7'b0100100 && f3 == 3'b101) exp_bm = 41;  // bext
      end else if (op == 7'h13) begin              // OP-IMM
        if (f3 == 3'b001) begin
          if (f7 == 7'b0010100) exp_bm = 43;                // bseti
          if (f7 == 7'b0100100) exp_bm = 40;                // bclri
          if (f7 == 7'b0110100) exp_bm = 42;                // binvi
          if (f7 == 7'b0110000) begin
            if (r2 == 5'b00000) exp_bm = 23;                // clz
            if (r2 == 5'b00001) exp_bm = 24;                // ctz
            if (r2 == 5'b00010) exp_bm = 25;                // cpop
            if (r2 == 5'b00100) exp_bm = 30;                // sext.b
            if (r2 == 5'b00101) exp_bm = 31;                // sext.h
          end
        end else if (f3 == 3'b101) begin
          if (f7 == 7'b0100100) exp_bm = 41;                // bexti
          if (f7 == 7'b0110000) exp_bm = 34;                // rori
          if (f7 == 7'b0010100 && r2 == 5'b00111) exp_bm = 35; // orc.b
          if (f7 == 7'b0110100 && r2 == 5'b11000) exp_bm = 36; // rev8
        end
      end
    end
  endfunction

  // ------------------------------------------------------------------
  // Checking
  // ------------------------------------------------------------------
  integer checks, errors, n_base, n_bm, n_both_illegal;
  integer seed, i, j, k, m, bm;
  integer niter;
  logic   base_mismatch;

  task automatic check_one;
    begin
      #1;
      checks = checks + 1;
      bm     = exp_bm(instr);

      if (!a_illegal) begin
        // --- variant 1 legal: variant 2 must agree on everything ---
        n_base = n_base + 1;
        base_mismatch =
             (b_illegal   !== 1'b0)
          || (b_rs1       !== a_rs1)      || (b_rs2      !== a_rs2)
          || (b_rd        !== a_rd)       || (b_rf_we    !== a_rf_we)
          || (b_rs1_used  !== a_rs1_used) || (b_rs2_used !== a_rs2_used)
          || (b_alu_op    !== {2'b00, a_alu_op})
          || (b_op_a      !== a_op_a)     || (b_op_b     !== a_op_b)
          || (b_imm       !== a_imm)      || (b_wb       !== a_wb)
          || (b_md_req    !== a_md_req)   || (b_md_op    !== a_md_op)
          || (b_lsu_req   !== a_lsu_req)  || (b_lsu_we   !== a_lsu_we)
          || (b_lsu_size  !== a_lsu_size) || (b_lsu_sx   !== a_lsu_sx)
          || (b_branch    !== a_branch)   || (b_jump     !== a_jump)
          || (b_jalr      !== a_jalr)     || (b_csr_acc  !== a_csr_acc)
          || (b_csr_op    !== a_csr_op)   || (b_csr_addr !== a_csr_addr)
          || (b_csr_imm   !== a_csr_imm)  || (b_ecall    !== a_ecall)
          || (b_ebreak    !== a_ebreak)   || (b_mret     !== a_mret)
          || (b_wfi       !== a_wfi)      || (b_fence    !== a_fence)
          || (b_fencei    !== a_fencei);
        if (base_mismatch) begin
          if (errors < 10)
            $display("[FAIL] %08x base decode differs: v1 alu=%0d imm=%08x rf_we=%0d rs2u=%0d | v2 alu=%0d imm=%08x rf_we=%0d rs2u=%0d ill=%0d",
                     instr, a_alu_op, a_imm, a_rf_we, a_rs2_used,
                     b_alu_op, b_imm, b_rf_we, b_rs2_used, b_illegal);
          errors = errors + 1;
        end
      end else if (!b_illegal) begin
        // --- variant 2 accepts what variant 1 rejected ---
        if (bm < 0) begin
          if (errors < 10)
            $display("[FAIL] %08x accepted by v2 but is not a bitmanip encoding (alu=%0d)",
                     instr, b_alu_op);
          errors = errors + 1;
        end else if (b_alu_op !== bm[5:0]) begin
          if (errors < 10)
            $display("[FAIL] %08x bitmanip alu op: got %0d want %0d",
                     instr, b_alu_op, bm);
          errors = errors + 1;
        end else begin
          n_bm = n_bm + 1;
          // the new ops must write a register from the ALU
          if (!b_rf_we || b_wb !== 2'd0) begin
            if (errors < 10)
              $display("[FAIL] %08x bitmanip control: rf_we=%0d wb=%0d",
                       instr, b_rf_we, b_wb);
            errors = errors + 1;
          end
        end
      end else begin
        // --- both reject ---
        n_both_illegal = n_both_illegal + 1;
        if (bm >= 0) begin
          if (errors < 10)
            $display("[FAIL] %08x is bitmanip %0d but v2 rejected it", instr, bm);
          errors = errors + 1;
        end
      end
    end
  endtask

  initial begin
    seed = 32'h0dec_0de1;
    // Mutation runs pass +niter to keep each one short; the directed
    // sweeps below are exhaustive over OP/OP-IMM either way.
    niter = 3000000;
    void'($value$plusargs("niter=%d", niter));
    checks = 0; errors = 0; n_base = 0; n_bm = 0; n_both_illegal = 0;

    // 1. Every funct7 x funct3 x rs2 of OP and OP-IMM -- this is where
    //    the new encodings live and where a collision would happen.
    for (j = 0; j < 128; j = j + 1)
      for (k = 0; k < 8; k = k + 1)
        for (m = 0; m < 32; m = m + 1) begin
          instr = {j[6:0], m[4:0], 5'd7, k[2:0], 5'd9, 7'h33};
          check_one();
          instr = {j[6:0], m[4:0], 5'd7, k[2:0], 5'd9, 7'h13};
          check_one();
        end

    // 2. Every opcode, a spread of funct3/funct7
    for (j = 0; j < 128; j = j + 1)
      for (k = 0; k < 8; k = k + 1)
        for (m = 0; m < 8; m = m + 1) begin
          instr = {m[2:0], 4'd0, 5'd3, 5'd7, k[2:0], 5'd9, j[6:0]};
          check_one();
        end

    // 3. Random words
    for (i = 0; i < niter; i = i + 1) begin
      instr = $random(seed);
      check_one();
    end

    $display("[tb_decoder_equiv] %0d checks, %0d mismatches", checks, errors);
    $display("[tb_decoder_equiv]   %0d base-legal (compared field by field), %0d bitmanip, %0d both illegal",
             n_base, n_bm, n_both_illegal);
    if (n_base < 10000 || n_bm < 600) begin
      $display("[tb_decoder_equiv] FAIL -- a required class is under-exercised");
      $finish;
    end
    if (errors == 0) $display("[tb_decoder_equiv] PASS");
    else             $display("[tb_decoder_equiv] FAIL");
    $finish;
  end

endmodule

`default_nettype wire
