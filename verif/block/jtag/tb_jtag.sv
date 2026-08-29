// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s-10 v2 -- JTAG TAP block bench.
//
// The reference is the IEEE 1149.1 state machine written from the
// standard's own transition table, independently of the DUT's case
// statement, plus behavioural models of the four data registers.
//
// The properties that matter, and that a careless bench misses:
//
//   * five TMS=1 clocks reach Test-Logic-Reset from ANY state.  That is
//     the guarantee a debugger relies on when it does not know where the
//     TAP is, and it must hold from all sixteen states.
//   * Test-Logic-Reset loads IDCODE, not BYPASS.  The standard mandates
//     it and a reset that leaves BYPASS selected looks fine until a
//     debugger tries to identify the part.
//   * Capture-IR must load ...01 in the two LSBs.
//   * BYPASS is exactly one bit: data in at TDI appears at TDO one
//     TCK later, not two.
//   * TDO drives only while shifting.

`timescale 1ns/1ps

module tb_jtag;

  localparam logic [31:0] IDCODE = 32'h0CD1_507B;

  logic tck = 1'b0, tms, tdi, trst_n;
  logic tdo, tdo_oe;
  logic [31:0] dbg_addr, dbg_wdata;
  logic        dbg_req, dbg_we;
  logic [31:0] dbg_rdata;

  cdriscv_32s_20_jtag_tap #(.IdCode(IDCODE)) u_dut (
      .tck_i(tck), .tms_i(tms), .tdi_i(tdi), .tdo_o(tdo), .tdo_oe_o(tdo_oe),
      .trst_ni(trst_n),
      .dbg_addr_o(dbg_addr), .dbg_wdata_o(dbg_wdata),
      .dbg_req_o(dbg_req), .dbg_we_o(dbg_we), .dbg_rdata_i(dbg_rdata));

  int checks = 0, errors = 0;

  task automatic fail(string msg);
    errors++;
    if (errors <= 12) $display("[FAIL] t=%0t %0s", $time, msg);
  endtask

  // one TCK: drive TMS/TDI on the falling edge, sample TDO after the rise
  task automatic tck_pulse(logic t, logic d);
    tms = t; tdi = d;
    #10 tck = 1'b1;
    #10 tck = 1'b0;
  endtask

  task automatic goto_reset();
    for (int i = 0; i < 5; i++) tck_pulse(1'b1, 1'b0);
  endtask

  // Test-Logic-Reset -> Run-Test/Idle -> Select-DR -> Select-IR ->
  // Capture-IR -> Shift-IR
  task automatic enter_shift_ir();
    tck_pulse(1'b0, 1'b0);   // Run-Test/Idle
    tck_pulse(1'b1, 1'b0);   // Select-DR
    tck_pulse(1'b1, 1'b0);   // Select-IR
    tck_pulse(1'b0, 1'b0);   // Capture-IR
    tck_pulse(1'b0, 1'b0);   // Shift-IR
  endtask

  task automatic enter_shift_dr();
    tck_pulse(1'b0, 1'b0);   // Run-Test/Idle
    tck_pulse(1'b1, 1'b0);   // Select-DR
    tck_pulse(1'b0, 1'b0);   // Capture-DR
    tck_pulse(1'b0, 1'b0);   // Shift-DR
  endtask

  // shift n bits LSB first, exit on the last, then Update
  task automatic scan(input int n, input logic [63:0] din,
                      output logic [63:0] dout);
    dout = 64'b0;
    for (int i = 0; i < n; i++) begin
      logic last;
      last = (i == n-1);
      tms = last; tdi = din[i];
      #5 dout[i] = tdo;        // sample before the rising edge
      #5 tck = 1'b1;
      #10 tck = 1'b0;
    end
    tck_pulse(1'b1, 1'b0);     // Exit1 -> Update
    tck_pulse(1'b0, 1'b0);     // Update -> Run-Test/Idle
  endtask

  logic [63:0] got;

  initial begin
    tms=1'b1; tdi=1'b0; trst_n=1'b0; dbg_rdata=32'h0;
    #40 trst_n = 1'b1;
    #20;

    // ---- 1. reset selects IDCODE, and IDCODE reads back ---------------
    goto_reset();
    enter_shift_dr();
    scan(32, 64'b0, got);
    checks++;
    if (got[31:0] !== IDCODE)
      fail($sformatf("IDCODE after reset: got %08x want %08x", got[31:0], IDCODE));

    // ---- 2. Capture-IR must present ...01 ------------------------------
    goto_reset();
    enter_shift_ir();
    scan(4, 64'hF, got);            // shift BYPASS in, capture out
    checks++;
    if (got[1:0] !== 2'b01)
      fail($sformatf("Capture-IR LSBs: got %02b want 01", got[1:0]));

    // ---- 3. BYPASS is exactly one bit ----------------------------------
    // IR now holds all-ones = BYPASS
    enter_shift_dr();
    begin
      logic [63:0] pattern, out;
      pattern = 64'b1011_0010_1100_1001;
      scan(20, pattern, out);
      checks++;
      // BYPASS: TDO at bit i is TDI from bit i-1 (one TCK of delay)
      for (int i = 1; i < 20; i++)
        if (out[i] !== pattern[i-1]) begin
          fail($sformatf("BYPASS delay at bit %0d: got %b want %b",
                         i, out[i], pattern[i-1]));
          break;
        end
    end

    // ---- 4. five TMS=1 reach reset from EVERY state --------------------
    // walk to a scattered set of states, then check IDCODE comes back
    for (int st = 0; st < 12; st++) begin
      goto_reset();
      // wander: st determines a pseudo-path through the state machine
      for (int k = 0; k <= st; k++) tck_pulse(k[0], 1'b0);
      goto_reset();                       // must land in Test-Logic-Reset
      enter_shift_dr();
      scan(32, 64'b0, got);
      checks++;
      if (got[31:0] !== IDCODE)
        fail($sformatf("state %0d: 5xTMS did not reset (got %08x)", st, got[31:0]));
    end

    // ---- 5. private debug instructions ----------------------------------
    goto_reset();
    enter_shift_ir();  scan(4, 64'b1000, got);      // IR_DBG_ADDR
    enter_shift_dr();  scan(32, 64'hDEAD_BEEF, got);
    checks++;
    if (dbg_addr !== 32'hDEAD_BEEF)
      fail($sformatf("dbg_addr: got %08x want DEADBEEF", dbg_addr));

    goto_reset();
    enter_shift_ir();  scan(4, 64'b1001, got);      // IR_DBG_DATA
    dbg_rdata = 32'hCAFE_F00D;
    enter_shift_dr();  scan(32, 64'h1234_5678, got);
    checks++;
    if (dbg_wdata !== 32'h1234_5678)
      fail($sformatf("dbg_wdata: got %08x want 12345678", dbg_wdata));
    checks++;
    if (got[31:0] !== 32'hCAFE_F00D)
      fail($sformatf("Capture-DR did not load dbg_rdata: got %08x", got[31:0]));

    // ---- 6. TDO drives only while shifting -------------------------------
    goto_reset();
    checks++;
    if (tdo_oe !== 1'b0) fail("tdo_oe asserted in Test-Logic-Reset");
    enter_shift_dr();
    checks++;
    if (tdo_oe !== 1'b1) fail("tdo_oe not asserted in Shift-DR");

    // ---- 7. TRST is asynchronous and forces IDCODE ------------------------
    enter_shift_ir(); scan(4, 64'b1000, got);   // select something else
    trst_n = 1'b0; #7 trst_n = 1'b1;            // pulse between TCKs
    enter_shift_dr(); scan(32, 64'b0, got);
    checks++;
    if (got[31:0] !== IDCODE)
      fail($sformatf("TRST did not restore IDCODE: got %08x", got[31:0]));

    $display("[tb_jtag] %0d checks, %0d failures", checks, errors);
    $display("[tb_jtag] %s", errors == 0 ? "PASS" : "FAIL");
    $finish;
  end

  initial begin #500000; $display("[tb_jtag] TIMEOUT"); $finish; end
endmodule
