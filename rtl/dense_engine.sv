// ============================================================
// Module: dense_engine
// Description: Fully Connected (Dense) Layer Engine
//
// Features:
//   - Parameterized input/output size
//   - INT8 weights, INT20 accumulator
//   - Sequential MAC (1 input per clock, serial over input dim)
//   - ReLU activation (configurable)
//   - Supports final output layer (no ReLU)
// ============================================================

`timescale 1ns/1ps

module dense_engine #(
    parameter IN_DIM    = 1152,   // Input dimension
    parameter OUT_DIM   = 16,     // Output dimension
    parameter DATA_W    = 8,      // Data/weight width
    parameter ACC_W     = 28,     // Accumulator width (larger for 1152 MACs)
    parameter SCALE_SH  = 7,      // Scale shift
    parameter USE_RELU  = 1       // 1=apply ReLU, 0=raw output (final layer)
)(
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,                        // Pulse to start computation
    
    // Input feature vector (presented one element per clock after start)
    input  wire signed [DATA_W-1:0] din,
    input  wire         din_valid,

    // Weight ROM interface
    // weight[in_idx][out_idx] — OUT_DIM weights per input
    input  wire signed [DATA_W-1:0] w [0:IN_DIM-1][0:OUT_DIM-1],
    input  wire signed [DATA_W-1:0] b [0:OUT_DIM-1],

    // Output: all neurons computed together (sequential strategy)
    output reg          dout_valid,
    output reg signed [DATA_W-1:0] dout [0:OUT_DIM-1]
);

    // State machine
    localparam ST_IDLE    = 2'd0;
    localparam ST_COMPUTE = 2'd1;  // Accumulate MAC for all outputs
    localparam ST_STORE   = 2'd2;  // Apply activation, store, done

    reg [1:0] state;

    // Accumulators: one per output neuron
    reg signed [ACC_W-1:0] acc [0:OUT_DIM-1];

    // Input index counter
    reg [$clog2(IN_DIM):0] in_idx;

    integer oi;
    reg signed [ACC_W-1:0] scaled;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= ST_IDLE;
            in_idx     <= 0;
            dout_valid <= 0;
            for (oi = 0; oi < OUT_DIM; oi = oi+1) begin
                acc[oi]  <= 0;
                dout[oi] <= 0;
            end
        end else begin
            case (state)
                ST_IDLE: begin
                    dout_valid <= 0;
                    if (start) begin
                        // Initialize accumulators with biases
                        for (oi = 0; oi < OUT_DIM; oi = oi+1)
                            acc[oi] <= $signed(b[oi]);
                        in_idx <= 0;
                        state  <= ST_COMPUTE;
                    end
                end

                ST_COMPUTE: begin
                    if (din_valid) begin
                        // MAC: accumulate din × w[in_idx][oi] for all outputs
                        for (oi = 0; oi < OUT_DIM; oi = oi+1)
                            acc[oi] <= acc[oi] + ($signed(din) * $signed(w[in_idx][oi]));

                        if (in_idx == IN_DIM - 1)
                            state <= ST_STORE;
                        else
                            in_idx <= in_idx + 1;
                    end
                end

                ST_STORE: begin
                    // Apply scaling and activation, store outputs
                    for (oi = 0; oi < OUT_DIM; oi = oi+1) begin
                        scaled = acc[oi] >>> SCALE_SH;

                        if (USE_RELU) begin
                            // ReLU + INT8 clip
                            if (scaled <= 0)
                                dout[oi] <= 8'h00;
                            else if (scaled > 8'sh7F)
                                dout[oi] <= 8'h7F;
                            else
                                dout[oi] <= scaled[DATA_W-1:0];
                        end else begin
                            // No activation (final layer) - pass scaled value
                            if (scaled < -128)
                                dout[oi] <= 8'sh80;
                            else if (scaled > 127)
                                dout[oi] <= 8'sh7F;
                            else
                                dout[oi] <= scaled[DATA_W-1:0];
                        end
                    end

                    dout_valid <= 1;
                    state      <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
