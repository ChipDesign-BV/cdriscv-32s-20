// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s-20 -- Zcmp sequence table: exhaustive dump.
//
// Same philosophy as tb_decompress: this bench does not judge, it
// enumerates.  Every halfword the decompressor flags as Zcmp has its
// complete micro-operation sequence walked step by step and written
// out; scripts/check_zcmp.py then replays each dumped sequence against
// a Spike commit log built from binutils-assembled cm.* mnemonics, so
// the register list, the offsets, the stack adjustment, the a0 zeroing
// and the return are all checked against an implementation that is not
// ours.  Writing the rlist/adjustment arithmetic a second time in this
// bench would only prove the same misreading twice.
//
// The decompressor provides the flag so that the dumped set is exactly
// the set the core would sequence -- if the flag and the table ever
// disagreed on scope, that too would show up against the reference
// (an extra or missing encoding in the dump).

`timescale 1ns/1ps

module tb_zcmp;

  logic [15:0] c;
  logic [31:0] x;
  logic        ill, zcmp;

  logic [3:0]  step;
  logic        mem, we, azero, wb, last, ret;
  logic [4:0]  rs1, rs2, rd;
  logic [31:0] imm;

  integer      fd, nseq, nstep;

  cdriscv_32s_20_decompress u_flag (
      .instr_i   (c),
      .instr_o   (x),
      .illegal_o (ill),
      .zcmp_o    (zcmp)
  );

  cdriscv_32s_20_zcmp u_dut (
      .instr_i     (c),
      .step_i      (step),
      .mem_o       (mem),
      .we_o        (we),
      .rs1_o       (rs1),
      .rs2_o       (rs2),
      .rd_o        (rd),
      .imm_o       (imm),
      .op_a_zero_o (azero),
      .wb_o        (wb),
      .last_o      (last),
      .ret_o       (ret)
  );

  initial begin
    fd    = $fopen("build/zcmp_dump.txt", "w");
    nseq  = 0;
    nstep = 0;
    for (int unsigned i = 0; i < 65536; i++) begin
      c    = 16'(i);
      step = 4'd0;
      #1;
      if (zcmp) begin
        nseq++;
        // walk to the last step; 16 is a hard cap so a table that
        // never raises last_o cannot hang the bench
        for (int unsigned k = 0; k < 16; k++) begin
          step = 4'(k);
          #1;
          $fdisplay(fd, "%04x %0d %0d %0d %0d %0d %0d %08x %0d %0d %0d %0d",
                    c, k, mem, we, rs1, rs2, rd, imm, azero, wb, last, ret);
          nstep++;
          if (last) break;
        end
        if (!last) begin
          $display("[tb_zcmp] FAIL: %04x never raised last_o", c);
          $fatal(1);
        end
      end
    end
    $fclose(fd);
    $display("[tb_zcmp] dumped %0d sequences, %0d steps", nseq, nstep);
    $finish;
  end

endmodule
