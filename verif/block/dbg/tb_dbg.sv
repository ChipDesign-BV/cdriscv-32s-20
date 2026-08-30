// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// Block bench for the JTAG debug path: cdriscv_32s_20_dbg_bridge driving
// cdriscv_32s_20_dbg_win.  The TAP itself has its own bench (tb_jtag).
//
// Two things are being checked, and the second is the reason this bench
// exists at all:
//
//   1. the window decodes what it claims to -- including that a wrong
//      address gives the poison value rather than an aliased register,
//      and that a write changes nothing;
//
//   2. the crossing works at ANY tck:clk ratio.  The bridge header
//      claims that, so the bench runs the identical read sequence with
//      tck far slower than clk, equal to it, and far faster, and
//      requires the same answers.  A CDC that is only ever exercised
//      with a slow tck is a CDC whose one interesting property is
//      untested.
//
// Everything is checked against a value that could not arise by
// accident: the stimulus for each field is a distinct pattern, so a
// mux that returns the wrong register fails rather than coincidentally
// matching.

`timescale 1ns/1ps

module tb_dbg;

  localparam logic [31:0] IDCODE = 32'h0CD1_507B;
  localparam logic [31:0] POISON = 32'hffff_ffff;

  // ---- clocks -----------------------------------------------------

  logic clk = 1'b0;
  logic tck = 1'b0;
  logic rst_n = 1'b0;
  logic trst_n = 1'b0;

  real tck_half = 35.0;            // changed per phase

  always #5.0 clk = ~clk;          // 100 MHz system clock, fixed
  always #(tck_half) tck = ~tck;

  // ---- DUT --------------------------------------------------------

  logic [31:0] dbg_addr, dbg_wdata, dbg_rdata;
  logic        dbg_req, dbg_we, dbg_busy;

  logic        acc, acc_we;
  logic [31:0] acc_addr, acc_wdata, acc_rdata;

  cdriscv_32s_20_dbg_bridge u_bridge (
      .tck_i       (tck),
      .trst_ni     (trst_n),
      .dbg_addr_i  (dbg_addr),
      .dbg_wdata_i (dbg_wdata),
      .dbg_req_i   (dbg_req),
      .dbg_we_i    (dbg_we),
      .dbg_rdata_o (dbg_rdata),
      .dbg_busy_o  (dbg_busy),
      .clk_i       (clk),
      .rst_ni      (rst_n),
      .acc_o       (acc),
      .acc_addr_o  (acc_addr),
      .acc_wdata_o (acc_wdata),
      .acc_we_o    (acc_we),
      .acc_rdata_i (acc_rdata)
  );

  // observed state, driven by the bench
  logic        core_sleep, fault_any, err_pin, reset_req;
  logic [15:0] fault_int, fault_ext;
  logic        retire_valid;
  logic [31:0] retire_pc, retire_instr;

  cdriscv_32s_20_dbg_win #(.IdCode(IDCODE)) u_win (
      .clk_i          (clk),
      .rst_ni         (rst_n),
      .acc_i          (acc),
      .acc_addr_i     (acc_addr),
      .acc_wdata_i    (acc_wdata),
      .acc_we_i       (acc_we),
      .acc_rdata_o    (acc_rdata),
      .core_sleep_i   (core_sleep),
      .fault_any_i    (fault_any),
      .err_pin_i      (err_pin),
      .reset_req_i    (reset_req),
      .fault_int_i    (fault_int),
      .fault_ext_i    (fault_ext),
      .retire_valid_i (retire_valid),
      .retire_pc_i    (retire_pc),
      .retire_instr_i (retire_instr)
  );

  // ---- scoreboard -------------------------------------------------

  int errors = 0;
  int checks = 0;

  task automatic check(input string what, input logic [31:0] got,
                       input logic [31:0] exp);
    checks++;
    if (got !== exp) begin
      errors++;
      $display("FAIL %-42s got %08x exp %08x", what, got, exp);
    end else begin
      $display("  ok %-42s %08x", what, got);
    end
  endtask

  // ---- one debug-bus transaction, driven from the tck domain -------
  //
  // Mirrors what the TAP does: address and data are set up first and are
  // stable when the single-cycle request pulse goes out at UPDATE_DR.

  task automatic dbg_access(input logic [31:0] a, input logic we,
                            input logic [31:0] d);
    @(posedge tck);
    dbg_addr  <= a;
    dbg_wdata <= d;
    dbg_we    <= we;
    @(posedge tck);
    dbg_req   <= 1'b1;
    @(posedge tck);
    dbg_req   <= 1'b0;
    // Wait for busy to RISE before waiting for it to fall.  Testing only
    // for the fall races the non-blocking update of busy_q and returns
    // immediately, which reads the previous transaction's data -- every
    // check then passes or fails one transaction late.
    wait (dbg_busy === 1'b1);
    wait (dbg_busy === 1'b0);
    @(posedge tck);
  endtask

  task automatic dbg_read(input logic [31:0] a, output logic [31:0] v);
    dbg_access(a, 1'b0, 32'h0);
    v = dbg_rdata;
  endtask

  // ---- the read sequence, run once per clock ratio -----------------

  task automatic read_all(input string tag);
    logic [31:0] v;

    dbg_read(32'h00, v); check({tag, " IDCODE"},   v, IDCODE);
    dbg_read(32'h08, v); check({tag, " FAULTINT"}, v, {16'h0, fault_int});
    dbg_read(32'h0c, v); check({tag, " FAULTEXT"}, v, {16'h0, fault_ext});
    dbg_read(32'h10, v); check({tag, " LASTPC"},   v, 32'h0000_1234);
    dbg_read(32'h14, v); check({tag, " LASTINSN"}, v, 32'h0000_4581);

    // an address inside the window but not a register
    dbg_read(32'h18, v); check({tag, " unmapped 0x18"}, v, POISON);
    // and one that would alias onto IDCODE if only [7:0] were decoded
    dbg_read(32'h100, v); check({tag, " no alias at 0x100"}, v, POISON);
    dbg_read(32'h8000_0000, v);
    check({tag, " no alias at 0x80000000"}, v, POISON);
  endtask

  // ---- stimulus ---------------------------------------------------

  logic [31:0] v;

  initial begin
    dbg_addr = '0; dbg_wdata = '0; dbg_req = 1'b0; dbg_we = 1'b0;
    core_sleep = 1'b0; fault_any = 1'b0; err_pin = 1'b0; reset_req = 1'b0;
    fault_int = 16'h0; fault_ext = 16'h0;
    retire_valid = 1'b0; retire_pc = '0; retire_instr = '0;

    repeat (4) @(posedge clk);
    rst_n  = 1'b1;
    trst_n = 1'b1;
    repeat (4) @(posedge clk);

    // distinct patterns so a wrong mux leg cannot coincidentally pass
    fault_int = 16'h1248;
    fault_ext = 16'ha5c3;

    // retire one instruction, then stop retiring: the window must hold
    // this value, not follow the live inputs
    @(posedge clk);
    retire_pc    <= 32'h0000_1234;
    retire_instr <= 32'h0000_4581;
    retire_valid <= 1'b1;
    @(posedge clk);
    retire_valid <= 1'b0;
    retire_pc    <= 32'hdead_beef;   // must NOT appear in the window
    retire_instr <= 32'hdead_beef;
    @(posedge clk);

    // ---- phase 1: tck much slower than clk (the normal case) ------
    tck_half = 35.0;
    read_all("slow tck");

    // ---- status register, bit by bit ------------------------------
    // Each bit is set alone, so a status word wired in the wrong order
    // fails on the first one instead of passing on an accidental match.
    dbg_read(32'h04, v); check("status idle", v, 32'h0000_0010);

    core_sleep = 1'b1;
    dbg_read(32'h04, v); check("status core_sleep", v, 32'h0000_0011);
    core_sleep = 1'b0;

    fault_any = 1'b1;
    dbg_read(32'h04, v); check("status fault_any", v, 32'h0000_0012);
    fault_any = 1'b0;

    err_pin = 1'b1;
    dbg_read(32'h04, v); check("status err_pin", v, 32'h0000_0014);
    err_pin = 1'b0;

    reset_req = 1'b1;
    dbg_read(32'h04, v); check("status reset_req", v, 32'h0000_0018);
    reset_req = 1'b0;

    // ---- a write must change nothing ------------------------------
    dbg_access(32'h04, 1'b1, 32'hffff_ffff);
    dbg_read(32'h04, v); check("write to STATUS ignored", v, 32'h0000_0010);
    dbg_access(32'h10, 1'b1, 32'hffff_ffff);
    dbg_read(32'h10, v); check("write to LASTPC ignored", v, 32'h0000_1234);

    // ---- the held value survives further non-retiring cycles ------
    repeat (20) @(posedge clk);
    dbg_read(32'h10, v); check("LASTPC still held", v, 32'h0000_1234);

    // ---- phase 2: tck equal to clk --------------------------------
    tck_half = 5.0;
    repeat (4) @(posedge tck);
    read_all("equal tck");

    // ---- phase 3: tck FASTER than clk -----------------------------
    // The bridge claims no dependence on the ratio.  This is that claim.
    tck_half = 1.5;
    repeat (8) @(posedge tck);
    read_all("fast tck");

    // ---- a request while busy is dropped, not queued --------------
    // Two pulses back to back: the second must not be seen, and the
    // first must still complete and return its own address's value.
    tck_half = 35.0;
    repeat (4) @(posedge tck);
    @(posedge tck);
    dbg_addr <= 32'h00;  dbg_we <= 1'b0;
    @(posedge tck);
    dbg_req  <= 1'b1;
    @(posedge tck);
    dbg_req  <= 1'b0;
    dbg_addr <= 32'h10;             // would return LASTPC if it took effect
    @(posedge tck);
    dbg_req  <= 1'b1;               // ignored: busy
    @(posedge tck);
    dbg_req  <= 1'b0;
    wait (dbg_busy === 1'b0);
    @(posedge tck);
    check("request while busy dropped", dbg_rdata, IDCODE);

    // ---- TAP reset clears the debug data register -----------------
    trst_n = 1'b0;
    repeat (4) @(posedge tck);
    trst_n = 1'b1;
    repeat (2) @(posedge tck);
    check("trst_n clears rdata", dbg_rdata, 32'h0);
    dbg_read(32'h00, v); check("usable after trst_n", v, IDCODE);

    // ---- verdict --------------------------------------------------
    $display("");
    if (errors == 0) $display("PASS  %0d checks", checks);
    else             $display("FAILED %0d of %0d checks", errors, checks);
    $finish;
  end

  initial begin
    #500000;
    $display("FAILED timeout");
    $finish;
  end

endmodule
