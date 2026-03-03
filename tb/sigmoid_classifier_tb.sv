// ============================================================
// Testbench: sigmoid_classifier_tb.v
// Tests: 5-region piecewise linear sigmoid correctness,
//        threshold comparison, runtime threshold change,
//        boundary conditions (x=-8, x=0, x=+8)
// ============================================================
`timescale 1ns/1ps

module sigmoid_classifier_tb;

    localparam DATA_W = 16;
    localparam CONF_W = 8;
    localparam CLK_P  = 10;

    reg  clk, rst_n, valid_in;
    reg  signed [DATA_W-1:0] logit_in;
    reg  [CONF_W-1:0] threshold_cfg;
    wire valid_out;
    wire [CONF_W-1:0] confidence;
    wire classification;

    sigmoid_classifier #(.DATA_W(DATA_W), .CONF_W(CONF_W), .THRESHOLD(128)) dut (
        .clk(clk), .rst_n(rst_n),
        .valid_in(valid_in), .logit_in(logit_in),
        .threshold_cfg(threshold_cfg),
        .valid_out(valid_out), .confidence(confidence), .classification(classification)
    );

    initial clk = 0;
    always  #(CLK_P/2) clk = ~clk;

    initial begin
        $dumpfile("sigmoid_classifier.vcd");
        $dumpvars(0, sigmoid_classifier_tb);
    end

    integer errors;
    task ck; begin @(posedge clk); #1; end endtask
    task reset_dut;
        begin
            rst_n = 0; valid_in = 0; logit_in = 0; threshold_cfg = 128;
            repeat(4) ck(); rst_n = 1; repeat(2) ck();
        end
    endtask

    task send_logit;
        input signed [DATA_W-1:0] x;
        input integer exp_class;
        input [31:0] exp_conf_min, exp_conf_max;
        begin
            logit_in = x; valid_in = 1; ck(); valid_in = 0; ck();
            if (!valid_out) ck();  // allow 1 extra cycle
            $display("  logit=%4d → conf=%3d class=%0d  (exp class=%0d, conf[%0d..%0d])  %s",
                      $signed(logit_in), confidence, classification,
                      exp_class, exp_conf_min, exp_conf_max,
                      (classification==exp_class && confidence>=exp_conf_min && confidence<=exp_conf_max)
                      ? "PASS" : "FAIL");
            if (classification !== exp_class[0:0]) errors++;
        end
    endtask

    initial begin
        errors = 0;
        $display("==============================================");
        $display(" TB: sigmoid_classifier  DATA_W=%0d", DATA_W);
        $display("==============================================");

        reset_dut();

        // ── TEST 1: Boundary and region values ───────────────
        $display("\n[T1] Sigmoid piecewise regions");
        threshold_cfg = 128;  // threshold = 0.5

        // x < -8 → conf=0 → class=0
        send_logit(-16'd20, 0, 0, 5);
        // x = -8 → conf=0 → class=0
        send_logit(-16'd8, 0, 0, 5);
        // x = -4 → conf ~24 → class=0
        send_logit(-16'd4, 0, 20, 30);
        // x = 0 → conf=128 ≥ threshold=128 → class=1 (RTL uses >=, boundary belongs to positive class)
        send_logit(16'd0, 1, 126, 130);
        // x = +2 → conf=192 → class=1
        send_logit(16'd2, 1, 188, 196);
        // x = +4 → conf~230 → class=1
        send_logit(16'd4, 1, 225, 235);
        // x = +8 → conf=254 → class=1
        send_logit(16'd8, 1, 250, 255);
        // x > +8 → conf=255 → class=1
        send_logit(16'd20, 1, 255, 255);

        // ── TEST 2: Threshold sensitivity ────────────────────
        $display("\n[T2] Runtime threshold change");
        // At x=0, conf=128. If threshold=200 → class should be 0
        threshold_cfg = 200;
        send_logit(16'd0, 0, 126, 130);
        // If threshold=64 → class should be 1
        threshold_cfg = 64;
        send_logit(16'd0, 1, 126, 130);
        // Restore
        threshold_cfg = 128;

        // ── TEST 3: Negative confidence region ───────────────
        $display("\n[T3] Strongly negative → conf→0");
        send_logit(-16'd100, 0, 0, 2);

        // ── TEST 4: Strongly positive → conf→255 ─────────────
        $display("\n[T4] Strongly positive → conf→255");
        send_logit(16'd100, 1, 253, 255);

        // ── TEST 5: Valid_in=0 → no output ───────────────────
        $display("\n[T5] No output when valid_in=0");
        valid_in = 0; repeat(5) ck();
        $display("  No spurious valid_out after 5 idle cycles: %s",
                  valid_out ? "FAIL" : "PASS");
        if (valid_out) errors++;

        $display("\n==============================================");
        $display(" sigmoid_classifier: Errors=%0d  %s", errors, errors==0 ? "ALL PASS ✓" : "FAIL ✗");
        $display("==============================================");
        $finish;
    end

endmodule
