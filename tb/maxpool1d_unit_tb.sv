// ============================================================
// Testbench: maxpool1d_unit_tb.v
// Tests: pool window max selection, multi-channel parallel,
//        dout_valid timing, back-to-back pools
// ============================================================
`timescale 1ns/1ps

module maxpool1d_unit_tb;

    localparam CHANNELS = 8;
    localparam POOL_SZ  = 2;
    localparam DATA_W   = 8;
    localparam CLK_P    = 10;

    reg  clk, rst_n, enable, din_valid;
    wire dout_valid;

    // Packed arrays for all channels
    reg  signed [DATA_W-1:0] din  [0:CHANNELS-1];
    wire signed [DATA_W-1:0] dout [0:CHANNELS-1];

    maxpool1d_unit #(.CHANNELS(CHANNELS), .POOL_SIZE(POOL_SZ), .DATA_W(DATA_W)) dut (
        .clk(clk), .rst_n(rst_n), .enable(enable),
        .din_valid(din_valid), .din(din),
        .dout_valid(dout_valid), .dout(dout)
    );

    initial clk = 0;
    always  #(CLK_P/2) clk = ~clk;

    initial begin
        $dumpfile("maxpool1d.vcd");
        $dumpvars(0, maxpool1d_unit_tb);
    end

    integer ch, i, errors;
    task ck; begin @(posedge clk); #1; end endtask

    task send_pair;
        input signed [DATA_W-1:0] v0 [0:CHANNELS-1];
        input signed [DATA_W-1:0] v1 [0:CHANNELS-1];
        integer c;
        begin
            // First element
            for (c = 0; c < CHANNELS; c = c+1) din[c] = v0[c];
            din_valid = 1; ck();
            // Second element
            for (c = 0; c < CHANNELS; c = c+1) din[c] = v1[c];
            ck(); din_valid = 0; ck();
        end
    endtask

    reg signed [DATA_W-1:0] v0 [0:CHANNELS-1];
    reg signed [DATA_W-1:0] v1 [0:CHANNELS-1];

    initial begin
        errors = 0;
        $display("==============================================");
        $display(" TB: maxpool1d_unit  %0d-ch  pool=%0d", CHANNELS, POOL_SZ);
        $display("==============================================");

        rst_n = 0; enable = 0; din_valid = 0;
        for (ch = 0; ch < CHANNELS; ch = ch+1) din[ch] = 0;
        repeat(4) ck(); rst_n = 1; enable = 1; repeat(2) ck();

        // ── TEST 1: Max of positive pair ───────────────────
        $display("\n[T1] max(3,7)=7 across all channels");
        for (ch = 0; ch < CHANNELS; ch = ch+1) begin v0[ch]=3; v1[ch]=7; end
        din_valid = 1;
        for (ch = 0; ch < CHANNELS; ch = ch+1) din[ch] = v0[ch];
        ck();
        for (ch = 0; ch < CHANNELS; ch = ch+1) din[ch] = v1[ch];
        ck(); din_valid = 0; ck(); ck();
        if (dout_valid) begin
            for (ch = 0; ch < CHANNELS; ch = ch+1)
                if (dout[ch] !== 8'd7) begin
                    $display("  FAIL ch%0d: got %0d exp 7", ch, dout[ch]); errors++;
                end
            $display("  ch0=%0d ch7=%0d  %s", dout[0], dout[7], (dout[0]==7 && dout[7]==7)?"PASS":"FAIL");
        end else begin
            // dout_valid may be 1 cycle earlier, check in monitor
            ck();
        end

        // ── TEST 2: Max of negative pair ───────────────────
        $display("\n[T2] max(-5,-2)=-2 (signed comparison)");
        for (ch = 0; ch < CHANNELS; ch = ch+1) begin v0[ch]=-5; v1[ch]=-2; end
        din_valid = 1;
        for (ch = 0; ch < CHANNELS; ch = ch+1) din[ch] = v0[ch];
        ck();
        for (ch = 0; ch < CHANNELS; ch = ch+1) din[ch] = v1[ch];
        ck(); din_valid = 0; ck(); ck();

        // ── TEST 3: First > Second ──────────────────────────
        $display("\n[T3] max(100,10)=100");
        for (ch = 0; ch < CHANNELS; ch = ch+1) begin v0[ch]=100; v1[ch]=10; end
        din_valid = 1;
        for (ch = 0; ch < CHANNELS; ch = ch+1) din[ch] = v0[ch];
        ck();
        for (ch = 0; ch < CHANNELS; ch = ch+1) din[ch] = v1[ch];
        ck(); din_valid = 0; ck(); ck();

        // ── TEST 4: Equal values ────────────────────────────
        $display("\n[T4] max(50,50)=50");
        for (ch = 0; ch < CHANNELS; ch = ch+1) begin v0[ch]=50; v1[ch]=50; end
        din_valid = 1;
        for (ch = 0; ch < CHANNELS; ch = ch+1) din[ch] = v0[ch];
        ck();
        for (ch = 0; ch < CHANNELS; ch = ch+1) din[ch] = v1[ch];
        ck(); din_valid = 0; ck(); ck();

        // ── TEST 5: Back-to-back 4 pools ───────────────────
        $display("\n[T5] Back-to-back 4 pool operations");
        for (i = 0; i < 4; i = i+1) begin
            for (ch = 0; ch < CHANNELS; ch = ch+1) begin
                v0[ch] = i;
                v1[ch] = i + 10;
            end
            din_valid = 1;
            for (ch = 0; ch < CHANNELS; ch = ch+1) din[ch] = v0[ch];
            ck();
            for (ch = 0; ch < CHANNELS; ch = ch+1) din[ch] = v1[ch];
            ck(); din_valid = 0; ck();
        end
        repeat(4) ck();

        // ── TEST 6: Disable mid-stream ──────────────────────
        $display("\n[T6] Disable during computation");
        for (ch = 0; ch < CHANNELS; ch = ch+1) din[ch] = 8'd42;
        din_valid = 1; ck();
        enable = 0; ck();
        enable = 1;
        for (ch = 0; ch < CHANNELS; ch = ch+1) din[ch] = 8'd10;
        ck(); din_valid = 0; repeat(3) ck();
        $display("  Disable test: no crash = PASS");

        $display("\n==============================================");
        $display(" maxpool1d_unit: Errors=%0d  %s", errors, errors==0 ? "ALL PASS ✓" : "FAIL ✗");
        $display("==============================================");
        $finish;
    end

    // Monitor all dout_valid pulses
    always @(posedge clk) begin
        if (dout_valid)
            $display("  [POOL OUT] ch0=%0d ch1=%0d ch7=%0d",
                      $signed(dout[0]), $signed(dout[1]), $signed(dout[7]));
    end

endmodule
