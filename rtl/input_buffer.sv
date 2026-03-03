// ============================================================
// Module: input_buffer
// Description: ECG Sample Input Buffer
//
// Features:
//   - 300-sample circular FIFO (INT8)
//   - Streaming input interface
//   - Full/empty flags
//   - Random-access read port for CNN engine
//   - Overflow protection
// ============================================================
`timescale 1ns/1ps
module input_buffer #(
    parameter DEPTH  = 300,          // Buffer depth (ECG segment length)
    parameter DATA_W = 8             // Sample width (INT8 signed)
)(
    input  wire         clk,
    input  wire         rst_n,
    input  wire         clear,       // Clear buffer
    // Write interface (streaming from sensor/MCU)
    input  wire         wr_en,
    input  wire signed [DATA_W-1:0] wr_data,
    output reg          full,
    output reg          overflow_flag,
    // Read interface (random access for CNN)
    input  wire         rd_en,
    input  wire [$clog2(DEPTH)-1:0] rd_addr,   // Absolute position
    output wire signed [DATA_W-1:0] rd_data,
    // Sequential read (for streaming to CNN)
    input  wire         seq_rd_en,
    output reg  signed [DATA_W-1:0] seq_rd_data,
    output reg          empty,
    // Status
    output reg  [$clog2(DEPTH):0]   sample_count,
    output reg                       buffer_ready   // All 300 samples loaded
);
    // Dual-port buffer
    reg signed [DATA_W-1:0] buf_mem [0:DEPTH-1];
    reg [$clog2(DEPTH):0] wr_ptr;
    reg [$clog2(DEPTH):0] rd_ptr;
    // Random-access read (combinational)
    assign rd_data = buf_mem[rd_addr];
    integer idx;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || clear) begin
            wr_ptr       <= 0;
            rd_ptr       <= 0;
            sample_count <= 0;
            full         <= 0;
            empty        <= 1;
            overflow_flag<= 0;
            buffer_ready <= 0;
            seq_rd_data  <= 0;
            for (idx = 0; idx < DEPTH; idx = idx+1)
                buf_mem[idx] <= 0;
        end else begin
            // Write
            if (wr_en) begin
                if (full) begin
                    overflow_flag <= 1;  // Overflow: discard sample
                end else begin
                    buf_mem[wr_ptr] <= wr_data;
                    wr_ptr <= (wr_ptr == DEPTH-1) ? 0 : wr_ptr + 1;
                    sample_count <= sample_count + 1;
                    empty <= 0;
                    if (sample_count + 1 == DEPTH) begin
                        full         <= 1;
                        buffer_ready <= 1;
                    end
                end
            end
            // Sequential read
            if (seq_rd_en && !empty) begin
                seq_rd_data <= buf_mem[rd_ptr];
                rd_ptr <= (rd_ptr == DEPTH-1) ? 0 : rd_ptr + 1;
                if (sample_count > 0) sample_count <= sample_count - 1;
                if (sample_count == 1) begin
                    empty        <= 1;
                    buffer_ready <= 0;
                end
                full <= 0;
            end
        end
    end
endmodule
