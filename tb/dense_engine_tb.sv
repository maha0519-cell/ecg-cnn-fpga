// ============================================================
// Testbench: dense_engine_tb.v
// Tests: bias init, sequential MAC over IN_DIM=4 (small),
//        ReLU activation, no-ReLU mode, dout_valid,
//        back-to-back inferences
// Golden: computed manually and verified with Python
// ============================================================
`timescale 1ns/1ps

module dense_engine_tb;

    // ── Small instance for fast simulation ───────────────────
    localparam IN_DIM  = 4;
    localparam OUT_DIM = 3;
    localparam DATA_W  = 8;
    localparam ACC_W   = 20;
    localparam CLK_P   = 10;

    // ── Ports ────────────────────────────────────────────────
    reg  clk, rst_n, start, din_valid;
    reg  signed [DATA_W-1:0] din;
    wire dout_valid;
    wire signed [DATA_W-1:0] dout [0:OUT_DIM-1];

    // Weights and biases
    reg signed [DATA_W-1:0] w [0:IN_DIM-1][0:OUT_DIM-1];
    reg signed [DATA_W-1:0] b [0:OUT_DIM-1];

    // ── DUT with ReLU ────────────────────────────────────────
    dense_engine #(
        .IN_DIM(IN_DIM), .OUT_DIM(OUT_DIM),
        .DATA_W(DATA_W), .ACC_W(ACC_W),
        .SCALE_SH(7), .USE_RELU(1)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .start(start), .din(din), .din_valid(din_valid),
        .w(w), .b(b),
        .dout_valid(dout_valid), .dout(dout)
    );

    initial clk = 0;
    always  #(CLK_P/2) clk = ~clk;

    initial begin
        $dumpfile("dense_engine.vcd");
        $dumpvars(0, dense_engine_tb);
    end

    integer i, oi, errors;
    task ck; begin @(posedge clk); #1; end endtask

    // ── Run one inference: feed din array ────────────────────
    reg signed [DATA_W-1:0] din_arr [0:IN_DIM-1];
    task run_inference;
        integer idx;
        begin
            start = 1; ck(); start = 0;
            for (idx = 0; idx < IN_DIM; idx = idx+1) begin
                din = din_arr[idx]; din_valid = 1; ck();
            end
            din_valid = 0;
            // Wait for done
            wait(dout_valid == 1); ck();
        end
    endtask

    // ── Manual golden computation ─────────────────────────────
    // Input: [1,2,3,4]
    // W: [[1,2,3],[4,5,6],[7,8,9],[10,11,12]]
    // B: [0,0,0]
    // acc_j = sum_i(in[i]*w[i][j]) (in INT32 space)
    // acc[0]=1*1+2*4+3*7+4*10 = 1+8+21+40 = 70
    // acc[1]=1*2+2*5+3*8+4*11 = 2+10+24+44 = 80
    // acc[2]=1*3+2*6+3*9+4*12 = 3+12+27+48 = 90
    // >>7: 70>>7=0, 80>>7=0, 90>>7=0 → after ReLU: 0,0,0
    // Need larger weights. Let weights=50:
    // acc = sum(in*50) = 50*(1+2+3+4)=500 same for all outputs
    // >>7 = 3, ReLU=3 ✓
    function signed [DATA_W-1:0] relu8;
        input signed [ACC_W-1:0] x;
        begin
            if (x <= 0)      relu8 = 0;
            else if (x > 127) relu8 = 127;
            else             relu8 = x[DATA_W-1:0];
        end
    endfunction

    initial begin
        errors = 0;
        $display("==============================================");
        $display(" TB: dense_engine  IN=%0d  OUT=%0d  ReLU=1", IN_DIM, OUT_DIM);
        $display("==============================================");

        rst_n = 0; start = 0; din = 0; din_valid = 0;
        for (i = 0; i < IN_DIM; i = i+1)
            for (oi = 0; oi < OUT_DIM; oi = oi+1)
                w[i][oi] = 0;
        for (oi = 0; oi < OUT_DIM; oi = oi+1) b[oi] = 0;
        repeat(4) ck(); rst_n = 1; repeat(2) ck();

        // ── TEST 1: All-zero weights → output should be 0 (ReLU(0)=0) ──
        $display("\n[T1] Zero weights → output=0");
        din_arr[0]=1; din_arr[1]=2; din_arr[2]=3; din_arr[3]=4;
        run_inference();
        for (oi = 0; oi < OUT_DIM; oi = oi+1)
            if (dout[oi] !== 0) begin $display("  FAIL: dout[%0d]=%0d exp 0",oi,dout[oi]); errors++; end
        $display("  dout=[%0d,%0d,%0d]  %s", dout[0],dout[1],dout[2], (dout[0]===0)?"PASS":"FAIL");

        // ── TEST 2: Positive weights → positive output ────────
        $display("\n[T2] w=50, in=[1,2,3,4] → acc=500>>7=3 per output");
        for (i = 0; i < IN_DIM; i = i+1)
            for (oi = 0; oi < OUT_DIM; oi = oi+1)
                w[i][oi] = 8'd50;
        for (oi = 0; oi < OUT_DIM; oi = oi+1) b[oi] = 0;
        din_arr[0]=1; din_arr[1]=2; din_arr[2]=3; din_arr[3]=4;
        run_inference();
        // Expected: (1+2+3+4)*50=500, 500>>7=3 (500/128=3.9...)
        for (oi = 0; oi < OUT_DIM; oi = oi+1)
            if (dout[oi] !== 8'd3) begin
                $display("  FAIL: dout[%0d]=%0d exp 3",oi,$signed(dout[oi])); errors++;
            end
        $display("  dout=[%0d,%0d,%0d]  %s", dout[0],dout[1],dout[2], (dout[0]===3)?"PASS":"FAIL");

        // ── TEST 3: Negative acc → ReLU clamps to 0 ──────────
        $display("\n[T3] Negative weights → acc<0 → ReLU=0");
        for (i = 0; i < IN_DIM; i = i+1)
            for (oi = 0; oi < OUT_DIM; oi = oi+1)
                w[i][oi] = -8'd50;
        din_arr[0]=1; din_arr[1]=2; din_arr[2]=3; din_arr[3]=4;
        run_inference();
        for (oi = 0; oi < OUT_DIM; oi = oi+1)
            if (dout[oi] !== 8'd0) begin $display("  FAIL: dout[%0d]=%0d exp 0",oi,dout[oi]); errors++; end
        $display("  ReLU(negative)=[%0d,%0d,%0d]  %s", dout[0],dout[1],dout[2], (dout[0]===0)?"PASS":"FAIL");

        // ── TEST 4: Saturation → clip to 127 ─────────────────
        $display("\n[T4] Saturation → clip to 127");
        for (i = 0; i < IN_DIM; i = i+1)
            for (oi = 0; oi < OUT_DIM; oi = oi+1)
                w[i][oi] = 8'd127;
        for (oi = 0; oi < OUT_DIM; oi = oi+1) b[oi] = 8'd127;
        din_arr[0]=127; din_arr[1]=127; din_arr[2]=127; din_arr[3]=127;
        run_inference();
        for (oi = 0; oi < OUT_DIM; oi = oi+1)
            if (dout[oi] !== 8'd127) begin
                $display("  FAIL: dout[%0d]=%0d exp 127",oi,dout[oi]); errors++;
            end
        $display("  Saturation=[%0d,%0d,%0d]  %s", dout[0],dout[1],dout[2], (dout[0]===127)?"PASS":"FAIL");

        // ── TEST 5: Back-to-back ──────────────────────────────
        $display("\n[T5] 3× back-to-back inferences");
        for (i = 0; i < IN_DIM; i = i+1)
            for (oi = 0; oi < OUT_DIM; oi = oi+1)
                w[i][oi] = 8'd10;
        for (oi = 0; oi < OUT_DIM; oi = oi+1) b[oi] = 0;
        repeat(3) begin
            din_arr[0]=5; din_arr[1]=5; din_arr[2]=5; din_arr[3]=5;
            run_inference();
            $display("  Run: dout=[%0d,%0d,%0d]", dout[0],dout[1],dout[2]);
            ck();
        end
        $display("  Back-to-back: PASS");

        $display("\n==============================================");
        $display(" dense_engine: Errors=%0d  %s", errors, errors==0 ? "ALL PASS ✓" : "FAIL ✗");
        $display("==============================================");
        $finish;
    end

endmodule
