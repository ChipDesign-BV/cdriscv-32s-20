// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// Illegal state recovery, on the gate level netlist.
//
// Coverage waiver W2a keeps the `default:` arms of the state machines
// on the grounds that they are unreachable in simulation but are what
// returns the machine to a defined state after an upset.  That argument
// is made against the RTL, and the waiver itself says it has to be
// re-made against the netlist, because synthesis is entitled to notice
// that a state is unreachable and optimise the recovery away.
//
// This is that check.  The multiplier's three states are encoded in two
// flip-flops, so exactly one encoding is unused.  The netlist is forced
// into each of the four encodings in turn and clocked once; every one
// of them must lead to a defined state, and the unused one must lead
// back to idle rather than to X or to a lock-up.
//
// If synthesis had dropped the recovery, the unused encoding would
// either hold or produce X here, and W2a would be false at gate level.
//
// The post-recovery functional proof is a DIVIDE.  This module is the
// divider only: variant 2 routes every multiply to the single-cycle
// cdriscv_32s_20_mult (finding 17, commit 2ecf4b2), and the divider's
// structural contract is that a multiply encoding never reaches
// req_i -- its result mux answers one with a defensive 0, and the
// contract check that would say so is `ifndef SYNTHESIS`, so on gates
// it is silent.  The bench inherited from cdriscv-32s-10 asked for
// 7*6 and read that silent 0 as a failed recovery; it was never the
// recovery.  operator is the full md_op_e width so nothing is
// zero-extended into a multiply encoding by accident.

`default_nettype none
`timescale 1ns/1ps

module tb_gate_fsm;

  logic clk = 0, rst_n;
  always #5ns clk = ~clk;

  logic        req, kill;
  logic [31:0] a, b;
  logic [2:0]  operator;   // md_op_e width: bit 2 set selects a divide
  logic        valid, busy;
  logic [31:0] result;

  cdriscv_32s_20_multdiv u_dut (
      .clk_i        (clk),
      .rst_ni       (rst_n),
      .req_i        (req),
      .operator_i   (operator),
      .operand_a_i  (a),
      .operand_b_i  (b),
      .kill_i       (kill),
      .busy_o       (busy),
      .valid_o      (valid),
      .result_o     (result)
  );

  int errors = 0;
  logic [1:0] seen [4];

  // A static task, not automatic: Icarus refuses to use an
  // automatically allocated variable in a procedural force.
  logic [1:0] enc;
  task try_state;
    // Drive the state register to `enc`, let the netlist compute its
    // next state from it, then let go and look at where it went.
    force u_dut.state_q = enc;
    @(posedge clk);
    #1ns;
    release u_dut.state_q;
    #1ns;
    seen[enc] = u_dut.state_q;
    if (u_dut.state_q === 2'bxx) begin
      $display("[tb_gate_fsm] FAIL: encoding %02b led to X", enc);
      errors++;
    end else begin
      $display("[tb_gate_fsm] encoding %02b -> %02b", enc, u_dut.state_q);
    end
  endtask

  initial begin
    rst_n = 0; req = 0; kill = 0; a = 0; b = 0; operator = 0;
    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (5) @(posedge clk);
    $display("[tb_gate_fsm] reset state = %02b", u_dut.state_q);

    for (int e = 0; e < 4; e++) begin
      rst_n = 0; repeat (2) @(posedge clk); rst_n = 1; repeat (2) @(posedge clk);
      enc = 2'(e);
      try_state;
    end

    // After visiting every encoding the netlist must still work.  A
    // recovery that leaves the machine in a defined but wrong state
    // would pass the checks above and fail here.
    rst_n = 0; repeat (2) @(posedge clk); rst_n = 1; repeat (2) @(posedge clk);
    force u_dut.state_q = 2'b11;
    @(posedge clk);
    #1ns;
    release u_dut.state_q;
    repeat (4) @(posedge clk);
    // 42 / 6 = 7, unsigned: the operation this divider implements.
    a = 32'd42; b = 32'd6; operator = cdriscv_32s_20_pkg::MD_DIVU; req = 1'b1;
    @(posedge clk);
    req = 1'b0;
    fork
      begin while (!valid) @(posedge clk); end
      begin repeat (200) @(posedge clk); end
    join_any
    if (!valid || result !== 32'd7) begin
      $display("[tb_gate_fsm] FAIL: after an illegal state, 42/6 gave %0d (valid=%0b)",
               result, valid);
      errors++;
    end else begin
      $display("[tb_gate_fsm] recovered: 42/6 = %0d", result);
    end

    if (errors == 0) $display("[tb_gate_fsm] PASS: every state encoding leads to a defined state");
    else             $display("[tb_gate_fsm] FAIL: %0d problems", errors);
    $finish;
  end

  initial begin
    #1ms;
    $display("[tb_gate_fsm] FAIL: timeout");
    $finish;
  end

endmodule
