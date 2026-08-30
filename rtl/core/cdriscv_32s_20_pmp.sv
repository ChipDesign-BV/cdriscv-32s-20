// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s-20 -- physical memory protection.
//
// Machine-mode PMP to the privileged specification: NRegions entries,
// each an 8-bit pmpcfg and a 34-bit-equivalent pmpaddr (RV32 stores
// address[33:2], so the register holds the address shifted right by 2).
//
// Why a safety core wants this even with no user mode: PMP is the
// mechanism that gives freedom from interference between software
// partitions of different ASIL, which ISO 26262 requires when mixed-
// criticality software shares one core.  Without it the argument has to
// be made entirely in software.
//
// Matching rules, in the order the spec mandates:
//  * entries are checked LOW index first and the FIRST match wins --
//    not the most permissive, not the most restrictive;
//  * a locked entry (cfg.l) applies to machine mode too and cannot be
//    rewritten until reset.  Unlocked entries do not restrict machine
//    mode, which is why mmwp-style behaviour needs an explicit
//    catch-all entry;
//  * TOR compares against the PREVIOUS entry's address, and entry 0's
//    lower bound is zero;
//  * NAPOT decodes the trailing ones of pmpaddr to a size; NA4 is the
//    degenerate 4-byte case.
//
// STATUS: block-verified (doc/variant_status.md, section 2) and
// instantiated by the subsystem.  No signoff gate is met in this
// repository -- see README.md.  NOT qualified for safety-critical use.

`default_nettype none

module cdriscv_32s_20_pmp
  import cdriscv_32s_20_pkg::*;
#(
    parameter int unsigned NRegions = 8
) (
    // configuration, driven from the CSR file
    input  pmp_cfg_t             cfg_i   [NRegions],
    input  logic [31:0]          addr_i  [NRegions],   // pmpaddr (addr>>2)

    // access under test
    input  logic [31:0]          req_addr_i,
    input  pmp_access_e          req_type_i,
    input  logic                 req_machine_i,        // 1 = M-mode

    output logic                 allow_o
);

  logic [NRegions-1:0] match, perm, lock, unused_rsv;

  // Everything below works in pmpaddr space -- the byte address shifted
  // right by 2 -- which is the format pmpaddr itself holds.  Mixing byte
  // and word addresses here is the classic source of off-by-four PMP
  // bugs, so the conversion happens exactly once.
  logic [31:0] req_pa;
  assign req_pa = {2'b00, req_addr_i[31:2]};

  for (genvar r = 0; r < NRegions; r++) begin : g_region
    // cfg_i[r] is copied into a local before its fields are used: Icarus
    // aborts on a struct-field select into an element of an unpacked
    // array, and the plan runs it beside Verilator (findings V0-F4).
    pmp_cfg_t    c;
    logic [31:0] a, napot_mask, napot_base;
    logic        lower_ok;
    assign c          = cfg_i[r];
    assign lock[r]    = c.l;
    // pmpcfg[6:5] are reserved by the spec and read as zero.
    assign unused_rsv[r] = |c[6:5];
    assign a = addr_i[r];

    // TOR lower bound is the previous entry; entry 0 starts at zero.
    // Entry 0's bound is therefore not a comparison at all -- an
    // unsigned address is always >= 0 -- so it is written as a constant
    // rather than as a compare that folds.  Stating it structurally
    // keeps the intent in the RTL instead of in a comment beside a
    // warning.
    if (r == 0) begin : g_tor0
      assign lower_ok = 1'b1;
    end else begin : g_torn
      assign lower_ok = (req_pa >= addr_i[r-1]);
    end

    // NAPOT size comes from the trailing ones of pmpaddr: the lowest
    // zero bit sets the mask.  NA4 is the degenerate all-ones mask.
    logic mask_found;
    always_comb begin
      napot_mask = 32'hffff_ffff;   // NA4: exact match
      mask_found = 1'b0;
      if (c.a == PMP_NAPOT) begin
        for (int unsigned i = 0; i < 32; i++)
          if (a[i] == 1'b0 && !mask_found) begin
            napot_mask = 32'hffff_ffff << (i + 1);
            mask_found = 1'b1;
          end
      end
    end
    assign napot_base = a & napot_mask;

    always_comb begin
      unique case (c.a)
        PMP_OFF   : match[r] = 1'b0;
        PMP_TOR   : match[r] = lower_ok && (req_pa < a);
        PMP_NA4   : match[r] = (req_pa == a);
        PMP_NAPOT : match[r] = ((req_pa & napot_mask) == napot_base);
        default   : match[r] = 1'b0;
      endcase
    end

    always_comb begin
      unique case (req_type_i)
        PMP_ACC_READ  : perm[r] = c.r;
        PMP_ACC_WRITE : perm[r] = c.w;
        PMP_ACC_EXEC  : perm[r] = c.x;
        default       : perm[r] = 1'b0;
      endcase
    end
  end

  // ---- first match wins ------------------------------------------------
  logic matched, granted;
  always_comb begin
    matched = 1'b0;
    granted = 1'b0;
    for (int unsigned r = 0; r < NRegions; r++) begin
      if (!matched && match[r]) begin
        matched = 1'b1;
        // A locked entry binds machine mode as well; an unlocked one
        // does not constrain M-mode at all.
        granted = perm[r] || (req_machine_i && !lock[r]);
      end
    end
    // No entry matched: machine mode is unrestricted, anything else is
    // denied.  (With no U-mode implemented req_machine_i is tied high,
    // and this reduces to "unmatched is allowed".)
    if (!matched) granted = req_machine_i;
  end

  assign allow_o = granted;

  // PMP granularity is 4 bytes, so the byte offset never participates;
  // pmpcfg bits [6:5] are reserved by the spec and read as zero.
  logic unused;
  assign unused = |req_addr_i[1:0] | |unused_rsv;

endmodule
