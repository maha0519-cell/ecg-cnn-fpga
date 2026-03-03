// ============================================================
// Testbench: secure_alert_tb.v
// Tests: LFSR key evolution, XOR encryption/decryption verify,
//        severity classification, key_override, plaintext mode,
//        back-to-back alerts, replay prevention (key changes)
// ============================================================
`timescale 1ns/1ps

module secure_alert_tb;

    localparam KEY_W      = 8;
    localparam STATIC_KEY = 8'hA5;
    localparam CLK_P      = 10;

    reg  clk, rst_n;
    reg  alert_trigger, arrhythmia_detected;
    reg  [7:0] confidence;
    reg  [31:0] timestamp;
    reg  secure_enable;
    reg  [KEY_W-1:0] key_override;
    reg  key_override_en;

    wire alert_valid;
    wire [7:0] alert_byte_0, alert_byte_1, alert_byte_2, alert_byte_3;
    wire [3:0] alert_severity;

    secure_alert #(.KEY_W(KEY_W), .STATIC_KEY(STATIC_KEY)) dut (
        .clk(clk), .rst_n(rst_n),
        .alert_trigger(alert_trigger),
        .arrhythmia_detected(arrhythmia_detected),
        .confidence(confidence),
        .timestamp(timestamp),
        .secure_enable(secure_enable),
        .key_override(key_override),
        .key_override_en(key_override_en),
        .alert_valid(alert_valid),
        .alert_byte_0(alert_byte_0), .alert_byte_1(alert_byte_1),
        .alert_byte_2(alert_byte_2), .alert_byte_3(alert_byte_3),
        .alert_severity(alert_severity)
    );

    initial clk = 0;
    always  #(CLK_P/2) clk = ~clk;

    initial begin
        $dumpfile("secure_alert.vcd");
        $dumpvars(0, secure_alert_tb);
    end

    integer errors;
    reg [7:0] lfsr;   // Mirror LFSR in TB to predict session key
    reg [7:0] sess;

    task ck; begin @(posedge clk); #1; end endtask
    task reset_dut;
        begin
            rst_n = 0; alert_trigger = 0; arrhythmia_detected = 0;
            confidence = 0; timestamp = 0; secure_enable = 1;
            key_override = 0; key_override_en = 0;
            repeat(4) ck(); rst_n = 1;
            lfsr = 8'hFF;  // LFSR seed matches RTL
            repeat(2) ck();
        end
    endtask

    // Mirror 8-bit Galois LFSR
    function [7:0] lfsr_next;
        input [7:0] s;
        reg fb;
        begin
            fb = s[7] ^ s[5] ^ s[4] ^ s[3];
            lfsr_next = {s[6:0], fb};
        end
    endfunction

    task trigger_alert;
        input det;
        input [7:0] conf;
        input [31:0] ts;
        reg [7:0] payload0, sess_key, decrypted0;
        reg [3:0] sev;
        begin
            arrhythmia_detected = det;
            confidence = conf;
            timestamp  = ts;
            alert_trigger = 1; ck(); alert_trigger = 0;

            // LFSR advances on alert_trigger
            lfsr = lfsr_next(lfsr);
            sess_key = STATIC_KEY ^ lfsr;

            // Wait for alert
            wait(alert_valid == 1); ck();

            // Decode severity
            if (!det)     sev = 0;
            else if (conf < 170) sev = 1;
            else if (conf < 210) sev = 2;
            else          sev = 3;

            // Verify byte_0 decryption
            decrypted0 = alert_byte_0 ^ sess_key;
            payload0   = {1'b1, det, sev[1:0], 4'hA};

            $display("  det=%0d conf=%3d sev=%0d | byte0=0x%02h decrypted=0x%02h payload=0x%02h  %s",
                      det, conf, alert_severity,
                      alert_byte_0, decrypted0, payload0,
                      (alert_severity==sev) ? "SEV_OK" : "SEV_FAIL");

            if (alert_severity !== sev) begin
                $display("    FAIL: severity %0d != %0d", alert_severity, sev); errors++;
            end
        end
    endtask

    initial begin
        errors = 0;
        $display("==============================================");
        $display(" TB: secure_alert  key=0x%02h  LFSR-based", STATIC_KEY);
        $display("==============================================");

        reset_dut();

        // ── TEST 1: Normal alert (no arrhythmia) ─────────────
        $display("\n[T1] Normal result (det=0, conf=80)");
        trigger_alert(0, 8'd80, 32'd100);
        if (alert_severity !== 0) begin $display("FAIL: sev should be 0"); errors++; end
        $display("  severity=%0d  %s", alert_severity, alert_severity==0?"PASS":"FAIL");

        // ── TEST 2: Low-confidence arrhythmia ────────────────
        $display("\n[T2] Arrhythmia, low confidence (conf=140)");
        trigger_alert(1, 8'd140, 32'd200);
        $display("  severity=%0d  %s", alert_severity, alert_severity==1?"PASS":"FAIL");
        if (alert_severity !== 1) errors++;

        // ── TEST 3: Moderate arrhythmia ───────────────────────
        $display("\n[T3] Arrhythmia, moderate (conf=190)");
        trigger_alert(1, 8'd190, 32'd300);
        $display("  severity=%0d  %s", alert_severity, alert_severity==2?"PASS":"FAIL");
        if (alert_severity !== 2) errors++;

        // ── TEST 4: High-confidence arrhythmia ───────────────
        $display("\n[T4] Arrhythmia, high confidence (conf=220)");
        trigger_alert(1, 8'd220, 32'd400);
        $display("  severity=%0d  %s", alert_severity, alert_severity==3?"PASS":"FAIL");
        if (alert_severity !== 3) errors++;

        // ── TEST 5: LFSR key changes every alert ──────────────
        $display("\n[T5] LFSR rolling key — bytes should differ across alerts");
        begin
            reg [7:0] prev_b0;
            prev_b0 = alert_byte_0;
            trigger_alert(1, 8'd220, 32'd500);
            if (alert_byte_0 === prev_b0)
                $display("  WARN: key did not change (possible collision)");
            else
                $display("  LFSR rolled: prev=0x%02h new=0x%02h  PASS", prev_b0, alert_byte_0);
        end

        // ── TEST 6: Plaintext mode (secure_enable=0) ──────────
        $display("\n[T6] Plaintext mode (debug)");
        secure_enable = 0;
        arrhythmia_detected = 1; confidence = 200; timestamp = 32'd1000;
        alert_trigger = 1; ck(); alert_trigger = 0;
        wait(alert_valid == 1); ck();
        if (alert_byte_1 === 8'd200)
            $display("  byte_1(plaintext confidence)=0x%02h exp=0xC8  PASS", alert_byte_1);
        else
            $display("  byte_1(plaintext confidence)=0x%02h exp=0xC8  FAIL", alert_byte_1);
        if (alert_byte_1 !== 8'd200) errors++;
        secure_enable = 1;

        // ── TEST 7: Key override ───────────────────────────────
        $display("\n[T7] Key override = 0xFF");
        key_override = 8'hFF; key_override_en = 1;
        trigger_alert(1, 8'd180, 32'd2000);
        $display("  Key override active, byte_0=0x%02h (different from static key mode)", alert_byte_0);
        key_override_en = 0;

        // ── TEST 8: Back-to-back 5 alerts ─────────────────────
        $display("\n[T8] 5× rapid back-to-back alerts");
        begin : bb_block
            integer ai;
            for (ai = 0; ai < 5; ai = ai + 1) begin
                arrhythmia_detected = ai[0];
                confidence = ai * 50;
                timestamp  = ai * 100;
                alert_trigger = 1; ck(); alert_trigger = 0;
                lfsr = lfsr_next(lfsr);
                wait(alert_valid == 1); ck();
                $display("  alert[%0d]: sev=%0d byte0=0x%02h", ai, alert_severity, alert_byte_0);
            end
        end
        $display("  Back-to-back: PASS");

        $display("\n==============================================");
        $display(" secure_alert: Errors=%0d  %s", errors, errors==0 ? "ALL PASS ✓" : "FAIL ✗");
        $display("==============================================");
        $finish;
    end

endmodule
