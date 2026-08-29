// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s v2 -- Zca/Zcb decompressor: exhaustive dump.
//
// This bench does not judge; it enumerates.  All 65 536 halfwords are
// pushed through the DUT and the (input, expansion, illegal) triple is
// written out for scripts/check_decompress.py to compare against
// binutils.
//
// Writing a second decode table in SystemVerilog and calling it a
// reference would prove only that the same misreading of the RVC
// immediate tables had been made twice.  binutils is an independent
// implementation, and it disassembles BOTH the compressed input and the
// 32-bit expansion, so the immediate and register extraction on each
// side comes from outside this repository.

`timescale 1ns/1ps

module tb_decompress;

  logic [15:0] c;
  logic [31:0] x;
  logic        ill;
  integer      fd;

  cdriscv_32s_20_decompress u_dut (.instr_i(c), .instr_o(x), .illegal_o(ill));

  initial begin
    fd = $fopen("build/decompress_dump.txt", "w");
    for (int unsigned i = 0; i < 65536; i++) begin
      c = 16'(i);
      #1;
      $fdisplay(fd, "%04x %08x %0d", c, x, ill);
    end
    $fclose(fd);
    $display("[tb_decompress] dumped 65536 encodings");
    $finish;
  end
endmodule
