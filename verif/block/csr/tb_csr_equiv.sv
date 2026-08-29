// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// Equivalence bench for cdriscv_32s_20_csr against cdriscv_csr.
//
// Same shape as tb_v2_decoder, but on a stateful module: both CSR files
// are driven from identical stimulus, cycle by cycle, and every output
// is compared.  Divergence in a register that is only read much later
// still shows up, because the comparison runs every cycle rather than
// at the end.
//
// Phase A is the regression: stimulus is constrained so that variant 2
// is *required* to behave exactly like variant 1 --
//   * no PMP addresses
//   * trap PCs word aligned
//   * mepc writes with bit 1 clear
// and then every output must match, with one documented exception:
// misa, which variant 2 must report differently because it implements
// B and C.  Constraining the stimulus rather than whitelisting the
// differences keeps phase A a strict equality check; the differences
// get tested on their own in phase B instead of being excused here.
//
// Phase B tests the three intended differences directly: misa, mepc
// bit 1, and the PMP registers with their WARL and locking rules.

`default_nettype none
`timescale 1ns/1ps

module tb_csr_equiv;

  localparam logic [11:0] A_MSTATUS  = 12'h300;
  localparam logic [11:0] A_MISA     = 12'h301;
  localparam logic [11:0] A_MIE      = 12'h304;
  localparam logic [11:0] A_MTVEC    = 12'h305;
  localparam logic [11:0] A_MSCRATCH = 12'h340;
  localparam logic [11:0] A_MEPC     = 12'h341;
  localparam logic [11:0] A_MCAUSE   = 12'h342;
  localparam logic [11:0] A_MTVAL    = 12'h343;
  localparam logic [11:0] A_MCYCLE   = 12'hb00;
  localparam logic [11:0] A_MINSTRET = 12'hb02;
  localparam logic [11:0] A_SAFESTAT = 12'h7c0;
  localparam logic [11:0] A_SAFECTRL = 12'h7c1;
  localparam logic [11:0] A_PMPCFG0  = 12'h3a0;
  localparam logic [11:0] A_PMPCFG1  = 12'h3a1;
  localparam logic [11:0] A_PMPCFG2  = 12'h3a2;
  localparam logic [11:0] A_PMPADDR0 = 12'h3b0;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  // shared stimulus
  logic        access, commit, rd_x0, rs1_x0;
  logic [1:0]  op;
  logic [11:0] addr;
  logic [31:0] wdata;
  logic        trap, trap_irq, mret;
  logic [4:0]  trap_cause;
  logic [31:0] trap_pc, trap_val;
  logic        irq_s, irq_t, irq_e;
  logic        ev_rf, ev_il, ev_bus, ev_ls;
  logic        retired;

  // ---------------- variant 1 ----------------
  logic [31:0] a_rdata, a_mtvec, a_mepc;
  logic        a_illegal, a_cfg_err, a_irq_pend, a_irq_wake, a_mie_o;
  logic [4:0]  a_irq_cause;
  logic        a_sw_fault, a_fault_en;

  cdriscv_csr u_v1 (
      .clk_i(clk), .rst_ni(rst_n),
      .access_i(access), .op_i(op), .addr_i(addr), .wdata_i(wdata),
      .rd_is_x0_i(rd_x0), .rs1_is_x0_i(rs1_x0),
      .rdata_o(a_rdata), .illegal_o(a_illegal), .commit_i(commit),
      .trap_i(trap), .trap_is_irq_i(trap_irq), .trap_cause_i(trap_cause),
      .trap_pc_i(trap_pc), .trap_val_i(trap_val), .mret_i(mret),
      .irq_soft_i(irq_s), .irq_timer_i(irq_t), .irq_ext_i(irq_e),
      .evt_rf_par_err_i(ev_rf), .evt_illegal_i(ev_il),
      .evt_bus_err_i(ev_bus), .evt_lockstep_i(ev_ls),
      .instr_retired_i(retired),
      .mtvec_o(a_mtvec), .cfg_err_o(a_cfg_err), .mepc_o(a_mepc),
      .irq_pending_o(a_irq_pend), .irq_wake_o(a_irq_wake),
      .irq_cause_o(a_irq_cause), .mstatus_mie_o(a_mie_o),
      .sw_fault_o(a_sw_fault), .fault_out_en_o(a_fault_en)
  );

  // ---------------- variant 2 ----------------
  logic [31:0] b_rdata, b_mtvec, b_mepc;
  logic        b_illegal, b_cfg_err, b_irq_pend, b_irq_wake, b_mie_o;
  logic [4:0]  b_irq_cause;
  logic        b_sw_fault, b_fault_en;
  logic [7:0]  b_pmp_cfg  [8];
  logic [31:0] b_pmp_addr [8];

  cdriscv_32s_20_csr u_v2 (
      .clk_i(clk), .rst_ni(rst_n),
      .access_i(access), .op_i(op), .addr_i(addr), .wdata_i(wdata),
      .rd_is_x0_i(rd_x0), .rs1_is_x0_i(rs1_x0),
      .rdata_o(b_rdata), .illegal_o(b_illegal), .commit_i(commit),
      .trap_i(trap), .trap_is_irq_i(trap_irq), .trap_cause_i(trap_cause),
      .trap_pc_i(trap_pc), .trap_val_i(trap_val), .mret_i(mret),
      .irq_soft_i(irq_s), .irq_timer_i(irq_t), .irq_ext_i(irq_e),
      .evt_rf_par_err_i(ev_rf), .evt_illegal_i(ev_il),
      .evt_bus_err_i(ev_bus), .evt_lockstep_i(ev_ls),
      .instr_retired_i(retired),
      .mtvec_o(b_mtvec), .cfg_err_o(b_cfg_err), .mepc_o(b_mepc),
      .irq_pending_o(b_irq_pend), .irq_wake_o(b_irq_wake),
      .irq_cause_o(b_irq_cause), .mstatus_mie_o(b_mie_o),
      .sw_fault_o(b_sw_fault), .fault_out_en_o(b_fault_en),
      .pmp_cfg_o(b_pmp_cfg), .pmp_addr_o(b_pmp_addr)
  );

  // ------------------------------------------------------------------
  integer checks, errors, n_wr, n_trap, n_illegal, seed, i, k;
  integer niter;
  logic [11:0] pool [16];

  task automatic fail(input string what);
    begin
      if (errors < 12) $display("[FAIL] %s (addr %03x op %0d)", what, addr, op);
      errors = errors + 1;
    end
  endtask

  task automatic compare_all;
    begin
      checks = checks + 1;
      // misa is the one documented difference; phase B checks it.
      if (addr !== A_MISA && b_rdata !== a_rdata) fail("rdata");
      else if (b_illegal   !== a_illegal)   fail("illegal");
      else if (b_mtvec     !== a_mtvec)     fail("mtvec");
      else if (b_mepc      !== a_mepc)      fail("mepc");
      else if (b_cfg_err   !== a_cfg_err)   fail("cfg_err");
      else if (b_irq_pend  !== a_irq_pend)  fail("irq_pending");
      else if (b_irq_wake  !== a_irq_wake)  fail("irq_wake");
      else if (b_irq_cause !== a_irq_cause) fail("irq_cause");
      else if (b_mie_o     !== a_mie_o)     fail("mstatus_mie");
      else if (b_sw_fault  !== a_sw_fault)  fail("sw_fault");
      else if (b_fault_en  !== a_fault_en)  fail("fault_out_en");
    end
  endtask

  // ---- helpers for phase B (drive variant 2 only, v1 in parallel) ----
  task automatic do_write(input logic [11:0] a, input logic [31:0] d);
    begin
      access = 1'b1; commit = 1'b1; op = 2'b01 /*RW*/;
      addr = a; wdata = d; rs1_x0 = 1'b0;
      @(posedge clk); #1;
      access = 1'b0; commit = 1'b0; op = 2'b00;
    end
  endtask

  task automatic do_read(input logic [11:0] a);
    begin
      access = 1'b1; commit = 1'b0; op = 2'b10 /*RS*/;
      addr = a; wdata = 32'b0; rs1_x0 = 1'b1;
      #1;
    end
  endtask

  task automatic expect_eq(input logic [31:0] got, input logic [31:0] want,
                           input string what);
    begin
      checks = checks + 1;
      if (got !== want) begin
        if (errors < 12)
          $display("[FAIL] %s: got %08x want %08x", what, got, want);
        errors = errors + 1;
      end
    end
  endtask

  initial begin
    seed = 32'hc5ea_0001;
    niter = 400000;
    void'($value$plusargs("niter=%d", niter));
    checks = 0; errors = 0; n_wr = 0; n_trap = 0; n_illegal = 0;

    pool[0]=A_MSTATUS; pool[1]=A_MISA;   pool[2]=A_MIE;      pool[3]=A_MTVEC;
    pool[4]=A_MSCRATCH;pool[5]=A_MEPC;   pool[6]=A_MCAUSE;   pool[7]=A_MTVAL;
    pool[8]=A_MCYCLE;  pool[9]=A_MINSTRET;pool[10]=A_SAFESTAT;pool[11]=A_SAFECTRL;
    pool[12]=12'h344;  pool[13]=12'hf14; pool[14]=12'hc00;   pool[15]=12'h000;

    access=0; commit=0; op=0; addr=0; wdata=0; rd_x0=0; rs1_x0=0;
    trap=0; trap_irq=0; mret=0; trap_cause=0; trap_pc=0; trap_val=0;
    irq_s=0; irq_t=0; irq_e=0; ev_rf=0; ev_il=0; ev_bus=0; ev_ls=0; retired=0;

    repeat (4) @(posedge clk); #1;
    rst_n = 1'b1;
    @(posedge clk); #1;

    // ================= phase A: strict equivalence =================
    for (i = 0; i < niter; i = i + 1) begin
      access     = (({$random(seed)} % 100) < 70);
      commit     = (({$random(seed)} % 100) < 80);
      op         = {$random(seed)} % 4;
      rd_x0      = {$random(seed)} % 2;
      rs1_x0     = ({$random(seed)} % 100) < 20;
      wdata      = $random(seed);
      retired    = {$random(seed)} % 2;
      irq_s      = {$random(seed)} % 2;
      irq_t      = {$random(seed)} % 2;
      irq_e      = {$random(seed)} % 2;
      ev_rf      = ({$random(seed)} % 100) < 3;
      ev_il      = ({$random(seed)} % 100) < 3;
      ev_bus     = ({$random(seed)} % 100) < 3;
      ev_ls      = ({$random(seed)} % 100) < 3;

      // mostly implemented CSRs, sometimes a random address
      if (({$random(seed)} % 100) < 75)
        addr = pool[{$random(seed)} % 16];
      else
        addr = {$random(seed)} % 4096;
      // ... but never a PMP one: those are the intended difference
      if (addr[11:4] == 8'h3a || addr[11:3] == 9'h076) addr = A_MSCRATCH;

      // mepc bit 1 is the other intended difference
      if (addr == A_MEPC) wdata[1] = 1'b0;

      trap       = ({$random(seed)} % 100) < 4;
      mret       = !trap && (({$random(seed)} % 100) < 4);
      trap_irq   = {$random(seed)} % 2;
      trap_cause = {$random(seed)} % 32;
      trap_val   = $random(seed);
      trap_pc    = {$random(seed)} & 32'hffff_fffc;   // word aligned

      if (trap)   n_trap = n_trap + 1;
      if (access && commit) n_wr = n_wr + 1;

      @(negedge clk);
      compare_all();
      if (a_illegal) n_illegal = n_illegal + 1;
      @(posedge clk); #1;
    end

    $display("[tb_csr_equiv] phase A: %0d checks, %0d mismatches (%0d writes, %0d traps, %0d illegal)",
             checks, errors, n_wr, n_trap, n_illegal);

    // ================= phase B: the intended differences =============
    access=0; commit=0; op=0; trap=0; mret=0; retired=0;
    irq_s=0; irq_t=0; irq_e=0; ev_rf=0; ev_il=0; ev_bus=0; ev_ls=0;
    @(posedge clk); #1;

    // --- misa reports I, M, B, C ---
    do_read(A_MISA);
    expect_eq(b_rdata, {2'b01, 4'b0, 26'h000_1106}, "misa (I+M+B+C)");
    expect_eq(a_rdata, {2'b01, 4'b0, 26'h000_1100}, "v1 misa (I+M)");
    access = 1'b0; @(posedge clk); #1;

    // --- mepc keeps bit 1 ---
    do_write(A_MEPC, 32'h0000_1236);          // ...0110
    do_read(A_MEPC);
    expect_eq(b_rdata, 32'h0000_1236, "v2 mepc keeps bit 1");
    expect_eq(a_rdata, 32'h0000_1234, "v1 mepc forces bits 1:0");
    access = 1'b0; @(posedge clk); #1;

    // and a trap on a halfword address
    trap = 1'b1; trap_pc = 32'h0000_2002; trap_cause = 5'd2; trap_irq = 1'b0;
    @(posedge clk); #1;
    trap = 1'b0;
    expect_eq(b_mepc, 32'h0000_2002, "v2 mepc from halfword trap PC");
    expect_eq(a_mepc, 32'h0000_2000, "v1 mepc from halfword trap PC");

    // --- v1 rejects PMP addresses, v2 does not ---
    do_read(A_PMPCFG0);
    checks = checks + 1;
    if (!a_illegal || b_illegal) begin
      $display("[FAIL] pmpcfg0 legality: v1 illegal=%0d (want 1), v2 illegal=%0d (want 0)",
               a_illegal, b_illegal);
      errors = errors + 1;
    end
    access = 1'b0; @(posedge clk); #1;

    // --- pmpcfg reserved bits [6:5] read as zero ---
    do_write(A_PMPCFG0, 32'h0000_00ff);       // request every bit of byte 0
    do_read(A_PMPCFG0);
    expect_eq(b_rdata & 32'h0000_00ff, 32'h0000_009f, "pmpcfg0 byte0 reserved bits cleared");
    access = 1'b0; @(posedge clk); #1;

    // --- R=0 W=1 is refused, byte unchanged ---
    do_write(A_PMPCFG0, 32'h0000_0000);       // clear (byte 0 not locked yet? it is)
    do_read(A_PMPCFG0);
    // byte 0 was locked by the 0xff write above (L=1), so it must be unchanged
    expect_eq(b_rdata & 32'h0000_00ff, 32'h0000_009f, "locked pmpcfg byte is read-only");
    access = 1'b0; @(posedge clk); #1;

    // use byte 1, which is not locked
    do_write(A_PMPCFG0, 32'h0000_0200 | (32'h0000_009f));  // byte1 = 0x02 -> R=0 W=1
    do_read(A_PMPCFG0);
    expect_eq((b_rdata >> 8) & 32'h0000_00ff, 32'h0000_0000, "R=0,W=1 refused");
    access = 1'b0; @(posedge clk); #1;

    // --- pmpaddr0 is locked because pmpcfg0 byte 0 is locked ---
    do_write(A_PMPADDR0, 32'hdead_beef);
    do_read(A_PMPADDR0);
    expect_eq(b_rdata, 32'h0000_0000, "pmpaddr0 locked by its own cfg");
    access = 1'b0; @(posedge clk); #1;

    // --- pmpaddr2 writable, then locked by a TOR region 3 ---
    do_write(A_PMPADDR0 + 12'd2, 32'h1111_1111);
    do_read(A_PMPADDR0 + 12'd2);
    expect_eq(b_rdata, 32'h1111_1111, "pmpaddr2 writable while unlocked");
    access = 1'b0; @(posedge clk); #1;

    // region 3: L=1, A=TOR(01) -> byte value 8'b1_00_01_000 = 0x88
    do_write(A_PMPCFG0, 32'h8800_0000 | 32'h0000_009f);
    do_write(A_PMPADDR0 + 12'd2, 32'h2222_2222);
    do_read(A_PMPADDR0 + 12'd2);
    expect_eq(b_rdata, 32'h1111_1111, "pmpaddr2 locked by TOR region 3");
    access = 1'b0; @(posedge clk); #1;

    // --- pmpcfg2 reads zero and ignores writes ---
    do_write(A_PMPCFG2, 32'hffff_ffff);
    do_read(A_PMPCFG2);
    expect_eq(b_rdata, 32'h0000_0000, "pmpcfg2 reads zero");
    access = 1'b0; @(posedge clk); #1;

    // --- the PMP outputs carry what the CSRs hold ---
    expect_eq({24'b0, b_pmp_cfg[0]}, 32'h0000_009f, "pmp_cfg_o[0]");
    expect_eq({24'b0, b_pmp_cfg[3]}, 32'h0000_0088, "pmp_cfg_o[3]");
    expect_eq(b_pmp_addr[2],         32'h1111_1111, "pmp_addr_o[2]");

    $display("[tb_csr_equiv] %0d checks, %0d mismatches", checks, errors);
    if (n_wr < 20000 || n_trap < 1000 || n_illegal < 1000) begin
      $display("[tb_csr_equiv] FAIL -- a required class is under-exercised");
      $finish;
    end
    if (errors == 0) $display("[tb_csr_equiv] PASS");
    else             $display("[tb_csr_equiv] FAIL");
    $finish;
  end

endmodule

`default_nettype wire
