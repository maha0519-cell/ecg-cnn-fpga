// ============================================================
// Module: sigmoid_classifier
// Description: Piecewise-linear sigmoid approximation + threshold
//
// Sigmoid approximation (5-region piecewise linear):
//   x < -4   → 0
//   x in [-4,-2] → 0 + (x+4)*(32/2) = 16*(x+4)
//   x in [-2, 0] → 64 + (x+2)*(64/2) = 64 + 32*(x+2)
//   x in [ 0,+2] → 128 + x*32
//   x in [+2,+4] → 192 + (x-2)*16
//   x > +4   → 255
//
// Input:  16-bit signed logit (pre-sigmoid)
// Output: 8-bit confidence (0–255) and binary classification
// ============================================================
`timescale 1ns/1ps
module sigmoid_classifier #(
    parameter DATA_W   = 16,      // Input logit width
    parameter CONF_W   = 8,       // Confidence output width (0-255)
    parameter THRESHOLD = 128     // Classification threshold (default 0.5)
)(
    input  wire         clk,
    input  wire         rst_n,
    input  wire         valid_in,
    input  wire signed [DATA_W-1:0] logit_in,
    // Runtime threshold override
    input  wire [CONF_W-1:0] threshold_cfg,
    output reg          valid_out,
    output reg [CONF_W-1:0] confidence,     // 0–255 sigmoid output
    output reg          classification       // 1=arrhythmia, 0=normal
);
    // Scale logit: the logit from INT8 computation is already scaled
    // Map to range [-8, +8] for sigmoid input
    reg signed [DATA_W-1:0] x;
    reg [CONF_W-1:0] sig_val;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_out      <= 0;
            confidence     <= 0;
            classification <= 0;
        end else if (valid_in) begin
            x = logit_in;
            // 5-region piecewise linear sigmoid
            if (x <= -8)
                sig_val = 8'd0;
            else if (x <= -6)
                sig_val = 8'd2  + (x + 8) * 4;       // 0 → 8
            else if (x <= -4)
                sig_val = 8'd10 + (x + 6) * 8;        // 8 → 24
            else if (x <= -2)
                sig_val = 8'd26 + (x + 4) * 19;       // 24 → 64
            else if (x <= 0)
                sig_val = 8'd64 + (x + 2) * 32;       // 64 → 128
            else if (x <= 2)
                sig_val = 8'd128 + x * 32;             // 128 → 192
            else if (x <= 4)
                sig_val = 8'd192 + (x - 2) * 19;      // 192 → 230
            else if (x <= 6)
                sig_val = 8'd230 + (x - 4) * 8;       // 230 → 246
            else if (x <= 8)
                sig_val = 8'd246 + (x - 6) * 4;       // 246 → 254
            else
                sig_val = 8'd255;
            confidence     <= sig_val;
            classification <= (sig_val >= threshold_cfg) ? 1'b1 : 1'b0;
            valid_out      <= 1;
        end else begin
            valid_out <= 0;
        end
    end
endmodule
