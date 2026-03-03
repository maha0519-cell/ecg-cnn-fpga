// ============================================================
// Module: config_reg_block
// Description: Runtime Configuration Registers
//
// Register Map:
//   Addr 0x00: Control   [7:4]=reserved [3]=secure_en [2]=dense_en [1]=conv2_en [0]=conv1_en
//   Addr 0x01: Kernel    [7:4]=conv2_kern [3:0]=conv1_kern (3/5/7 valid)
//   Addr 0x02: Filters   [7:4]=conv2_filt [3:0]=conv1_filt (1-8 valid)
//   Addr 0x03: Threshold [7:0]=sigmoid threshold (default 0x80 = 128 ≈ 0.5)
//   Addr 0x04: Key[7:0]  Encryption key override LSB
//   Addr 0x05: Flags     [0]=key_override_en [1]=debug_mode
//   Addr 0x06: Latency   [7:0]=max latency limit (in 100-cycle units)
//   Addr 0x07-0x0F: Reserved
// ============================================================

`timescale 1ns/1ps

module config_reg_block #(
    parameter N_REGS      = 16,
    parameter DEFAULT_CTRL = 8'h0F,  // All layers enabled, no secure
    parameter DEFAULT_THR  = 8'h80   // Threshold = 0.5
)(
    input  wire         clk,
    input  wire         rst_n,

    // Write interface
    input  wire         wr_en,
    input  wire [3:0]   wr_addr,
    input  wire [7:0]   wr_data,

    // Read interface
    input  wire [3:0]   rd_addr,
    output reg  [7:0]   rd_data,

    // Decoded configuration outputs
    output wire         cfg_conv1_en,
    output wire         cfg_conv2_en,
    output wire         cfg_dense_en,
    output wire         cfg_secure_en,
    output wire [2:0]   cfg_conv1_kern,
    output wire [2:0]   cfg_conv2_kern,
    output wire [3:0]   cfg_conv1_filt,
    output wire [3:0]   cfg_conv2_filt,
    output wire [7:0]   cfg_threshold,
    output wire [7:0]   cfg_enc_key,
    output wire         cfg_key_override,
    output wire         cfg_debug_mode
);

    // Register file
    reg [7:0] regs [0:N_REGS-1];

    // Write logic
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < N_REGS; i = i+1)
                regs[i] <= 8'h00;
            regs[0] <= DEFAULT_CTRL;  // Control
            regs[1] <= 8'h55;         // Kernels: Conv1=5, Conv2=5
            regs[2] <= 8'h88;         // Filters: Conv1=8, Conv2=8 (use 8=0x8→actual is 8)
            regs[3] <= DEFAULT_THR;   // Threshold
            regs[4] <= 8'hA5;         // Default encryption key
            regs[5] <= 8'h00;         // Flags: no override, no debug
        end else if (wr_en) begin
            regs[wr_addr] <= wr_data;
        end
    end

    // Read logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            rd_data <= 8'h00;
        else
            rd_data <= regs[rd_addr];
    end

    // Decode outputs
    // Kernel size decode: 0→3, 1→5, 2→7 (register stores 3/5/7 directly)
    assign cfg_conv1_en      = regs[0][0];
    assign cfg_conv2_en      = regs[0][1];
    assign cfg_dense_en      = regs[0][2];
    assign cfg_secure_en     = regs[0][3];

    // Kernel: stored as actual value (3, 5, or 7)
    assign cfg_conv1_kern    = regs[1][2:0];  // Lower nibble
    assign cfg_conv2_kern    = regs[1][6:4];  // Upper nibble

    // Filter counts (1-16, stored as actual count)
    assign cfg_conv1_filt    = regs[2][3:0];
    assign cfg_conv2_filt    = regs[2][7:4];

    assign cfg_threshold     = regs[3];
    assign cfg_enc_key       = regs[4];
    assign cfg_key_override  = regs[5][0];
    assign cfg_debug_mode    = regs[5][1];

endmodule
