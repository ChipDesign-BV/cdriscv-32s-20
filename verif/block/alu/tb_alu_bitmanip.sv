// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s-10 v2 -- ALU block bench (base + Zba + Zbb + Zbs).
//
// The reference model below is written INDEPENDENTLY of the DUT: where
// the DUT uses a reduction tree the reference uses a loop, where the DUT
// uses (5'd0 - shamt) the reference uses concatenation, and so on.  A
// reference that restates the implementation proves only that the file
// was copied correctly.
//
// Stimulus is directed corner cases crossed with random vectors, for
// every operation.

`timescale 1ns/1ps

module tb_alu_bitmanip
  import cdriscv_32s_20_pkg::*;
;

  alu_op_e     op;
  logic [31:0] a, b, dut_y, ref_y;
  int          checks = 0, errors = 0;

  cdriscv_32s_20_alu u_dut (.operator_i(op), .operand_a_i(a), .operand_b_i(b),
                        .result_o(dut_y));

  // ---- independent reference ----------------------------------------
  function automatic logic [31:0] refmodel(alu_op_e o,
                                           logic [31:0] x, logic [31:0] y);
    logic [4:0]  sh;
    logic [31:0] r;
    int          n;
    sh = y[4:0];
    r  = 32'b0;
    case (o)
      ALU_ADD   : r = x + y;
      ALU_SUB   : r = x - y;
      ALU_SLL   : r = x << sh;
      ALU_SRL   : r = x >> sh;
      ALU_SRA   : r = $unsigned($signed(x) >>> sh);
      ALU_XOR   : r = x ^ y;
      ALU_OR    : r = x | y;
      ALU_AND   : r = x & y;
      ALU_SLT   : r = {31'b0, ($signed(x) < $signed(y))};
      ALU_SLTU  : r = {31'b0, (x < y)};
      ALU_EQ    : r = {31'b0, (x == y)};
      ALU_NE    : r = {31'b0, (x != y)};
      ALU_GE    : r = {31'b0, ($signed(x) >= $signed(y))};
      ALU_GEU   : r = {31'b0, (x >= y)};
      ALU_PASSB : r = y;
      // Zba -- reference multiplies rather than shifts
      ALU_SH1ADD: r = x * 2 + y;
      ALU_SH2ADD: r = x * 4 + y;
      ALU_SH3ADD: r = x * 8 + y;
      // Zbb
      ALU_ANDN  : r = x & ~y;
      ALU_ORN   : r = x | ~y;
      ALU_XNOR  : r = ~(x ^ y);
      ALU_CLZ   : begin n = 0;
                    for (int i = 31; i >= 0; i--)
                      if (x[i]) break; else n++;
                    r = n; end
      ALU_CTZ   : begin n = 0;
                    for (int i = 0; i < 32; i++)
                      if (x[i]) break; else n++;
                    r = n; end
      ALU_CPOP  : begin n = 0;
                    for (int i = 0; i < 32; i++) if (x[i]) n++;
                    r = n; end
      ALU_MAX   : r = ($signed(x) > $signed(y)) ? x : y;
      ALU_MAXU  : r = (x > y) ? x : y;
      ALU_MIN   : r = ($signed(x) < $signed(y)) ? x : y;
      ALU_MINU  : r = (x < y) ? x : y;
      ALU_SEXTB : r = {{24{x[7]}},  x[7:0]};
      ALU_SEXTH : r = {{16{x[15]}}, x[15:0]};
      ALU_ZEXTH : r = {16'b0, x[15:0]};
      // rotate reference: build by concatenation, not arithmetic
      // Reference rotates built bit-by-bit -- deliberately the least
      // clever formulation available, and independent of the DUT's.
      ALU_ROL   : begin
                    for (int i = 0; i < 32; i++) r[(i + sh) % 32] = x[i];
                  end
      ALU_ROR   : begin
                    for (int i = 0; i < 32; i++) r[i] = x[(i + sh) % 32];
                  end
      ALU_ORCB  : begin
                    for (int i = 0; i < 4; i++)
                      r[8*i +: 8] = (x[8*i +: 8] != 8'h00) ? 8'hff : 8'h00;
                  end
      ALU_REV8  : r = {x[7:0], x[15:8], x[23:16], x[31:24]};
      // Zbs -- reference uses a shifted one built by loop
      ALU_BCLR  : begin r = x; r[sh] = 1'b0; end
      ALU_BEXT  : r = {31'b0, x[sh]};
      ALU_BINV  : begin r = x; r[sh] = ~x[sh]; end
      ALU_BSET  : begin r = x; r[sh] = 1'b1; end
      default   : r = 32'b0;
    endcase
    return r;
  endfunction

  task automatic check(alu_op_e o, logic [31:0] x, logic [31:0] y);
    op = o; a = x; b = y;
    #1;
    ref_y = refmodel(o, x, y);
    checks++;
    if (dut_y !== ref_y) begin
      errors++;
      if (errors <= 15)
        $display("[MISMATCH] op=%0s a=%08x b=%08x dut=%08x ref=%08x",
                 o.name(), x, y, dut_y, ref_y);
    end
  endtask

  alu_op_e ops [39] = '{ALU_ADD, ALU_SUB, ALU_SLL, ALU_SLT, ALU_SLTU, ALU_XOR,
    ALU_SRL, ALU_SRA, ALU_OR, ALU_AND, ALU_EQ, ALU_NE, ALU_GE, ALU_GEU,
    ALU_PASSB, ALU_SH1ADD, ALU_SH2ADD, ALU_SH3ADD, ALU_ANDN, ALU_ORN,
    ALU_XNOR, ALU_CLZ, ALU_CTZ, ALU_CPOP, ALU_MAX, ALU_MAXU, ALU_MIN,
    ALU_MINU, ALU_SEXTB, ALU_SEXTH, ALU_ZEXTH, ALU_ROL, ALU_ROR,
    ALU_ORCB, ALU_REV8, ALU_BCLR, ALU_BEXT, ALU_BINV, ALU_BSET};

  logic [31:0] corners [13] = '{32'h0000_0000, 32'hffff_ffff, 32'h8000_0000,
    32'h7fff_ffff, 32'h0000_0001, 32'h0000_00ff, 32'hff00_ff00,
    32'h0000_8000, 32'h0001_0000, 32'haaaa_aaaa, 32'h5555_5555,
    32'h0000_001f, 32'h0000_0020};

  initial begin
    // directed: every op over the full corner cross-product
    foreach (ops[o])
      foreach (corners[i])
        foreach (corners[j])
          check(ops[o], corners[i], corners[j]);

    // random
    foreach (ops[o])
      for (int k = 0; k < 3000; k++)
        check(ops[o], $urandom, $urandom);

    // shift/rotate/bit ops deserve every shift amount explicitly
    foreach (ops[o])
      if (ops[o] == ALU_SLL  || ops[o] == ALU_SRL  || ops[o] == ALU_SRA ||
          ops[o] == ALU_ROL  || ops[o] == ALU_ROR  || ops[o] == ALU_BCLR||
          ops[o] == ALU_BEXT || ops[o] == ALU_BINV || ops[o] == ALU_BSET)
        for (int s = 0; s < 32; s++)
          for (int k = 0; k < 40; k++)
            check(ops[o], $urandom, s);

    $display("[tb_alu_bitmanip] %0d checks, %0d mismatches", checks, errors);
    $display("[tb_alu_bitmanip] %s", errors == 0 ? "PASS" : "FAIL");
    $finish;
  end
endmodule
