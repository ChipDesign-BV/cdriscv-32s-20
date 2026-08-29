// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s-10 v2 -- instruction realignment and decompression.
//
// Sits between the word-level prefetcher (which variant 1 already has,
// and which is unchanged) and the decode stage.  It consumes a stream
// of 32-bit words and produces a stream of 32-bit instructions at
// 16-bit granularity, expanding Zca/Zcb on the way.
//
// Why this is a separate module.  The prefetcher's job -- one
// outstanding OBI transaction, a two-entry buffer, redirect with
// in-flight discard -- is orthogonal to instruction length, and it was
// verified that way (V49, tb_if_equiv, 200 038 checks).  Making it
// halfword-aware would have meant re-verifying all of it.  Realignment
// is instead a pure downstream transform of the word stream, with its
// own state and its own bench.
//
// The four cases, given a position that is either the low or the high
// halfword of the incoming word:
//
//   low,  compressed    -- emit, stay on the same word, move to high
//   low,  uncompressed  -- emit the whole word, consume it, stay low
//   high, compressed    -- emit, consume the word, move to low
//   high, uncompressed  -- STRADDLE: the instruction's upper half is in
//                          this word and its lower half is in the next
//                          one.  Latch, consume, and emit when the next
//                          word arrives.
//
// The straddle is the whole difficulty, and in this design it is worse
// than the usual RISC-V one: a fetch word is one SEC-DED code word, so
// a straddling instruction is covered by *two independent* code words
// with independent error status.  `instr_err_o` for such an instruction
// is the OR of the two, because either one being uncorrectable makes
// the instruction untrustworthy.
//
// A known limitation, recorded rather than hidden: instruction length
// is read from bits [1:0] of the first halfword, and those bits live in
// the same code word as the rest of it.  An uncorrectable error there
// makes the *length* untrustworthy too, so the realigner may mis-split
// the following bytes.  That is contained rather than solved: the
// instruction is delivered with err=1, the core traps on it, and the
// trap redirect re-establishes alignment from `mepc`.  Nothing
// mis-split is ever executed, but the mis-split does happen.
//
// STATUS: variant 2, not integrated, not part of any signoff gate.

`default_nettype none

module cdriscv_32s_20_if_align (
    input  logic        clk_i,
    input  logic        rst_ni,

    // Redirect: discard all state and resume at redirect_pc_i, which is
    // halfword aligned.  The upstream prefetcher is flushed by the same
    // signal, so the next word to arrive is the one containing it.
    input  logic        redirect_i,
    input  logic [31:0] redirect_pc_i,

    // word stream in
    input  logic        word_valid_i,
    input  logic [31:0] word_rdata_i,
    input  logic [31:0] word_pc_i,      // word-aligned address of word_rdata_i
    input  logic        word_err_i,     // uncorrectable ECC / bus error
    output logic        word_ready_o,

    // instruction stream out
    output logic        instr_valid_o,
    output logic [31:0] instr_rdata_o,      // always 32 bits, expanded
    output logic [31:0] instr_pc_o,         // address of the FIRST halfword
    output logic        instr_err_o,
    output logic        instr_illegal_o,    // illegal compressed encoding
    output logic        instr_compressed_o,
    input  logic        instr_ready_i
);

  // ------------------------------------------------------------------
  // State
  // ------------------------------------------------------------------
  // half_q: the next instruction starts at the high halfword of the
  //         word currently being presented.
  // strad_q: holding the low half of a straddling instruction, waiting
  //         for the word that carries its high half.
  logic        half_q;
  logic        strad_q;
  logic [15:0] strad_data_q;
  logic [31:0] strad_pc_q;
  logic        strad_err_q;

  // ------------------------------------------------------------------
  // The halfword under consideration, and its length
  // ------------------------------------------------------------------
  logic [15:0] hw;
  logic        hw_uncompressed;
  logic [31:0] hw_pc;

  always_comb begin
    if (half_q) hw = word_rdata_i[31:16];
    else        hw = word_rdata_i[15:0];
  end

  assign hw_uncompressed = (hw[1:0] == 2'b11);
  assign hw_pc           = {word_pc_i[31:2], half_q, 1'b0};

  // ------------------------------------------------------------------
  // Decompressor
  // ------------------------------------------------------------------
  logic [31:0] dec_instr;
  logic        dec_illegal;

  cdriscv_32s_20_decompress u_decompress (
      .instr_i   (hw),
      .instr_o   (dec_instr),
      .illegal_o (dec_illegal)
  );

  // ------------------------------------------------------------------
  // Output selection
  // ------------------------------------------------------------------
  // Four mutually exclusive shapes.  `emit_straddle` needs the incoming
  // word for its low half; the other three read the current position.
  logic emit_straddle;   // completing a held instruction
  logic emit_compressed; // 16-bit at the current position
  logic emit_full;       // 32-bit, wholly inside this word (low half)
  logic start_straddle;  // 32-bit starting at the high half: latch, no output

  assign emit_straddle   =  strad_q && word_valid_i;
  assign emit_compressed = !strad_q && word_valid_i && !hw_uncompressed;
  assign emit_full       = !strad_q && word_valid_i &&  hw_uncompressed && !half_q;
  assign start_straddle  = !strad_q && word_valid_i &&  hw_uncompressed &&  half_q;

  always_comb begin
    instr_valid_o      = emit_straddle || emit_compressed || emit_full;
    instr_rdata_o      = word_rdata_i;
    instr_pc_o         = hw_pc;
    instr_err_o        = word_err_i;
    instr_illegal_o    = 1'b0;
    instr_compressed_o = 1'b0;

    if (emit_straddle) begin
      instr_rdata_o      = {word_rdata_i[15:0], strad_data_q};
      instr_pc_o         = strad_pc_q;
      // Two code words cover this instruction; either failing makes it
      // untrustworthy.
      instr_err_o        = strad_err_q || word_err_i;
      instr_compressed_o = 1'b0;
    end else if (emit_compressed) begin
      instr_rdata_o      = dec_instr;
      instr_illegal_o    = dec_illegal;
      instr_compressed_o = 1'b1;
    end
  end

  // ------------------------------------------------------------------
  // Word consumption
  // ------------------------------------------------------------------
  // The word is released when nothing further is needed from it:
  //   - completing a straddle takes only its LOW half, so it is kept
  //     and the position becomes its high half
  //   - a compressed instruction in the low half leaves the high half
  //   - everything else finishes the word
  logic accept;
  assign accept = instr_valid_o && instr_ready_i;

  always_comb begin
    word_ready_o = 1'b0;
    if (start_straddle)                    word_ready_o = 1'b1;
    else if (accept && emit_straddle)      word_ready_o = 1'b0;
    else if (accept && emit_compressed)    word_ready_o = half_q;
    else if (accept && emit_full)          word_ready_o = 1'b1;
  end

  // ------------------------------------------------------------------
  // Sequential state
  // ------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      half_q       <= 1'b0;
      strad_q      <= 1'b0;
      strad_data_q <= 16'b0;
      strad_pc_q   <= 32'b0;
      strad_err_q  <= 1'b0;
    end else if (redirect_i) begin
      // A redirect may land on an odd halfword (a compressed branch
      // target).  Any held straddle belongs to the abandoned stream.
      half_q       <= redirect_pc_i[1];
      strad_q      <= 1'b0;
      strad_data_q <= 16'b0;
      strad_pc_q   <= 32'b0;
      strad_err_q  <= 1'b0;
    end else begin
      if (start_straddle) begin
        strad_q      <= 1'b1;
        strad_data_q <= word_rdata_i[31:16];
        strad_pc_q   <= hw_pc;
        strad_err_q  <= word_err_i;
        half_q       <= 1'b0;
      end else if (accept) begin
        if (emit_straddle) begin
          // its low half came from this word; the high half is next
          strad_q <= 1'b0;
          half_q  <= 1'b1;
        end else if (emit_compressed) begin
          half_q  <= ~half_q;
        end
        // emit_full leaves half_q at 0
      end
    end
  end

endmodule

`default_nettype wire
