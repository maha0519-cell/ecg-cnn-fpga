// ============================================================
// Module: secure_alert
// Description: Lightweight Edge Security Module
//
// Features:
//   - XOR-based stream cipher for alert encryption
//   - Rolling key (LFSR-based) for session uniqueness
//   - Alert payload: {det_bit, confidence[6:0]}
//   - Timestamp tagging for replay prevention
//   - Future: PUF-based key derivation hook
//
// Security Note: XOR cipher provides lightweight obfuscation
//   suitable for edge BLE/UART transmission. For production
//   use, replace with AES-CCM (hardware IP core).
// ============================================================

`timescale 1ns/1ps

module secure_alert #(
    parameter KEY_W    = 8,          // Key width
    parameter STATIC_KEY = 8'hA5     // Base encryption key (0xA5 = 1010_0101)
)(
    input  wire         clk,
    input  wire         rst_n,

    // Trigger inputs
    input  wire         alert_trigger,           // Pulse when new result
    input  wire         arrhythmia_detected,     // Classification result
    input  wire [7:0]   confidence,              // Confidence 0-255
    input  wire [31:0]  timestamp,               // Cycle count / timestamp
    input  wire         secure_enable,           // Enable encryption
    input  wire [KEY_W-1:0] key_override,        // Optional key override
    input  wire         key_override_en,          // Use key_override if 1

    // Outputs
    output reg          alert_valid,             // Alert ready to transmit
    output reg [7:0]    alert_byte_0,            // Encrypted status byte
    output reg [7:0]    alert_byte_1,            // Encrypted confidence
    output reg [7:0]    alert_byte_2,            // Timestamp byte (LSB)
    output reg [7:0]    alert_byte_3,            // Timestamp byte (MSB)
    output reg [3:0]    alert_severity           // 0=normal, 1-3=severity levels
);

    // ─────────────────────────────────────────────
    // LFSR-based rolling key generator
    // 8-bit Galois LFSR (polynomial: x^8 + x^6 + x^5 + x^4 + 1)
    // ─────────────────────────────────────────────
    reg [7:0] lfsr_state;
    wire      lfsr_feedback = lfsr_state[7] ^ lfsr_state[5] ^ lfsr_state[4] ^ lfsr_state[3];

    wire [7:0] effective_key = key_override_en ? key_override : STATIC_KEY;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            lfsr_state <= 8'hFF;   // LFSR seed (must not be 0)
        else if (alert_trigger)
            lfsr_state <= {lfsr_state[6:0], lfsr_feedback};  // Shift one step per alert
    end

    // ─────────────────────────────────────────────
    // Rolling session key = static key XOR LFSR
    // ─────────────────────────────────────────────
    wire [7:0] session_key = effective_key ^ lfsr_state;

    // ─────────────────────────────────────────────
    // Alert Payload Assembly
    // Byte 0: {1'b1, arrhythmia_detected, severity[1:0], 4'b1010}  (magic header)
    // Byte 1: confidence (0-255)
    // Byte 2: timestamp[7:0]
    // Byte 3: timestamp[15:8]
    // ─────────────────────────────────────────────
    reg [7:0] payload_0, payload_1, payload_2, payload_3;

    // Severity classification from confidence
    function [3:0] get_severity;
        input [7:0] conf;
        input det;
        begin
            if (!det)
                get_severity = 4'd0;             // Normal
            else if (conf < 170)
                get_severity = 4'd1;             // Low-confidence arrhythmia
            else if (conf < 210)
                get_severity = 4'd2;             // Moderate
            else
                get_severity = 4'd3;             // High-confidence arrhythmia
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            alert_valid    <= 0;
            alert_byte_0   <= 0;
            alert_byte_1   <= 0;
            alert_byte_2   <= 0;
            alert_byte_3   <= 0;
            alert_severity <= 0;
        end else if (alert_trigger) begin
            // Build payload
            payload_0 = {1'b1, arrhythmia_detected, get_severity(confidence, arrhythmia_detected)[1:0], 4'hA};
            payload_1 = confidence;
            payload_2 = timestamp[7:0];
            payload_3 = timestamp[15:8];

            alert_severity <= get_severity(confidence, arrhythmia_detected);

            if (secure_enable) begin
                // XOR encrypt with rolling session key
                alert_byte_0 <= payload_0 ^ session_key;
                alert_byte_1 <= payload_1 ^ (session_key ^ 8'h3C);  // Per-byte key variation
                alert_byte_2 <= payload_2 ^ (session_key ^ 8'hF0);
                alert_byte_3 <= payload_3 ^ (session_key ^ 8'h55);
            end else begin
                // Plaintext (debug mode)
                alert_byte_0 <= payload_0;
                alert_byte_1 <= payload_1;
                alert_byte_2 <= payload_2;
                alert_byte_3 <= payload_3;
            end

            alert_valid <= 1;
        end else begin
            alert_valid <= 0;
        end
    end

endmodule
