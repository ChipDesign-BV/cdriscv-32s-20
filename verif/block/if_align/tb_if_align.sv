// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// Equivalence bench for cdriscv_32s_20_if_align.
//
// The reference is a byte-stream walker written from the ISA rule and
// nothing else: read the halfword at the pointer, if bits [1:0] are 11
// take four bytes and advance four, otherwise take two and advance two.
// It has no notion of words, of the DUT's straddle latch, or of which
// half of a word anything sits in -- which is the point, because those
// are exactly what the DUT gets to be wrong about.
//
// Memory is filled with random halfwords, so about a quarter of them
// read as uncompressed and straddles are common rather than a corner.
// Error bits are random per word, so a straddling instruction regularly
// has an error in one of its two code words but not the other.
//
// Backpressure is random on both sides and redirects land on random
// halfword boundaries, so the DUT is exercised holding a straddle
// across stalls and having one discarded by a redirect.

`default_nettype none
`timescale 1ns/1ps

module tb_if_align;

  localparam int NWORDS  = 512;
  localparam int ABITS   = 11;              // NWORDS*4 = 2048 bytes
  localparam int AMASK   = (1 << ABITS) - 1;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  // ------------------------------------------------------------------
  // Memory image
  // ------------------------------------------------------------------
  logic [31:0] mem  [NWORDS];
  logic        merr [NWORDS];

  // ------------------------------------------------------------------
  // DUT
  // ------------------------------------------------------------------
  logic        redirect;
  logic [31:0] redirect_pc;
  logic        word_valid, word_ready, word_err;
  logic [31:0] word_rdata, word_pc;
  logic        instr_valid, instr_err, instr_illegal, instr_compressed;
  logic        instr_zcmp;   // observed for completeness; the walker's
                             // classification of Zcmp encodings is
                             // checked in block-decompress/block-zcmp
  logic [31:0] instr_rdata, instr_pc;
  logic        instr_ready;

  cdriscv_32s_20_if_align u_dut (
      .clk_i             (clk),
      .rst_ni            (rst_n),
      .redirect_i        (redirect),
      .redirect_pc_i     (redirect_pc),
      .word_valid_i      (word_valid),
      .word_rdata_i      (word_rdata),
      .word_pc_i         (word_pc),
      .word_err_i        (word_err),
      .word_ready_o      (word_ready),
      .instr_valid_o     (instr_valid),
      .instr_rdata_o     (instr_rdata),
      .instr_pc_o        (instr_pc),
      .instr_err_o       (instr_err),
      .instr_illegal_o   (instr_illegal),
      .instr_zcmp_o      (instr_zcmp),
      .instr_compressed_o(instr_compressed),
      .instr_ready_i     (instr_ready)
  );

  // Reference expander, for the compressed case only.  The decompressor
  // is separately verified against binutils over all 65 536 encodings
  // (make block-v2-decompress); this bench is about realignment, so it
  // takes the expansion as given and checks that the right halfword was
  // presented to it.
  logic [15:0] ref_hw;
  logic [31:0] ref_expanded;
  logic        ref_illegal;
  cdriscv_32s_20_decompress u_ref_dec (
      .instr_i   (ref_hw),
      .instr_o   (ref_expanded),
      .illegal_o (ref_illegal)
  );

  // ------------------------------------------------------------------
  // Word-stream driver -- models the prefetcher
  // ------------------------------------------------------------------
  logic [31:0] fetch_addr;

  assign word_pc    = fetch_addr;
  assign word_rdata = mem [(fetch_addr >> 2) & (NWORDS-1)];
  assign word_err   = merr[(fetch_addr >> 2) & (NWORDS-1)];

  // ------------------------------------------------------------------
  // Golden model
  // ------------------------------------------------------------------
  logic [31:0] gm_pc;
  logic [31:0] exp_pc, exp_raw;
  logic        exp_comp, exp_err;

  task automatic gm_step;
    int          wi, wj;
    logic [15:0] h;
    begin
      wi = (gm_pc >> 2) & (NWORDS-1);
      if (gm_pc[1]) h = mem[wi][31:16];
      else          h = mem[wi][15:0];

      exp_pc = gm_pc;
      if (h[1:0] == 2'b11) begin
        exp_comp = 1'b0;
        if (!gm_pc[1]) begin
          exp_raw = mem[wi];
          exp_err = merr[wi];
        end else begin
          wj      = (wi + 1) & (NWORDS-1);
          exp_raw = {mem[wj][15:0], h};
          exp_err = merr[wi] | merr[wj];
        end
        gm_pc = (gm_pc + 32'd4) & AMASK;
      end else begin
        exp_comp = 1'b1;
        exp_raw  = {16'h0, h};
        exp_err  = merr[wi];
        gm_pc    = (gm_pc + 32'd2) & AMASK;
      end
    end
  endtask

  // ------------------------------------------------------------------
  // Stimulus and checking
  // ------------------------------------------------------------------
  integer checks, errors, n_comp, n_strad, n_redirect, n_err;
  logic   adv;   // word consumed this cycle, applied after the edge
  integer seed;
  integer i;
  logic [31:0] target;
  logic [31:0] want_rdata;
  logic [31:0] trace [8];
  integer      t;

  initial begin
    seed    = 32'h5eed_1234;
    checks  = 0; errors = 0;
    n_comp  = 0; n_strad = 0; n_redirect = 0; n_err = 0;

    for (i = 0; i < NWORDS; i = i + 1) begin
      mem[i]  = {$random(seed)} & 32'hffff_ffff;
      merr[i] = (({$random(seed)} % 100) < 5);   // 5 % of words faulted
    end

    redirect    = 1'b0;
    redirect_pc = 32'b0;
    word_valid  = 1'b0;
    instr_ready = 1'b0;
    fetch_addr  = 32'b0;
    gm_pc       = 32'b0;

    // Reset release, like every other input, must happen off the edge:
    // asserted AT a posedge it races the DUT's own asynchronous reset
    // and the two simulators disagree about which edge is the first
    // live one.  Icarus passed and Verilator failed on exactly this.
    repeat (4) @(posedge clk);
    #1;
    rst_n = 1'b1;
    @(posedge clk);
    #1;

    for (i = 0; i < 200000; i = i + 1) begin
      // random backpressure on both interfaces
      word_valid  = (({$random(seed)} % 100) < 80);
      instr_ready = (({$random(seed)} % 100) < 70);

      // occasional redirect; never coincident with an acceptance, so
      // the bench does not have to arbitrate the two
      if (({$random(seed)} % 1000) < 8) begin
        instr_ready = 1'b0;
        target      = {$random(seed)} & AMASK & 32'hffff_fffe;  // halfword aligned
        redirect    = 1'b1;
        redirect_pc = target;
      end

      @(negedge clk);

      if (!redirect && instr_valid && instr_ready) begin
        gm_step();
        if (errors == 0 && checks > 0)
          trace[checks % 8] = {instr_pc[15:0], exp_pc[15:0]};

        // what the instruction word should be
        if (exp_comp) begin
          ref_hw = exp_raw[15:0];
          #1;                       // let the reference decompressor settle
          want_rdata = ref_expanded;
        end else begin
          want_rdata = exp_raw;
        end

        checks = checks + 1;
        if (exp_comp) n_comp  = n_comp + 1;
        if (!exp_comp && exp_pc[1]) n_strad = n_strad + 1;
        if (exp_err)  n_err   = n_err + 1;

        if (instr_pc !== exp_pc && errors == 0) begin
          $display("  last 8 accepted (dut_pc, model_pc):");
          for (t = 0; t < 8; t = t + 1)
            $display("    %04x  %04x", trace[(checks + t) % 8][31:16], trace[(checks + t) % 8][15:0]);
        end
        if (instr_pc !== exp_pc) begin
          if (errors < 3)
            $display("[FAIL] pc: got %08x want %08x | half_q=%0d strad_q=%0d strad_pc=%08x fetch=%08x wv=%0d wr=%0d rdata=%08x",
                     instr_pc, exp_pc, u_dut.half_q, u_dut.strad_q,
                     u_dut.strad_pc_q, fetch_addr, word_valid, word_ready, word_rdata);
          errors = errors + 1;
        end else if (instr_compressed !== exp_comp) begin
          if (errors < 10)
            $display("[FAIL] pc %08x compressed: got %0d want %0d",
                     exp_pc, instr_compressed, exp_comp);
          errors = errors + 1;
        end else if (instr_err !== exp_err) begin
          if (errors < 10)
            $display("[FAIL] pc %08x err: got %0d want %0d",
                     exp_pc, instr_err, exp_err);
          errors = errors + 1;
        end else if (instr_rdata !== want_rdata) begin
          if (errors < 10)
            $display("[FAIL] pc %08x rdata: got %08x want %08x",
                     exp_pc, instr_rdata, want_rdata);
          errors = errors + 1;
        end
      end

      // Latch the DUT's request now; applying it before the posedge
      // would change word_rdata_i underneath the very edge that
      // consumes it.
      adv = (!redirect && word_valid && word_ready);

      // Drive inputs strictly after the edge.  Assigning them AT the
      // edge races the DUT's own always_ff sampling them: a redirect
      // pulse cleared in the same timestep can be missed by the flop
      // and seen by the model, and the two then disagree for good.
      @(posedge clk);
      #1;

      if (adv) fetch_addr = (fetch_addr + 32'd4) & AMASK;

      if (redirect) begin
        fetch_addr = target & AMASK & 32'hffff_fffc;
        gm_pc      = target;
        redirect   = 1'b0;
        n_redirect = n_redirect + 1;
      end
    end

    $display("[tb_if_align] %0d checks, %0d mismatches", checks, errors);
    $display("[tb_if_align]   %0d compressed, %0d straddling, %0d faulted, %0d redirects",
             n_comp, n_strad, n_err, n_redirect);
    if (checks < 10000) begin
      $display("[tb_if_align] FAIL -- too few checks, stimulus is not running");
      $finish;
    end
    if (n_strad < 500 || n_err < 200 || n_redirect < 100) begin
      $display("[tb_if_align] FAIL -- a required case is under-exercised");
      $finish;
    end
    if (errors == 0) $display("[tb_if_align] PASS");
    else             $display("[tb_if_align] FAIL");
    $finish;
  end

endmodule

`default_nettype wire
