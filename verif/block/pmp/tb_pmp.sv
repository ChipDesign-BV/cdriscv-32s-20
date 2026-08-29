// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s v2 -- PMP block bench.
//
// The reference implements the privileged-spec matching rules from the
// prose rather than from the DUT: NAPOT size is derived by counting
// trailing ones, TOR bounds are compared as plain integers, and the
// first-match scan is an explicit early-exit loop.
//
// The cases that matter here are the ones a PMP gets wrong in practice:
// first-match-wins (not most-permissive), TOR against the previous
// entry with entry 0 based at zero, the lock bit binding machine mode,
// and NAPOT sizes at both extremes.

`timescale 1ns/1ps

module tb_pmp
  import cdriscv_32s_20_pkg::*;
;

  localparam int unsigned N = 8;

  pmp_cfg_t     cfg  [N];
  logic [31:0]  addr [N];
  logic [31:0]  req_addr;
  pmp_access_e  req_type;
  logic         req_m, dut_allow, ref_allow;
  int           checks = 0, errors = 0;

  cdriscv_32s_20_pmp #(.NRegions(N)) u_dut (
      .cfg_i(cfg), .addr_i(addr), .req_addr_i(req_addr),
      .req_type_i(req_type), .req_machine_i(req_m), .allow_o(dut_allow));

  // ---- independent reference ------------------------------------------
  function automatic logic refmodel();
    logic [31:0] pa, lower, msk, base, ar;
    logic        m, perm;
    int          tz;
    pmp_cfg_t    c;
    // cfg[r] and addr[r] are copied into locals before use: Icarus
    // aborts on a struct-field or bit select into an element of an
    // unpacked array.  Same class of limitation as the RTL constructs
    // removed earlier -- worked around in the bench, since the port
    // shape itself is what the DUT needs.
    pa = {2'b00, req_addr[31:2]};
    for (int r = 0; r < N; r++) begin
      c     = cfg[r];
      ar    = addr[r];
      lower = (r == 0) ? 32'd0 : addr[r-1];
      m = 1'b0;
      case (c.a)
        PMP_OFF   : m = 1'b0;
        PMP_TOR   : m = (pa >= lower) && (pa < ar);
        PMP_NA4   : m = (pa == ar);
        PMP_NAPOT : begin
          // Count trailing ones of pmpaddr -> region size.  `ar` is a
          // local copy because Icarus aborts on a bit select into an
          // element of an unpacked array (addr[r][i]).
          tz = 0;
          for (int i = 0; i < 32; i++)
            if (ar[i] == 1'b1) tz++; else break;
          msk  = (tz >= 32) ? 32'h0 : (32'hffff_ffff << (tz + 1));
          base = ar & msk;
          m    = ((pa & msk) == base);
        end
        default : m = 1'b0;
      endcase
      if (m) begin
        case (req_type)
          PMP_ACC_READ  : perm = c.r;
          PMP_ACC_WRITE : perm = c.w;
          PMP_ACC_EXEC  : perm = c.x;
          default       : perm = 1'b0;
        endcase
        // locked entries bind M-mode; unlocked ones do not restrict it
        return perm || (req_m && !c.l);
      end
    end
    return req_m;      // no match: M-mode unrestricted, others denied
  endfunction

  task automatic check();
    #1;
    ref_allow = refmodel();
    checks++;
    if (dut_allow !== ref_allow) begin
      errors++;
      if (errors <= 12) begin
        // Fields printed as raw bits: Icarus does not support .name()
        // on a struct field of an unpacked-array element.
        $display("[MISMATCH] addr=%08x type=%0d m=%b dut=%b ref=%b",
                 req_addr, req_type, req_m, dut_allow, ref_allow);
        for (int r = 0; r < N; r++) begin
          pmp_cfg_t cd;
          cd = cfg[r];
          $display("    cfg[%0d]: a=%0d l=%b rwx=%b%b%b addr=%08x",
                   r, cd.a, cd.l, cd.r, cd.w, cd.x, addr[r]);
        end
      end
    end
  endtask

  // Icarus cannot assign to a struct field of an unpacked-array element,
  // so every configuration write builds a local and stores it whole.
  task automatic set_cfg(int r, pmp_mode_e a, logic l,
                         logic rd, logic wr, logic ex, logic [31:0] ad);
    pmp_cfg_t c;
    c.a = a; c.l = l; c.r = rd; c.w = wr; c.x = ex; c.rsv = 2'b00;
    cfg[r]  = c;
    addr[r] = ad;
  endtask

  task automatic randomise_regions();
    for (int r = 0; r < N; r++) begin
      logic [31:0] ad;
      // mix NAPOT-shaped values with plain ascending bounds so both TOR
      // and NAPOT see meaningful addresses
      if ($urandom_range(0,1) == 1)
        ad = ($urandom & 32'hffff_fff0) | ((32'b1 << $urandom_range(0,7)) - 1);
      else
        ad = 32'(r) * 32'h0000_1000 + ($urandom & 32'h0000_0fff);
      set_cfg(r, pmp_mode_e'(2'($urandom_range(0,3))),
              1'($urandom_range(0,1)), 1'($urandom_range(0,1)),
              1'($urandom_range(0,1)), 1'($urandom_range(0,1)), ad);
    end
  endtask

  initial begin
    // ---- directed: first-match-wins ---------------------------------
    for (int r = 0; r < N; r++) set_cfg(r, PMP_OFF, 0, 0, 0, 0, 32'h0);
    // entry 1 would allow, entry 0 denies and is checked first
    set_cfg(0, PMP_NAPOT, 1, 0, 0, 0, 32'h0000_03ff);
    set_cfg(1, PMP_NAPOT, 1, 1, 0, 0, 32'h0000_03ff);
    req_type = PMP_ACC_READ; req_m = 1'b1;
    for (int unsigned i = 0; i < 4096; i += 4) begin req_addr = i; check(); end

    // ---- directed: NAPOT sizes at both extremes -----------------------
    // The matching region DENIES (r=0, locked so it binds M-mode) while
    // everything else is OFF, so "did this region match?" is directly
    // observable in allow_o.  With a permitting region the answer is
    // allow either way and the stimulus proves nothing -- which is how
    // an earlier version of this bench let a NAPOT mask mutation pass.
    for (int r = 1; r < N; r++) set_cfg(r, PMP_OFF, 0, 0, 0, 0, 32'h0);
    req_type = PMP_ACC_READ; req_m = 1'b1;
    for (int s = 0; s < 30; s++) begin
      logic [31:0] napot_addr, region_base, region_size;
      napot_addr  = (32'b1 << s) - 1;              // s trailing ones
      region_size = 32'b1 << (s + 1);              // in pmpaddr units
      region_base = napot_addr & ~(region_size - 1);
      set_cfg(0, PMP_NAPOT, 1, 0, 0, 0, napot_addr);
      // walk the edges of the decoded region, where an off-by-one mask
      // changes the answer
      for (int d = -2; d <= 2; d++) begin
        req_addr = (region_base + 32'(d)) << 2;                 check();
        req_addr = (region_base + region_size + 32'(d)) << 2;   check();
        req_addr = (region_base + (region_size >> 1) + 32'(d)) << 2; check();
      end
      for (int k = 0; k < 60; k++) begin req_addr = $urandom; check(); end
    end

    // ---- directed: NA4 -------------------------------------------------
    // NA4 matches exactly one 4-byte word, so random stimulus hits it
    // with probability ~2^-32 and proves nothing: an earlier version of
    // this bench let "NA4 disabled" pass unnoticed.  Probe the exact
    // word and its neighbours, with the region DENYING so a match is
    // visible in allow_o.
    for (int r = 1; r < N; r++) set_cfg(r, PMP_OFF, 0, 0, 0, 0, 32'h0);
    req_type = PMP_ACC_READ; req_m = 1'b1;
    for (int k = 0; k < 400; k++) begin
      logic [31:0] na4_pa;
      na4_pa = $urandom;
      set_cfg(0, PMP_NA4, 1, 0, 0, 0, na4_pa);
      for (int d = -2; d <= 2; d++) begin
        req_addr = (na4_pa + 32'(d)) << 2;   // exact hit at d == 0
        check();
      end
    end
    // NA4 against each access type, and against a permitting entry too
    for (int t = 0; t < 3; t++) begin
      req_type = pmp_access_e'(2'(t));
      set_cfg(0, PMP_NA4, 1, 1'(t == 0), 1'(t == 1), 1'(t == 2), 32'h0000_2000);
      req_addr = 32'h0000_2000 << 2; check();
      req_addr = 32'h0000_2001 << 2; check();
      set_cfg(0, PMP_NA4, 1, 0, 0, 0, 32'h0000_2000);
      req_addr = 32'h0000_2000 << 2; check();
    end

    // ---- directed: TOR, including entry 0's implicit zero base --------
    // Again denying, so a match is observable, and the addresses land
    // exactly ON the bounds -- an inclusive/exclusive slip only shows up
    // at req_pa == bound.
    for (int r = 0; r < N; r++)
      set_cfg(r, PMP_TOR, 1, 0, 0, 0, 32'(r + 1) * 32'h0000_0400);
    req_type = PMP_ACC_READ; req_m = 1'b1;
    for (int r = 0; r < N; r++) begin
      logic [31:0] bnd;
      bnd = 32'(r + 1) * 32'h0000_0400;
      for (int d = -2; d <= 2; d++) req_addr = (bnd + 32'(d)) << 2;
      for (int d = -2; d <= 2; d++) begin
        req_addr = (bnd + 32'(d)) << 2; check();
      end
    end
    for (int k = 0; k < 3000; k++) begin
      req_addr = ($urandom & 32'h0000_1fff); req_type = PMP_ACC_READ; check();
    end
    // and a dense sweep across the whole TOR range, every word
    for (int unsigned w = 0; w < 4096; w++) begin
      req_addr = w << 2; check();
    end

    // ---- random ---------------------------------------------------------
    for (int k = 0; k < 40000; k++) begin
      randomise_regions();
      req_addr = $urandom;
      req_type = pmp_access_e'(2'($urandom_range(0,2)));
      req_m    = 1'($urandom_range(0,1));
      check();
    end

    $display("[tb_pmp] %0d checks, %0d mismatches", checks, errors);
    $display("[tb_pmp] %s", errors == 0 ? "PASS" : "FAIL");
    $finish;
  end
endmodule
