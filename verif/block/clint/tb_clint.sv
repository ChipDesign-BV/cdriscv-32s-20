// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s-10 v2 -- CLINT block bench.
//
// The reference is a plain behavioural model of what the privileged
// specification says a CLINT does, written from the prose rather than
// from the DUT: a prescaled 64-bit counter, a 64-bit comparator, a
// software-interrupt bit, and a LEVEL timer interrupt that is high
// exactly while mtime >= mtimecmp.
//
// The properties worth attacking, in order of how easily they are got
// wrong:
//
//   * MTIP is a LEVEL, not a pulse.  It must stay high until software
//     moves mtimecmp, and must reassert if mtimecmp moves back below
//     mtime.  A pulse implementation passes a careless bench.
//   * mtime keeps counting while mtimecmp is written in two halves,
//     which is the RV32 hazard the programming manual documents.
//   * the register map is the standard one -- msip 0x0000,
//     mtimecmp 0x4000, mtime 0xBFF8 -- and everything else errors.

`timescale 1ns/1ps

module tb_clint;

  localparam int unsigned PW = 16;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic        req, we;
  logic [15:0] addr;
  logic [31:0] wdata, rdata;
  logic        err, irq_timer, irq_soft, cfg_err;

  cdriscv_32s_20_clint #(.PrescalerW(PW)) u_dut (
      .clk_i(clk), .rst_ni(rst_n), .req_i(req), .we_i(we), .addr_i(addr),
      .wdata_i(wdata), .rdata_o(rdata), .err_o(err),
      .irq_timer_o(irq_timer), .irq_soft_o(irq_soft), .cfg_err_o(cfg_err));

  // ---- independent reference model ------------------------------------
  logic [63:0] r_mtime, r_cmp;
  logic        r_msip;
  logic [PW-1:0] r_presc, r_cnt;

  int checks = 0, errors = 0;

  task automatic ref_step();
    if (r_cnt == r_presc) begin
      r_cnt   = '0;
      r_mtime = r_mtime + 64'd1;
    end else begin
      r_cnt = r_cnt + 1'b1;
    end
    if (req && we) begin
      case (addr)
        16'h0000 : r_msip        = wdata[0];
        16'h4000 : r_cmp[31:0]   = wdata;
        16'h4004 : r_cmp[63:32]  = wdata;
        16'hBFF8 : r_mtime[31:0] = wdata;
        16'hBFFC : r_mtime[63:32]= wdata;
        16'h8000 : r_presc       = wdata[PW-1:0];
        default  : ;
      endcase
    end
  endtask

  function automatic logic [31:0] ref_rdata();
    case (addr)
      16'h0000 : return {31'b0, r_msip};
      16'h4000 : return r_cmp[31:0];
      16'h4004 : return r_cmp[63:32];
      16'hBFF8 : return r_mtime[31:0];
      16'hBFFC : return r_mtime[63:32];
      16'h8000 : return {{(32-PW){1'b0}}, r_presc};
      default  : return 32'h0;
    endcase
  endfunction

  function automatic logic ref_err();
    case (addr)
      16'h0000, 16'h4000, 16'h4004, 16'hBFF8, 16'hBFFC, 16'h8000 : return 1'b0;
      default : return req;
    endcase
  endfunction

  task automatic cmp(string tag);
    checks++;
    // cfg_err_o must stay low throughout: nothing here corrupts a
    // protected register, so any assertion is a false alarm from the
    // parity block.  The bench previously ignored this output entirely,
    // which is how an unconnected wr_i went unnoticed.
    if (rdata !== ref_rdata() || err !== ref_err() ||
        irq_timer !== (r_mtime >= r_cmp) || irq_soft !== r_msip ||
        cfg_err !== 1'b0) begin
      errors++;
      if (errors <= 12)
        $display("[MISMATCH:%0s] t=%0t addr=%04x cfgerr=%b mtip %b/%b | dut mtime=%0d cmp=%0d cnt=%0d presc=%0d | ref mtime=%0d cmp=%0d cnt=%0d presc=%0d",
                 tag, $time, addr, cfg_err, irq_timer, (r_mtime >= r_cmp),
                 u_dut.mtime_q, u_dut.mtimecmp_q, u_dut.presc_cnt_q, u_dut.presc_q,
                 r_mtime, r_cmp, r_cnt, r_presc);
    end
  endtask

  task automatic idle(); req=0; we=0; addr=16'h0; wdata=32'h0; endtask

  // The reference steps on the clock, not from the stimulus tasks.  An
  // earlier version stepped it inside wr/rd/tick, which drifted: rst_n
  // is released on a posedge and the first tick() then waits a further
  // negedge, so the DUT saw one increment the model never made.  The
  // model lagged by one from then on and reported 18 false MTIP
  // mismatches.  Driving it from the same edge as the DUT cannot drift.
  always @(posedge clk) begin
    if (!rst_n) begin
      r_mtime <= 64'd0; r_cmp <= {64{1'b1}}; r_msip <= 1'b0;
      r_presc <= '0;    r_cnt <= '0;
    end else begin
      ref_step();
    end
  end

  task automatic wr(logic [15:0] a, logic [31:0] d);
    @(negedge clk); req=1; we=1; addr=a; wdata=d;
    @(posedge clk); #1 cmp("wr");
  endtask

  task automatic rd(logic [15:0] a);
    @(negedge clk); req=1; we=0; addr=a; wdata=32'h0;
    #1 cmp("rd_comb");
    @(posedge clk); #1;
  endtask

  task automatic tick(int n);
    for (int i = 0; i < n; i++) begin
      @(negedge clk); idle();
      @(posedge clk); #1 cmp("tick");
    end
  endtask

  initial begin
    idle();
    // Release reset on a NEGEDGE.  Releasing it at a posedge races the
    // DUT's asynchronous reset against the model's synchronous one: the
    // DUT sampled rst_ni=1 and incremented while the model still saw 0,
    // leaving the model permanently one count behind and reporting false
    // MTIP mismatches at every comparator crossing.
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;

    // ---- 1. reset state: mtimecmp all-ones, so no interrupt ----------
    tick(50);

    // ---- 2. MTIP is a level, not a pulse ------------------------------
    wr(16'h4000, 32'd60); wr(16'h4004, 32'd0);   // fire soon
    tick(200);                                    // must go high and STAY high
    // move the comparator up: MTIP must drop
    wr(16'h4000, 32'hffff_ffff); wr(16'h4004, 32'h0000_ffff);
    tick(50);
    // move it back below mtime: MTIP must reassert
    wr(16'h4004, 32'd0); wr(16'h4000, 32'd10);
    tick(50);

    // ---- 3. the RV32 two-half write hazard ----------------------------
    // the documented safe sequence: hi=all-ones, then lo, then hi
    wr(16'h4004, 32'hffff_ffff);
    wr(16'h4000, 32'd500);
    wr(16'h4004, 32'd0);
    tick(120);

    // ---- 4. msip -------------------------------------------------------
    wr(16'h0000, 32'h1); tick(5);
    wr(16'h0000, 32'h0); tick(5);
    wr(16'h0000, 32'hffff_ffff); tick(5);   // only bit 0 is implemented

    // ---- 5. prescaler --------------------------------------------------
    wr(16'h8000, 32'd7); tick(100);
    wr(16'h8000, 32'd0); tick(30);

    // ---- 6. mtime is writable both halves ------------------------------
    wr(16'hBFF8, 32'hffff_fff0); wr(16'hBFFC, 32'd0);
    tick(40);                                    // must roll into the high half

    // ---- 7. register read-back and unmapped offsets --------------------
    rd(16'h0000); rd(16'h4000); rd(16'h4004);
    rd(16'hBFF8); rd(16'hBFFC); rd(16'h8000);
    rd(16'h0004); rd(16'h1234); rd(16'hFFFC); rd(16'hC000);

    // ---- 8. random traffic ----------------------------------------------
    for (int k = 0; k < 6000; k++) begin
      logic [15:0] a;
      int pick;
      pick = $urandom_range(0,7);
      case (pick)
        0: a = 16'h0000; 1: a = 16'h4000; 2: a = 16'h4004;
        3: a = 16'hBFF8; 4: a = 16'hBFFC; 5: a = 16'h8000;
        default: a = 16'($urandom);
      endcase
      if ($urandom_range(0,1) == 1) wr(a, $urandom); else rd(a);
      if ($urandom_range(0,3) == 0) tick($urandom_range(1,6));
    end

    $display("[tb_clint] %0d checks, %0d mismatches", checks, errors);
    $display("[tb_clint] %s", errors == 0 ? "PASS" : "FAIL");
    $finish;
  end

  initial begin #50_000_000; $display("[tb_clint] TIMEOUT"); $finish; end
endmodule
