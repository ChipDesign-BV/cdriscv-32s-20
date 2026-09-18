// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s-20 -- QSPI boot loader fault injection (finding 22).
//
// GENERATED from tb/tb_cdriscv_boot.sv by scripts/mk_fi_boot.py: the DUT,
// the flash model, the pad wiring and the ADC model are that bench's,
// verbatim, so the loader is exercised exactly as `make bootsim` exercises
// it.  What is added here is a single-cycle upset in one loader register
// and a verdict that can tell a WRONG IMAGE from a REPORTED failure.
//
// Why a dedicated bench: tb_fi builds the subsystem with BootEnable=0 --
// the loader is not even elaborated there -- so the 534-flop loader row of
// the FMEDA was the one row carried on an argument rather than a campaign
// (doc/fmeda.md section 5).  This is that campaign.
//
// The verdict needs the image, not just the exit code.  A corrupted
// PAYLOAD fails the CRC and retries, which the loader reports; the fault
// class the argument could not bound is an upset in an ADDRESS register
// AFTER the header is validated, which delivers a CRC-correct payload to
// the wrong offset and reports nothing.  So the bench hashes what the
// loader actually delivers -- address and data of every accepted write
// beat, FNV-style so order, address and data all matter -- and latches the
// hash at boot_done.  A run that raises boot_done with a hash different
// from the fault-free one is silent data corruption, however clean its
// exit code looks.
//
//   +TARGET= +BIT= +CYCLE=   the upset (see TARGETS in fi_boot_campaign.py)
//   +GOLD_I= +GOLD_N=        fault-free delivery hash and write count
//   plus tb_cdriscv_boot's own +FLASH_HEX= +MAX_CYCLES= +TRACE=

`default_nettype none
`timescale 1ns/1ps

module tb_fi_boot #(
    // sclk = clk / BootSclkDiv.  The chip builds with the default 2; the
    // coverage flow also builds a /4 bench (-GBootSclkDiv=4) because the
    // divider's count-up branch is dead at /2 -- exercised, not waived.
    parameter int unsigned BootSclkDiv = 2
);

  localparam time ClkPeriod    = 10ns;    // 100 MHz system clock
  localparam time RefClkPeriod = 1000ns;  // 1 MHz reference clock

  logic clk, rst_n;
  logic ref_clk, ref_rst_n;

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
  // Device under test -- BootEnable is left at its default 1, exactly
  // as the chip top builds it
  // ------------------------------------------------------------------
  logic        fetch_enable;
  logic        err_pin, reset_req, fault_any;

  logic        adc_start;
  logic [2:0]  adc_ch;
  logic        adc_valid;
  logic [11:0] adc_data;

  logic        ext_psel, ext_penable, ext_pwrite, ext_pready;
  logic [11:0] ext_paddr;
  logic [31:0] ext_pwdata;

  logic        core_sleep, retire_valid;
  logic        corrupt_mode;
  int          retire_count;
  logic [31:0] retire_pc, retire_instr;
  logic        tdo, tdo_oe;

  logic        qspi_sclk, qspi_cs_n;
  logic [3:0]  qspi_io_o, qspi_io_oe;
  wire  [3:0]  qspi_io;

  cdriscv_32s_20_subsys #(
      .Lockstep   (1'b1),
      .ItcmWords  (4096),
      .DtcmWords  (4096),
      .MbistAuto  (1'b0),
      .BootEnable (1'b1),     // the point of this bench
      .BootSclkDiv (BootSclkDiv)
  ) dut (
      .clk_i          (clk),
      .rst_ni         (rst_n),
      .ref_clk_i      (ref_clk),
      .ref_rst_ni     (ref_rst_n),
      .boot_addr_i    (32'h0000_0000),
      .fetch_enable_i (fetch_enable),
      .irq_i          ('0),
      .fault_ext_i    ('0),
      .err_pin_o      (err_pin),
      .reset_req_o    (reset_req),
      .fault_any_o    (fault_any),
      .adc_start_o    (adc_start),
      .adc_ch_o       (adc_ch),
      .adc_valid_i    (adc_valid),
      .adc_data_i     (adc_data),
      .dac_data_o     (),
      .dac_we_o       (),
      .atest_en_o     (),
      .atest_sel_o    (),
      .ana_flag_i     ('0),
      .ext_psel_o     (ext_psel),
      .ext_penable_o  (ext_penable),
      .ext_paddr_o    (ext_paddr),
      .ext_pwrite_o   (ext_pwrite),
      .ext_pwdata_o   (ext_pwdata),
      .ext_pstrb_o    (),
      .ext_prdata_i   (32'h0),
      .ext_pready_i   (ext_pready),
      .ext_pslverr_i  (1'b0),
      .tck_i          (1'b0),
      .tms_i          (1'b0),
      .tdi_i          (1'b0),
      .trst_ni        (1'b0),
      .tdo_o          (tdo),
      .tdo_oe_o       (tdo_oe),
      .core_sleep_o   (core_sleep),
      .retire_valid_o (retire_valid),
      .retire_pc_o    (retire_pc),
      .retire_instr_o (retire_instr),
      .qspi_sclk_o    (qspi_sclk),
      .qspi_cs_no     (qspi_cs_n),
      .qspi_io_i      (qspi_io),
      .qspi_io_o      (qspi_io_o),
      .qspi_io_oe_o   (qspi_io_oe)
  );

  // ---- QSPI pad wiring + flash --------------------------------------
  for (genvar b = 0; b < 4; b++) begin : g_pad
    assign qspi_io[b] = qspi_io_oe[b] ? qspi_io_o[b] : 1'bz;
  end

  spi_norflash_model #(.MemBytes(65536), .DummyCycles(4)) u_flash (
      .sclk_i (qspi_sclk),
      .cs_ni  (qspi_cs_n),
      .io     (qspi_io)
  );

  // ------------------------------------------------------------------
  // ADC model (the smoke program runs an AMS sequence), as in
  // tb_cdriscv_subsys
  // ------------------------------------------------------------------
  int unsigned adc_delay;

  always_ff @(posedge clk or negedge rst_n) begin
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
  // Exit register (SoC expansion slot), as in tb_cdriscv_subsys
  // ------------------------------------------------------------------
  logic        exit_seen;
  logic [31:0] exit_code;

  assign ext_pready = 1'b1;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      exit_seen <= 1'b0;
      exit_code <= 32'b0;
    end else if (ext_psel && ext_penable && ext_pwrite && (ext_paddr[7:0] == 8'h00)) begin
      exit_seen <= 1'b1;
      exit_code <= ext_pwdata;
    end
  end

  // ------------------------------------------------------------------
  // Stimulus and checks
  // ------------------------------------------------------------------
  string       flash_hex;
  int unsigned max_cycles, cycle, boot_cycle;
  bit          trace_en;
  int          errors;
  // declared here, not with the injection logic below: the boot monitor
  // above references fi_injected to stay quiet on an injected run
  int unsigned fi_target, fi_bit, fi_cycle;
  bit          fi_armed, fi_injected;

  wire boot_done  = dut.g_boot.u_boot.boot_done_o;
  wire boot_fault = dut.g_boot.u_boot.boot_fault_o;

  initial begin
    fetch_enable = 1'b0;
    errors       = 0;
    boot_cycle   = 0;

    if (!$value$plusargs("MAX_CYCLES=%d", max_cycles)) max_cycles = 600000;
    trace_en = $test$plusargs("TRACE");

    corrupt_mode = $test$plusargs("CORRUPT");
    if ($value$plusargs("FLASH_HEX=%s", flash_hex)) begin
      $display("[TB] loading flash from %s", flash_hex);
      $readmemh(flash_hex, u_flash.mem);
      if (corrupt_mode) begin
        // Flip one bit in the first payload byte (offset 0x1c).  The
        // header stays valid, so the loader reads the full image and
        // must fail the CRC -- exercising retry, sticky fault, and the
        // ungated err_pin, end to end.  In corrupt mode the timeout IS
        // the verdict point; keep it long enough for all 4 attempts.
        u_flash.mem[32'h1c] = u_flash.mem[32'h1c] ^ 8'h01;
        if (!$value$plusargs("MAX_CYCLES=%d", max_cycles)) max_cycles = 80000;
        $display("[TB] CORRUPT mode: payload bit flipped at 0x1c");
      end
    end else begin
      $display("[TB] FATAL: +FLASH_HEX not given -- an empty flash cannot boot");
      $finish;
    end

    // fetch_enable up front: the loader, not this pin, is what must
    // hold the core until the image is verified
    @(posedge rst_n);
    repeat (5) @(posedge clk);
    fetch_enable = 1'b1;
  end

  always_ff @(posedge clk) begin
    if (trace_en && retire_valid) begin
      $display("[TRACE] %8t pc=%08x instr=%08x", $time, retire_pc, retire_instr);
    end
    if (rst_n && retire_valid) retire_count++;
    if (rst_n && retire_valid && !boot_done) begin
      errors++;
      if (!fi_injected) $display("[TB] ERROR: instruction retired before boot_done (pc=%08x)", retire_pc);
    end
    if (rst_n && boot_fault) begin
      errors++;
      if (!fi_injected) $display("[TB] ERROR: boot_fault asserted");
    end
    if (boot_done && boot_cycle == 0) begin
      boot_cycle = cycle;
      $display("[TB] boot_done at cycle %0d", cycle);
    end
    if (fault_any) begin
      $display("[TB] fault reported, safety status = %08x", dut.u_safety.status_q);
    end
  end


  // ------------------------------------------------------------------
  // What the loader delivered, as an IMAGE.
  //
  // The first version of this hashed the write BEATS as they went by.
  // That was wrong, and the campaign said so: flipping a bit of the
  // running CRC produced 128 "silent corruptions" whose beat counts were
  // 320 and 434 against a fault-free 158 -- the loader had simply failed
  // its CRC, retried, and delivered the image a second time.  A retry is
  // the mechanism working, not a corruption.  So the bench keeps a
  // shadow of the memory instead: last write wins, exactly as the TCM
  // behaves, and the hash is taken over the shadow in address order at
  // boot_done.  Retrying the same bytes to the same addresses is then
  // invisible, while a word delivered to the WRONG address moves in the
  // hash -- which is the fault class this campaign exists to bound.
  // ------------------------------------------------------------------
  localparam int unsigned ShWords = 8192;          // 4096 I-TCM + 4096 D-TCM
  logic [31:0] sh_data [0:ShWords-1];
  bit          sh_val  [0:ShWords-1];
  int unsigned sh_oob;                             // beats outside both TCMs

  int unsigned sh_i;
  initial begin
    for (sh_i = 0; sh_i < ShWords; sh_i++) sh_val[sh_i] = 1'b0;
    sh_oob = 0;
  end

  function automatic int unsigned sh_index(input logic [31:0] a);
    // ItcmBase 0x0000_0000 and DtcmBase 0x1000_0000, 16 KiB each
    if (a[31:14] == 18'h00000)      sh_index = {2'b0, a[13:2]};
    else if (a[31:14] == 18'h04000) sh_index = 4096 + {2'b0, a[13:2]};
    else                            sh_index = ShWords;      // out of range
  endfunction

  always @(posedge clk) begin
    if (rst_n && dut.bt_req && dut.bt_gnt && dut.bt_we) begin
      if (sh_index(dut.bt_addr) >= ShWords) sh_oob = sh_oob + 1;
      else begin
        sh_data[sh_index(dut.bt_addr)] = dut.bt_wdata;
        sh_val [sh_index(dut.bt_addr)] = 1'b1;
      end
    end
  end

  logic [31:0] img_h, img_h_at_done;
  int unsigned img_n, img_n_at_done, oob_at_done;
  bit          done_seen;

  task automatic hash_image;
    int unsigned i;
    begin
      img_h = 32'h811c9dc5;
      img_n = 0;
      for (i = 0; i < ShWords; i++)
        if (sh_val[i]) begin
          img_h = ((img_h ^ i) * 32'h01000193) ^ sh_data[i];
          img_n = img_n + 1;
        end
    end
  endtask

  always @(posedge clk) begin
    if (rst_n && boot_done && !done_seen) begin
      done_seen     = 1'b1;
      hash_image();
      img_h_at_done = img_h;
      img_n_at_done = img_n;
      oob_at_done   = sh_oob;
    end
  end

  // ------------------------------------------------------------------
  // The upset: one bit of one loader register, deposited on a falling
  // edge (as tb_fi does -- on the rising edge the DUT's own flops
  // assign and the order is undefined, so the corruption would simply
  // be overwritten and every run would look clean).
  // ------------------------------------------------------------------
  initial begin
    done_seen   = 1'b0;
    fi_injected = 1'b0;
    if (!$value$plusargs("TARGET=%d", fi_target)) fi_target = 0;
    if (!$value$plusargs("BIT=%d",    fi_bit))    fi_bit    = 0;
    if (!$value$plusargs("CYCLE=%d",  fi_cycle))  fi_cycle  = 0;
  end

  // The arming counter is this block's own, deliberately.  Sampling the
  // bench's `cycle` here showed it taking only ODD values -- the counter
  // is incremented with `cycle++` from an initial-forever, and against
  // that this always block observes it every other edge -- so every
  // injection scheduled on an even cycle silently never landed, and
  // exactly half the campaign quietly became "not-injected".  A fault
  // injector that does nothing is the worst outcome there is: it reports
  // perfect coverage.  Count locally, non-blocking, no race.
  int unsigned fi_tick;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fi_tick  <= 0;
      fi_armed <= 1'b0;
    end else begin
      fi_tick <= fi_tick + 1;
      if (fi_tick == fi_cycle) fi_armed <= 1'b1;
    end
  end

  `define FIB(sig, w) dut.g_boot.u_boot.sig = dut.g_boot.u_boot.sig ^ ((w'b1) << (fi_bit % $bits(dut.g_boot.u_boot.sig)))

  always @(negedge clk) begin
    if (rst_n && fi_armed && !fi_injected) begin
      fi_injected = 1'b1;
      case (fi_target)
        0:  dut.g_boot.u_boot.state_q[fi_bit % 3] = ~dut.g_boot.u_boot.state_q[fi_bit % 3];
        1:  dut.g_boot.u_boot.phase_q[fi_bit % 3] = ~dut.g_boot.u_boot.phase_q[fi_bit % 3];
        2:  `FIB(cur_addr_q,  32);   // the residual the argument named
        3:  `FIB(wr_addr_q,   32);
        4:  `FIB(wr_data_q,   32);
        5:  `FIB(seg_left_q,  24);
        6:  `FIB(bytes_left_q,24);
        7:  `FIB(crc_q,       32);
        8:  `FIB(word_q,      24);
        9:  `FIB(tx_q,        32);
        10: `FIB(rx_q,         7);
        11: `FIB(hdr_q,      224);
        12: `FIB(retries_q,    4);
        13: `FIB(wdog_q,      32);
        14: case (fi_bit % 5)          // the small counters
              0: `FIB(bitcnt_q, 6);
              1: `FIB(tx1len_q, 6);
              2: `FIB(wbcnt_q,  2);
              3: `FIB(gap_q,    4);
              4: `FIB(div_q,    2);
            endcase
        15: case (fi_bit % 8)          // the single-bit flags
              0: dut.g_boot.u_boot.boot_done_q  = ~dut.g_boot.u_boot.boot_done_q;
              1: dut.g_boot.u_boot.boot_fault_q = ~dut.g_boot.u_boot.boot_fault_q;
              2: dut.g_boot.u_boot.use_quad_q   = ~dut.g_boot.u_boot.use_quad_q;
              3: dut.g_boot.u_boot.in_seg1_q    = ~dut.g_boot.u_boot.in_seg1_q;
              4: dut.g_boot.u_boot.wr_pending_q = ~dut.g_boot.u_boot.wr_pending_q;
              5: dut.g_boot.u_boot.wr_gntd_q    = ~dut.g_boot.u_boot.wr_gntd_q;
              6: dut.g_boot.u_boot.cs_n_q       = ~dut.g_boot.u_boot.cs_n_q;
              7: dut.g_boot.u_boot.sclk_q       = ~dut.g_boot.u_boot.sclk_q;
            endcase
        default: fi_injected = 1'b0;   // never claim an upset that did not land
      endcase
    end
  end

  task automatic report_fi;
    begin
      $display("FIBOOT target=%0d bit=%0d cycle=%0d inj=%0d done=%b fault=%b errpin=%b resetreq=%b exit=%08x exited=%0d retires=%0d hash=%08x nwr=%0d status=%08x oob=%0d",
               fi_target, fi_bit, fi_cycle, fi_injected, boot_done, boot_fault,
               err_pin, reset_req, exit_code, exit_seen, retire_count,
               img_h_at_done, img_n_at_done, dut.u_safety.status_q, oob_at_done);
    end
  endtask

  initial begin
    cycle = 0;
    retire_count = 0;
    forever begin
      @(posedge clk);
      cycle++;
      // One verdict line, whatever happened: a run that ends without a
      // classification is a run that quietly becomes "silent-ok".
      if (exit_seen)           begin report_fi(); $finish; end
      if (cycle >= max_cycles) begin report_fi(); $finish; end
    end
  end

endmodule

`default_nettype wire
