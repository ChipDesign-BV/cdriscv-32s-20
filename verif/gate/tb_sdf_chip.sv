// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s-20 -- CHIP-level gate simulation with SDF timing (plan O8
// on the final hardened netlist, flow/runs/chip2b).
//
// The DUT is the flat post-route netlist cdriscv_32s_20_chip.nl.v: one
// module, ~335k instances, IHP pad ring included, six SRAM macros as
// the vendor behavioural model.  Everything the bench touches is a
// PAD.  The subsystem inside was hardened with BootEnable=1, so the
// core does not fetch until the QSPI loader has pulled a flash image
// through the four qspi_io pads and verified its CRC32 -- exactly the
// silicon boot path.  This bench therefore mirrors tb_cdriscv_boot
// (the RTL `bootsim`), not tb_sdf_subsys: the flash model hangs on
// the QSPI pads and holds a mkbootimg.py image; nothing is preloaded
// and nothing is forced.
//
//   +FLASH_HEX=<file>  byte-per-line flash image (scripts/mkbootimg.py)
//   +SDF=<file>        SDF, filtered by scripts/sdf_chip_filter.py
//                      (omit for a zero-delay functional run)
//   +MAX_CYCLES=<n>    give up after n clk cycles (default 400000)
//   +SIGFILE/+SIGBEGIN/+SIGEND   arch-test signature dump (below)
//
// Observation -- the retire trace and the expansion APB are not
// padded (rtl/chip/cdriscv_32s_20_chip.sv header), so:
//
//   * End of test: every program here (tb/sw/start.S and the riscof
//     model_test.h RVMODEL_HALT) ends with a store to the exit register
//     0x2000_0f00 -- APB slot 15, the SoC expansion slot.  The
//     bridge's shared address/data/penable/pwrite registers survive
//     flattening as the named nets \u_sub.ext_paddr_o[11:2],
//     \u_sub.ext_pwdata_o[31:0], \u_sub.ext_penable_o and
//     \u_sub.ext_pwrite_o (all flop outputs, verified against the
//     netlist); a write with paddr[11:8]==4'hf and paddr[7:2]==0 is
//     the exit write and pwdata its code -- the same protocol the RTL
//     benches decode at the subsystem port.  Every APB write is also
//     printed so the decode can be checked against the program.
//   * Boot: \u_sub.boot_done / \u_sub.boot_fault (flop outputs) are
//     watched for the record and for the cross-checks of the RTL boot
//     bench: no exit before boot_done, boot_fault never.
//   * Loader integrity: when boot_done rises the bench reads the flash
//     header (segment dest/len) and compares every payload word with
//     the I-TCM / D-TCM macro arrays (u_sub.u_?tcm.g_bank[b].u_bank
//     .i_SRAM_1P_behavioral_bm_bist.memory, 32 data bits per word,
//     bank = word[11], row = word[10:0]).  The loader has to have
//     written what the flash held.
//   * Pads at the verdict: err_pin_o, fault_any_o, reset_req_o must be
//     low, as in tb_cdriscv_boot.
//   * Signature: the arch subset reads the signature region back from
//     the D-TCM macro arrays after the exit write, one 32-bit word per
//     line, the format riscof compares (see scripts/gate_chip_arch.sh).
//
// Clock: 40 ns, the chip's signed-off period (flow/config_chip.json
// CLOCK_PERIOD 40 = 25 MHz, chosen for the slow corner -- V45).
// ref_clk 1 us as in the RTL benches; the clock monitor is disabled at
// reset and no program here enables it.  Timescale 1ns/1ps against an
// SDF written with (TIMESCALE 1ns).
//
// Icarus does not evaluate timing checks ($setuphold etc. are parsed
// and ignored), so what this run establishes is that the netlist with
// its annotated cell, pad, macro and wire delays still computes what
// the RTL computed at the signoff clock; a marginal setup path shows
// as a functional divergence, not as a reported violation.  Slack is
// OpenSTA's job (doc/chip.md).
//
// STATUS: O8 evidence for the chip2b netlist; see doc/verification_plan.md.

`timescale 1ns/1ps

module tb_sdf_chip;

  localparam ClkPeriod    = 40;     // ns -- chip SDC, 25 MHz
  localparam RefClkPeriod = 1000;   // ns -- 1 MHz reference

  reg clk, rst_n;
  reg ref_clk, ref_rst_n;

  initial begin
    clk = 1'b0;
    forever #(ClkPeriod/2) clk = ~clk;
  end

  initial begin
    ref_clk = 1'b0;
    forever #(RefClkPeriod/2) ref_clk = ~ref_clk;
  end

  initial begin
    rst_n     = 1'b0;
    ref_rst_n = 1'b0;
    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge ref_clk);
    ref_rst_n = 1'b1;
  end

  // ------------------------------------------------------------------
  // Device under test: the flat post-route chip netlist, pads only
  // ------------------------------------------------------------------
  reg         fetch_enable;
  reg  [13:0] irq;
  reg  [15:0] fault_ext;
  reg         adc_valid;
  reg  [11:0] adc_data;
  reg  [3:0]  ana_flag;

  wire        err_pin, reset_req, fault_any, core_sleep;
  wire        adc_start;
  wire [2:0]  adc_ch;
  wire [11:0] dac_data;
  wire        dac_we, atest_en;
  wire [3:0]  atest_sel;
  wire        tdo;
  wire        qspi_sclk, qspi_cs_n;
  wire [3:0]  qspi_io;

  cdriscv_32s_20_chip dut (
      .clk_i          (clk),
      .rst_ni         (rst_n),
      .ref_clk_i      (ref_clk),
      .ref_rst_ni     (ref_rst_n),
      .fetch_enable_i (fetch_enable),
      .irq_i          (irq),
      .fault_ext_i    (fault_ext),
      .err_pin_o      (err_pin),
      .reset_req_o    (reset_req),
      .fault_any_o    (fault_any),
      .adc_start_o    (adc_start),
      .adc_ch_o       (adc_ch),
      .adc_valid_i    (adc_valid),
      .adc_data_i     (adc_data),
      .dac_data_o     (dac_data),
      .dac_we_o       (dac_we),
      .atest_en_o     (atest_en),
      .atest_sel_o    (atest_sel),
      .ana_flag_i     (ana_flag),
      // JTAG parked; trst_ni LOW so the tck-domain flops are reset
      // rather than left X (as in tb_sdf_subsys)
      .tck_i          (1'b0),
      .tms_i          (1'b0),
      .tdi_i          (1'b0),
      .trst_ni        (1'b0),
      .tdo_o          (tdo),
      .core_sleep_o   (core_sleep),
      .qspi_sclk_o    (qspi_sclk),
      .qspi_cs_no     (qspi_cs_n),
      .qspi_io        (qspi_io)
  );

  // ---- QSPI flash on the pads ---------------------------------------
  // The chip's four InOut pads drive qspi_io only while the loader's
  // io_oe bit is set (pad = c2p_en ? c2p : z); the flash drives during
  // data phases; nothing else touches the bus, so a fight shows as X
  // at the receiver, not as a lucky pass (tb_cdriscv_boot).
  spi_norflash_model #(.MemBytes(65536), .DummyCycles(4)) u_flash (
      .sclk_i (qspi_sclk),
      .cs_ni  (qspi_cs_n),
      .io     (qspi_io)
  );

  // ------------------------------------------------------------------
  // SDF annotation -- before time advances
  // ------------------------------------------------------------------
  reg [1023:0] sdf_file;
  initial begin
    if ($value$plusargs("SDF=%s", sdf_file)) begin
      $sdf_annotate(sdf_file, dut);
      $display("[TB-CHIP] annotated %0s", sdf_file);
    end else begin
      $display("[TB-CHIP] running WITHOUT SDF annotation (cell zero-delays)");
    end
  end

  // ------------------------------------------------------------------
  // Internal nets that survive flattening (names verified in the
  // netlist: all are sg13g2_dfrbpq_1 Q outputs)
  // ------------------------------------------------------------------
  wire boot_done   = dut.\u_sub.boot_done ;
  wire boot_fault  = dut.\u_sub.boot_fault ;
  wire ext_penable = dut.\u_sub.ext_penable_o ;
  wire ext_pwrite  = dut.\u_sub.ext_pwrite_o ;
  wire [11:2] ext_paddr = {
      dut.\u_sub.ext_paddr_o[11] , dut.\u_sub.ext_paddr_o[10] ,
      dut.\u_sub.ext_paddr_o[9]  , dut.\u_sub.ext_paddr_o[8]  ,
      dut.\u_sub.ext_paddr_o[7]  , dut.\u_sub.ext_paddr_o[6]  ,
      dut.\u_sub.ext_paddr_o[5]  , dut.\u_sub.ext_paddr_o[4]  ,
      dut.\u_sub.ext_paddr_o[3]  , dut.\u_sub.ext_paddr_o[2]  };
  wire [31:0] ext_pwdata = {
      dut.\u_sub.ext_pwdata_o[31] , dut.\u_sub.ext_pwdata_o[30] ,
      dut.\u_sub.ext_pwdata_o[29] , dut.\u_sub.ext_pwdata_o[28] ,
      dut.\u_sub.ext_pwdata_o[27] , dut.\u_sub.ext_pwdata_o[26] ,
      dut.\u_sub.ext_pwdata_o[25] , dut.\u_sub.ext_pwdata_o[24] ,
      dut.\u_sub.ext_pwdata_o[23] , dut.\u_sub.ext_pwdata_o[22] ,
      dut.\u_sub.ext_pwdata_o[21] , dut.\u_sub.ext_pwdata_o[20] ,
      dut.\u_sub.ext_pwdata_o[19] , dut.\u_sub.ext_pwdata_o[18] ,
      dut.\u_sub.ext_pwdata_o[17] , dut.\u_sub.ext_pwdata_o[16] ,
      dut.\u_sub.ext_pwdata_o[15] , dut.\u_sub.ext_pwdata_o[14] ,
      dut.\u_sub.ext_pwdata_o[13] , dut.\u_sub.ext_pwdata_o[12] ,
      dut.\u_sub.ext_pwdata_o[11] , dut.\u_sub.ext_pwdata_o[10] ,
      dut.\u_sub.ext_pwdata_o[9]  , dut.\u_sub.ext_pwdata_o[8]  ,
      dut.\u_sub.ext_pwdata_o[7]  , dut.\u_sub.ext_pwdata_o[6]  ,
      dut.\u_sub.ext_pwdata_o[5]  , dut.\u_sub.ext_pwdata_o[4]  ,
      dut.\u_sub.ext_pwdata_o[3]  , dut.\u_sub.ext_pwdata_o[2]  ,
      dut.\u_sub.ext_pwdata_o[1]  , dut.\u_sub.ext_pwdata_o[0]  };

  // TCM macro arrays: word w -> bank w[11], row w[10:0], 32 data bits.
  function [31:0] itcm_word(input [11:0] w);
    if (w[11]) itcm_word = dut.\u_sub.u_itcm.g_bank[1].u_bank .i_SRAM_1P_behavioral_bm_bist.memory[w[10:0]];
    else       itcm_word = dut.\u_sub.u_itcm.g_bank[0].u_bank .i_SRAM_1P_behavioral_bm_bist.memory[w[10:0]];
  endfunction

  function [31:0] dtcm_word(input [11:0] w);
    if (w[11]) dtcm_word = dut.\u_sub.u_dtcm.g_bank[1].u_bank .i_SRAM_1P_behavioral_bm_bist.memory[w[10:0]];
    else       dtcm_word = dut.\u_sub.u_dtcm.g_bank[0].u_bank .i_SRAM_1P_behavioral_bm_bist.memory[w[10:0]];
  endfunction

  // little-endian 32-bit word at flash word index widx
  function [31:0] flash_word(input integer widx);
    flash_word = {u_flash.mem[4*widx+3], u_flash.mem[4*widx+2],
                  u_flash.mem[4*widx+1], u_flash.mem[4*widx]};
  endfunction

  // ------------------------------------------------------------------
  // Minimal ADC model on the pads, as in the RTL benches (the smoke
  // program runs an AMS one-shot sequence and waits for it)
  // ------------------------------------------------------------------
  integer adc_delay;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      adc_valid <= 1'b0;
      adc_data  <= 12'b0;
      adc_delay <= 0;
    end else begin
      adc_valid <= 1'b0;
      if (adc_start) begin
        adc_delay <= 20;
      end else if (adc_delay > 1) begin
        adc_delay <= adc_delay - 1;
      end else if (adc_delay == 1) begin
        adc_delay <= 0;
        adc_valid <= 1'b1;
        adc_data  <= 12'h100 + {9'b0, adc_ch};
      end
    end
  end

  // ------------------------------------------------------------------
  // Exit write decode on the surviving APB bridge registers
  // ------------------------------------------------------------------
  reg        exit_seen;
  reg [31:0] exit_code;
  integer    apb_writes;
  integer    max_cycles, cycle, boot_cycle, errors;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      exit_seen  <= 1'b0;
      exit_code  <= 32'b0;
      apb_writes <= 0;
    end else if (ext_penable === 1'b1 && ext_pwrite === 1'b1) begin
      apb_writes <= apb_writes + 1;
      $display("[TB-CHIP] APB write @%0d: slot %0d offset 0x%02x data %08x",
               cycle, ext_paddr[11:8], {ext_paddr[7:2], 2'b00}, ext_pwdata);
      $fflush();
      if (ext_paddr[11:8] == 4'hf && ext_paddr[7:2] == 6'b0) begin
        exit_seen <= 1'b1;
        exit_code <= ext_pwdata;
      end
    end
  end

  // ------------------------------------------------------------------
  // Run control, boot tracking, loader integrity check
  // ------------------------------------------------------------------
  reg [1023:0] flash_hex;
  integer img_mismatch, img_words;
  reg     img_checked;

  task check_loaded_image;
    integer seg0_dest, seg0_len, seg1_dest, seg1_len, i, n0, n1;
    reg [31:0] exp, got;
    begin
      seg0_dest = flash_word(2); seg0_len = flash_word(3);
      seg1_dest = flash_word(4); seg1_len = flash_word(5);
      n0 = seg0_len / 4; n1 = seg1_len / 4;
      img_mismatch = 0; img_words = 0;
      for (i = 0; i < n0; i = i + 1) begin
        exp = flash_word(7 + i);
        if (seg0_dest[31:28] == 4'h1) got = dtcm_word((seg0_dest[13:2]) + i);
        else                          got = itcm_word((seg0_dest[13:2]) + i);
        img_words = img_words + 1;
        if (got !== exp) begin
          img_mismatch = img_mismatch + 1;
          if (img_mismatch <= 5)
            $display("[TB-CHIP] IMAGE MISMATCH seg0 word %0d: tcm %08x flash %08x", i, got, exp);
        end
      end
      for (i = 0; i < n1; i = i + 1) begin
        exp = flash_word(7 + n0 + i);
        if (seg1_dest[31:28] == 4'h1) got = dtcm_word((seg1_dest[13:2]) + i);
        else                          got = itcm_word((seg1_dest[13:2]) + i);
        img_words = img_words + 1;
        if (got !== exp) begin
          img_mismatch = img_mismatch + 1;
          if (img_mismatch <= 5)
            $display("[TB-CHIP] IMAGE MISMATCH seg1 word %0d: tcm %08x flash %08x", i, got, exp);
        end
      end
      $display("[TB-CHIP] loaded image check: seg0 %0d words @%08x, seg1 %0d words @%08x, %0d mismatches",
               n0, seg0_dest, n1, seg1_dest, img_mismatch);
      if (img_mismatch != 0) errors = errors + 1;
      $fflush();
    end
  endtask

  initial begin
    fetch_enable = 1'b0;
    irq          = 14'b0;
    fault_ext    = 16'b0;
    ana_flag     = 4'b0;
    errors       = 0;
    boot_cycle   = 0;
    img_checked  = 1'b0;
    img_mismatch = -1;
    img_words    = 0;
    if (!$value$plusargs("MAX_CYCLES=%d", max_cycles)) max_cycles = 400000;
    if ($value$plusargs("FLASH_HEX=%s", flash_hex)) begin
      $display("[TB-CHIP] loading flash from %0s", flash_hex);
      $readmemh(flash_hex, u_flash.mem);
    end else begin
      $display("[TB-CHIP] FATAL: +FLASH_HEX not given -- an empty flash cannot boot");
      $finish;
    end
    // fetch_enable up front: the loader, not this pin, holds the core
    @(posedge rst_n);
    repeat (5) @(posedge clk);
    fetch_enable = 1'b1;
  end

  always @(posedge clk) if (rst_n) begin
    if (boot_fault === 1'b1 && errors == 0) begin
      errors = errors + 1;
      $display("[TB-CHIP] ERROR: boot_fault asserted at cycle %0d", cycle);
    end
    if (boot_done === 1'b1 && boot_cycle == 0) begin
      boot_cycle = cycle;
      $display("[TB-CHIP] boot_done at cycle %0d (%0t)", cycle, $time);
      $fflush();
    end
    // two cycles after boot_done: every loader write has landed and
    // the core has not reached its first store yet
    if (boot_cycle != 0 && !img_checked && cycle == boot_cycle + 2) begin
      img_checked = 1'b1;
      check_loaded_image;
    end
    if (exit_seen && boot_done !== 1'b1) begin
      errors = errors + 1;
      $display("[TB-CHIP] ERROR: exit write before boot_done");
    end
  end

  initial begin
    cycle = 0;
    forever begin
      @(posedge clk);
      cycle = cycle + 1;
      if (cycle % 5000 == 0)
        $display("[TB-CHIP] cycle %0d (%0t): boot_done=%b boot_fault=%b fault_any=%b err_pin=%b core_sleep=%b apb_writes=%0d",
                 cycle, $time, boot_done, boot_fault, fault_any, err_pin, core_sleep, apb_writes);
      if (cycle % 5000 == 0) $fflush();
      if (exit_seen) begin
        $display("[TB-CHIP] pads at exit: err_pin=%b fault_any=%b reset_req=%b core_sleep=%b",
                 err_pin, fault_any, reset_req, core_sleep);
        if (exit_code == 32'b0 && errors == 0 && img_checked && img_mismatch == 0 &&
            boot_done === 1'b1 && err_pin === 1'b0 && fault_any === 1'b0 && reset_req === 1'b0)
          $display("[TB-CHIP] PASS after %0d cycles (boot at %0d)", cycle, boot_cycle);
        else
          $display("[TB-CHIP] FAIL, exit code %08x, %0d bench errors, image mismatches %0d, err_pin=%b fault_any=%b reset_req=%b",
                   exit_code, errors, img_mismatch, err_pin, fault_any, reset_req);
        dump_signature;
        $finish;
      end
      if (cycle >= max_cycles) begin
        $display("[TB-CHIP] TIMEOUT after %0d cycles (boot_done=%b boot_fault=%b apb_writes=%0d)",
                 cycle, boot_done, boot_fault, apb_writes);
        $finish;
      end
    end
  end

  // ------------------------------------------------------------------
  // Signature dump for the arch-test subset: the data word of each
  // D-TCM code word in [SIGBEGIN, SIGEND), one per line, the format
  // riscof compares.  Byte addresses in the D-TCM window (0x1000_0000).
  // ------------------------------------------------------------------
  integer sig_begin, sig_end, sig_fd, w;
  reg [1023:0] sig_file;

  task dump_signature;
    begin
      if ($value$plusargs("SIGFILE=%s", sig_file) &&
          $value$plusargs("SIGBEGIN=%h", sig_begin) &&
          $value$plusargs("SIGEND=%h", sig_end)) begin
        sig_fd = $fopen(sig_file, "w");
        for (w = (sig_begin - 'h10000000) >> 2;
             w < (sig_end - 'h10000000) >> 2; w = w + 1)
          $fdisplay(sig_fd, "%08x", dtcm_word(w[11:0]));
        $fclose(sig_fd);
        $display("[TB-CHIP] signature written to %0s", sig_file);
      end
    end
  endtask

endmodule
