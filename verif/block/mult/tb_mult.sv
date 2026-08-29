// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s v2 -- fast multiplier block bench.
//
// The DUT computes one 33x33 signed product and slices it.  The
// reference below computes each of the four M-extension multiplies
// separately with its own explicit widening, so a mistake in the
// sign-extension logic of the DUT cannot be mirrored by the reference.
//
// The signedness corner cases are where this instruction family goes
// wrong, so 0x80000000 (the value that is its own negation) appears in
// the directed set against everything else.

`timescale 1ns/1ps

module tb_mult
  import cdriscv_32s_20_pkg::*;
;

  md_op_e      op;
  logic [31:0] a, b, dut_y, ref_y;
  int          checks = 0, errors = 0;

  cdriscv_32s_20_mult u_dut (.operator_i(op), .operand_a_i(a), .operand_b_i(b),
                         .result_o(dut_y));

  function automatic logic [31:0] refmodel(md_op_e o,
                                           logic [31:0] x, logic [31:0] y);
    logic signed [63:0] ss;
    logic        [63:0] uu;
    logic signed [63:0] su;
    case (o)
      MD_MUL    : begin ss = $signed(x) * $signed(y);      return ss[31:0];  end
      MD_MULH   : begin ss = 64'($signed(x)) * 64'($signed(y)); return ss[63:32]; end
      MD_MULHU  : begin uu = 64'(x) * 64'(y);              return uu[63:32]; end
      MD_MULHSU : begin su = 64'($signed(x)) * $signed({1'b0, y});
                        return su[63:32]; end
      default   : return 32'b0;
    endcase
  endfunction

  task automatic check(md_op_e o, logic [31:0] x, logic [31:0] y);
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

  md_op_e      ops [4]     = '{MD_MUL, MD_MULH, MD_MULHSU, MD_MULHU};
  logic [31:0] corners [12] = '{32'h0000_0000, 32'h0000_0001, 32'hffff_ffff,
    32'h8000_0000, 32'h7fff_ffff, 32'h0000_ffff, 32'hffff_0000,
    32'h0001_0000, 32'h8000_0001, 32'h5555_5555, 32'haaaa_aaaa,
    32'h0000_0002};

  initial begin
    foreach (ops[o])
      foreach (corners[i])
        foreach (corners[j])
          check(ops[o], corners[i], corners[j]);

    foreach (ops[o])
      for (int k = 0; k < 20000; k++)
        check(ops[o], $urandom, $urandom);

    // small values, where sign handling is easiest to get subtly wrong
    foreach (ops[o])
      for (int i = -4; i <= 4; i++)
        for (int j = -4; j <= 4; j++)
          check(ops[o], 32'(i), 32'(j));

    $display("[tb_mult] %0d checks, %0d mismatches", checks, errors);
    $display("[tb_mult] %s", errors == 0 ? "PASS" : "FAIL");
    $finish;
  end
endmodule
