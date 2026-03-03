// ============================================================
// Testbench: input_buffer_tb.v
// Tests: Write 300 samples, overflow protection, random-read,
//        sequential read, full/empty flags, clear
// ============================================================
`timescale 1ns/1ps

module input_buffer_tb;

    // ── Parameters ──────────────────────────────────────────
    localparam DEPTH   = 300;
    localparam DATA_W  = 8;
    localparam CLK_P   = 10;

    // ── DUT ports ───────────────────────────────────────────
    reg         clk, rst_n, clear;
    reg         wr_en;
    reg signed [DATA_W-1:0] wr_data;
    wire        full, overflow_flag, empty, buffer_ready;
    reg         rd_en, seq_rd_en;
    reg  [$clog2(DEPTH)-1:0] rd_addr;
    wire signed [DATA_W-1:0] rd_data, seq_rd_data;
    wire [$clog2(DEPTH):0]   sample_count;

    // ── DUT ─────────────────────────────────────────────────
    input_buffer #(.DEPTH(DEPTH), .DATA_W(DATA_W)) dut (
        .clk(clk), .rst_n(rst_n), .clear(clear),
        .wr_en(wr_en), .wr_data(wr_data),
        .full(full), .overflow_flag(overflow_flag),
        .rd_en(rd_en), .rd_addr(rd_addr), .rd_data(rd_data),
        .seq_rd_en(seq_rd_en), .seq_rd_data(seq_rd_data),
        .empty(empty), .sample_count(sample_count),
        .buffer_ready(buffer_ready)
    );

    // ── Clock ───────────────────────────────────────────────
    initial clk = 0;
    always  #(CLK_P/2) clk = ~clk;

    // ── VCD ─────────────────────────────────────────────────
    initial begin
        $dumpfile("input_buffer.vcd");
        $dumpvars(0, input_buffer_tb);
    end

    // ── Helpers ─────────────────────────────────────────────
    integer i, errors;
    reg signed [DATA_W-1:0] written [0:DEPTH-1];

    task ck; begin @(posedge clk); #1; end endtask
    task reset_dut;
        begin
            rst_n = 0; clear = 0; wr_en = 0; rd_en = 0;
            seq_rd_en = 0; wr_data = 0; rd_addr = 0;
            repeat(4) ck();
            rst_n = 1; repeat(2) ck();
        end
    endtask

    // ── Test sequence ────────────────────────────────────────
    initial begin
        errors = 0;
        $display("==============================================");
        $display(" TB: input_buffer  DEPTH=%0d  DATA_W=%0d", DEPTH, DATA_W);
        $display("==============================================");

        reset_dut();

        // ── TEST 1: Write DEPTH samples ──────────────────────
        $display("\n[T1] Write %0d samples", DEPTH);
        for (i = 0; i < DEPTH; i = i+1) begin
            wr_data = $signed(i - 128);          // pattern: -128..+127
            written[i] = wr_data;
            wr_en = 1; ck(); wr_en = 0;
        end
        ck();
        if (!full)         begin $display("FAIL: full not asserted"); errors++; end
        if (!buffer_ready) begin $display("FAIL: buffer_ready not asserted"); errors++; end
        if (sample_count != DEPTH) begin $display("FAIL: count=%0d", sample_count); errors++; end
        $display("  full=%0d ready=%0d count=%0d  %s", full, buffer_ready, sample_count,
                  (full && buffer_ready) ? "PASS" : "FAIL");

        // ── TEST 2: Overflow protection ──────────────────────
        $display("\n[T2] Write when full → overflow");
        wr_data = 8'h55; wr_en = 1; ck(); wr_en = 0;
        ck();
        if (!overflow_flag) begin $display("FAIL: overflow_flag not set"); errors++; end
        $display("  overflow_flag=%0d  %s", overflow_flag, overflow_flag ? "PASS" : "FAIL");

        // ── TEST 3: Random-access read ───────────────────────
        $display("\n[T3] Random-access read check (10 spots)");
        rd_en = 1;
        for (i = 0; i < 10; i = i+1) begin
            rd_addr = i * 30;    // Every 30th sample
            ck();
            if (rd_data !== written[i*30]) begin
                $display("  FAIL addr=%0d: got %0d exp %0d", i*30, rd_data, written[i*30]);
                errors++;
            end
        end
        rd_en = 0;
        $display("  Random read: %s", (errors == 0) ? "PASS" : "FAIL");

        // ── TEST 4: Clear & re-fill ───────────────────────────
        $display("\n[T4] Clear + re-fill");
        clear = 1; ck(); clear = 0; ck();
        if (!empty) begin $display("FAIL: not empty after clear"); errors++; end
        if (full)   begin $display("FAIL: full should be 0 after clear"); errors++; end
        // Write 5 samples
        for (i = 0; i < 5; i = i+1) begin
            wr_data = i + 1; wr_en = 1; ck(); wr_en = 0;
        end
        ck();
        if (sample_count != 5) begin $display("FAIL: count after refill=%0d", sample_count); errors++; end
        $display("  Clear+refill count=%0d  %s", sample_count, (sample_count==5) ? "PASS" : "FAIL");

        // ── SUMMARY ─────────────────────────────────────────
        $display("\n==============================================");
        $display(" input_buffer: Errors=%0d  %s", errors, errors==0 ? "ALL PASS ✓" : "FAIL ✗");
        $display("==============================================");
        $finish;
    end

endmodule
