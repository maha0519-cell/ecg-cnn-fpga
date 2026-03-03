// ============================================================
// Module: ecg_pipeline_top
// Project: Configurable Low-Latency 1D CNN Accelerator
//          for Secure Real-Time ECG Arrhythmia Detection
//
// Description:
//   Integration wrapper that connects ALL standalone streaming
//   submodules into the complete wearable pipeline:
//
//   input_buffer → conv1d_engine(C1) → maxpool1d_unit(P1)
//               → conv1d_engine(C2) → maxpool1d_unit(P2)
//               → dense_engine(D1)  → dense_engine(D2)
//               → sigmoid_classifier → secure_alert
//               ← config_reg_block (drives all configs)
//
// This is the architecturally clean, submodule-based version of
// ecg_top. Use this for synthesis when you want each IP block
// to be separately optimized / replaced.
//
// Interface matches ecg_top for drop-in substitution.
// ============================================================
`timescale 1ns/1ps

module ecg_pipeline_top #(
    parameter INPUT_LEN   = 300,
    parameter CONV1_FILT  = 8,
    parameter CONV1_KERN  = 5,
    parameter CONV2_FILT  = 16,
    parameter CONV2_KERN  = 5,
    parameter POOL_SIZE   = 2,
    parameter DENSE1_OUT  = 16,
    parameter DATA_W      = 8,
    parameter ACC_W       = 28,
    parameter ALERT_KEY   = 8'hA5
)(
    input  wire        clk,
    input  wire        rst_n,

    // ECG sample streaming input
    input  wire        sample_valid,
    input  wire signed [DATA_W-1:0] sample_in,

    // Configuration bus
    input  wire        cfg_wr_en,
    input  wire [3:0]  cfg_wr_addr,
    input  wire [7:0]  cfg_wr_data,

    // Status
    output wire        result_valid,
    output wire        arrhythmia_det,
    output wire [7:0]  confidence,
    output wire [7:0]  alert_byte_0,
    output wire [7:0]  alert_byte_1,
    output wire [7:0]  alert_byte_2,
    output wire [7:0]  alert_byte_3,
    output wire [3:0]  alert_severity,
    output wire        busy,
    output wire        buffer_ready
);

    // =========================================================
    // DERIVED PARAMETERS
    // =========================================================
    localparam CONV1_OUT_LEN = INPUT_LEN - CONV1_KERN + 1;   // 296
    localparam POOL1_OUT_LEN = CONV1_OUT_LEN / POOL_SIZE;     // 148
    localparam CONV2_OUT_LEN = POOL1_OUT_LEN - CONV2_KERN + 1;// 144
    localparam POOL2_OUT_LEN = CONV2_OUT_LEN / POOL_SIZE;     // 72
    localparam FLAT_LEN      = CONV2_FILT * POOL2_OUT_LEN;    // 1152

    // =========================================================
    // WEIGHT ROMs — loaded from hex at simulation/synthesis
    // =========================================================
    // Conv1: CONV1_FILT × 1 × CONV1_KERN = 40
    reg signed [DATA_W-1:0] conv1_w [0:CONV1_FILT-1][0:0][0:CONV1_KERN-1];
    reg signed [DATA_W-1:0] conv1_b [0:CONV1_FILT-1];
    // Conv2: CONV2_FILT × CONV1_FILT × CONV2_KERN = 640
    reg signed [DATA_W-1:0] conv2_w [0:CONV2_FILT-1][0:CONV1_FILT-1][0:CONV2_KERN-1];
    reg signed [DATA_W-1:0] conv2_b [0:CONV2_FILT-1];
    // Dense1: FLAT_LEN × DENSE1_OUT = 18432
    reg signed [DATA_W-1:0] dense1_w [0:FLAT_LEN-1][0:DENSE1_OUT-1];
    reg signed [DATA_W-1:0] dense1_b [0:DENSE1_OUT-1];
    // Out: DENSE1_OUT × 1 = 16
    reg signed [DATA_W-1:0] out_w [0:DENSE1_OUT-1][0:0];
    reg signed [DATA_W-1:0] out_b [0:0];

    initial begin
        $readmemh("conv1_w.hex", conv1_w);
        $readmemh("conv1_b.hex", conv1_b);
        $readmemh("conv2_w.hex", conv2_w);
        $readmemh("conv2_b.hex", conv2_b);
        $readmemh("dense_w.hex", dense1_w);
        $readmemh("dense_b.hex", dense1_b);
        $readmemh("out_w.hex",   out_w);
        $readmemh("out_b.hex",   out_b);
    end

    // =========================================================
    // CONFIG REG BLOCK
    // =========================================================
    wire        cfg_conv1_en, cfg_conv2_en, cfg_dense_en, cfg_secure_en;
    wire [7:0]  cfg_threshold, cfg_enc_key;
    wire        cfg_key_override, cfg_debug_mode;
    wire [7:0]  cfg_rd_data;

    config_reg_block #(
        .DEFAULT_CTRL(8'h0F),
        .DEFAULT_THR (8'h80)
    ) u_cfg (
        .clk           (clk),
        .rst_n         (rst_n),
        .wr_en         (cfg_wr_en),
        .wr_addr       (cfg_wr_addr),
        .wr_data       (cfg_wr_data),
        .rd_addr       (4'd0),
        .rd_data       (cfg_rd_data),
        .cfg_conv1_en  (cfg_conv1_en),
        .cfg_conv2_en  (cfg_conv2_en),
        .cfg_dense_en  (cfg_dense_en),
        .cfg_secure_en (cfg_secure_en),
        .cfg_conv1_kern(),
        .cfg_conv2_kern(),
        .cfg_conv1_filt(),
        .cfg_conv2_filt(),
        .cfg_threshold (cfg_threshold),
        .cfg_enc_key   (cfg_enc_key),
        .cfg_key_override(cfg_key_override),
        .cfg_debug_mode(cfg_debug_mode)
    );

    // =========================================================
    // STAGE 0: INPUT BUFFER (300 samples)
    // =========================================================
    wire        buf_full, buf_empty, buf_overflow;
    wire signed [DATA_W-1:0] buf_seq_data;
    wire [$clog2(INPUT_LEN):0] buf_count;

    assign buffer_ready = buf_full;
    assign busy         = buf_full; // simplification; extend with pipeline busy

    input_buffer #(
        .DEPTH (INPUT_LEN),
        .DATA_W(DATA_W)
    ) u_ibuf (
        .clk          (clk),
        .rst_n        (rst_n),
        .clear        (1'b0),
        .wr_en        (sample_valid),
        .wr_data      (sample_in),
        .full         (buf_full),
        .overflow_flag(buf_overflow),
        .rd_en        (1'b0),
        .rd_addr      ({$clog2(INPUT_LEN){1'b0}}),
        .rd_data      (),
        .seq_rd_en    (1'b0),
        .seq_rd_data  (buf_seq_data),
        .empty        (buf_empty),
        .sample_count (buf_count),
        .buffer_ready (buffer_ready)
    );

    // =========================================================
    // STAGE 1: CONV1D ENGINE — Layer 1 (8 filters, k=5, 1 ch)
    // Driven when buffer is full and streaming samples
    // =========================================================
    wire        c1_valid;
    wire signed [DATA_W-1:0] c1_out [0:CONV1_FILT-1];
    wire [$clog2(1024):0]    c1_pos;

    conv1d_engine #(
        .IN_CHANNELS (1),
        .OUT_FILTERS (CONV1_FILT),
        .KERNEL_SIZE (CONV1_KERN),
        .DATA_W      (DATA_W),
        .ACC_W       (ACC_W),
        .SCALE_SHIFT (7)
    ) u_conv1 (
        .clk            (clk),
        .rst_n          (rst_n),
        .enable         (cfg_conv1_en),
        .cfg_kernel_size(3'd5),
        .cfg_num_filters(5'd8),
        .din_valid      (sample_valid),
        .din            (sample_in),
        .din_channel    (1'd0),
        .weight_in      (conv1_w),
        .bias_in        (conv1_b),
        .dout_valid     (c1_valid),
        .dout           (c1_out),
        .dout_pos       (c1_pos)
    );

    // =========================================================
    // STAGE 2: MAXPOOL LAYER 1 (pool=2, 8 channels)
    // =========================================================
    wire        p1_valid;
    wire signed [DATA_W-1:0] p1_out [0:CONV1_FILT-1];

    maxpool1d_unit #(
        .CHANNELS (CONV1_FILT),
        .POOL_SIZE(POOL_SIZE),
        .DATA_W   (DATA_W)
    ) u_pool1 (
        .clk      (clk),
        .rst_n    (rst_n),
        .enable   (1'b1),
        .din_valid(c1_valid),
        .din      (c1_out),
        .dout_valid(p1_valid),
        .dout     (p1_out)
    );

    // =========================================================
    // STAGE 3: CONV1D ENGINE — Layer 2 (16 filters, k=5, 8 ch)
    // Note: conv1d_engine takes one channel per cycle; for 8-channel
    // input we demux p1_out into sequential channel feeds.
    // A channel_serializer is used here (inline logic).
    // =========================================================

    // Serialize 8-channel parallel pool1 output into sequential channel stream
    reg [$clog2(CONV1_FILT):0] ser_ch_idx;
    reg ser_active;
    reg signed [DATA_W-1:0] ser_data;
    reg ser_valid;
    reg signed [DATA_W-1:0] ser_buf [0:CONV1_FILT-1];

    always @(posedge clk or negedge rst_n) begin : channel_serializer
        integer c;
        if (!rst_n) begin
            ser_ch_idx <= 0;
            ser_active <= 0;
            ser_valid  <= 0;
            ser_data   <= 0;
        end else begin
            ser_valid <= 0;
            if (p1_valid && !ser_active) begin
                // Capture all channels
                for (c = 0; c < CONV1_FILT; c = c+1)
                    ser_buf[c] <= p1_out[c];
                ser_ch_idx <= 0;
                ser_active <= 1;
            end
            if (ser_active) begin
                ser_data   <= ser_buf[ser_ch_idx];
                ser_valid  <= 1;
                if (ser_ch_idx == CONV1_FILT - 1) begin
                    ser_ch_idx <= 0;
                    ser_active <= 0;
                end else begin
                    ser_ch_idx <= ser_ch_idx + 1;
                end
            end
        end
    end

    wire        c2_valid;
    wire signed [DATA_W-1:0] c2_out [0:CONV2_FILT-1];
    wire [$clog2(1024):0]    c2_pos;

    conv1d_engine #(
        .IN_CHANNELS (CONV1_FILT),
        .OUT_FILTERS (CONV2_FILT),
        .KERNEL_SIZE (CONV2_KERN),
        .DATA_W      (DATA_W),
        .ACC_W       (ACC_W),
        .SCALE_SHIFT (7)
    ) u_conv2 (
        .clk            (clk),
        .rst_n          (rst_n),
        .enable         (cfg_conv2_en),
        .cfg_kernel_size(3'd5),
        .cfg_num_filters(5'd16),
        .din_valid      (ser_valid),
        .din            (ser_data),
        .din_channel    (ser_ch_idx[$clog2(CONV1_FILT):0]),
        .weight_in      (conv2_w),
        .bias_in        (conv2_b),
        .dout_valid     (c2_valid),
        .dout           (c2_out),
        .dout_pos       (c2_pos)
    );

    // =========================================================
    // STAGE 4: MAXPOOL LAYER 2 (pool=2, 16 channels)
    // =========================================================
    wire        p2_valid;
    wire signed [DATA_W-1:0] p2_out [0:CONV2_FILT-1];

    maxpool1d_unit #(
        .CHANNELS (CONV2_FILT),
        .POOL_SIZE(POOL_SIZE),
        .DATA_W   (DATA_W)
    ) u_pool2 (
        .clk      (clk),
        .rst_n    (rst_n),
        .enable   (1'b1),
        .din_valid(c2_valid),
        .din      (c2_out),
        .dout_valid(p2_valid),
        .dout     (p2_out)
    );

    // =========================================================
    // STAGE 5: FLATTEN & SERIALIZE — 72×16 → 1152 serial stream
    // Dense engine takes one din per clock
    // =========================================================
    reg  [$clog2(FLAT_LEN):0]   flat_idx;
    reg  [$clog2(CONV2_FILT):0] flat_ch;
    reg  [$clog2(POOL2_OUT_LEN):0] flat_pos;
    reg  flat_active;
    reg  flat_valid;
    reg  signed [DATA_W-1:0] flat_data;
    reg  flat_start_d1;

    // Accumulate POOL2_OUT_LEN pool2 outputs, then pass to dense
    reg signed [DATA_W-1:0] flat_buf [0:CONV2_FILT-1][0:POOL2_OUT_LEN-1];
    reg [$clog2(POOL2_OUT_LEN):0] p2_count;

    always @(posedge clk or negedge rst_n) begin : flattener
        integer fc, fp;
        if (!rst_n) begin
            flat_idx    <= 0;
            flat_ch     <= 0;
            flat_pos    <= 0;
            flat_active <= 0;
            flat_valid  <= 0;
            flat_data   <= 0;
            flat_start_d1 <= 0;
            p2_count    <= 0;
        end else begin
            flat_valid    <= 0;
            flat_start_d1 <= 0;

            // Collect pool2 outputs
            if (p2_valid) begin
                for (fc = 0; fc < CONV2_FILT; fc = fc+1)
                    flat_buf[fc][p2_count] <= p2_out[fc];
                if (p2_count == POOL2_OUT_LEN - 1) begin
                    p2_count    <= 0;
                    flat_idx    <= 0;
                    flat_ch     <= 0;
                    flat_pos    <= 0;
                    flat_active <= 1;
                    flat_start_d1 <= 1;  // Dense start trigger
                end else begin
                    p2_count <= p2_count + 1;
                end
            end

            // Serialize: filter-major order (matches dense_w layout)
            if (flat_active) begin
                flat_data  <= flat_buf[flat_ch][flat_pos];
                flat_valid <= 1;
                if (flat_pos == POOL2_OUT_LEN - 1) begin
                    flat_pos <= 0;
                    if (flat_ch == CONV2_FILT - 1) begin
                        flat_ch     <= 0;
                        flat_active <= 0;
                    end else begin
                        flat_ch <= flat_ch + 1;
                    end
                end else begin
                    flat_pos <= flat_pos + 1;
                end
                flat_idx <= flat_idx + 1;
            end
        end
    end

    // =========================================================
    // STAGE 6: DENSE ENGINE 1 (1152 → 16, ReLU)
    // =========================================================
    wire        d1_valid;
    wire signed [DATA_W-1:0] d1_out [0:DENSE1_OUT-1];

    dense_engine #(
        .IN_DIM   (FLAT_LEN),
        .OUT_DIM  (DENSE1_OUT),
        .DATA_W   (DATA_W),
        .ACC_W    (ACC_W),
        .SCALE_SH (7),
        .USE_RELU (1)
    ) u_dense1 (
        .clk       (clk),
        .rst_n     (rst_n),
        .start     (flat_start_d1),
        .din       (flat_data),
        .din_valid (flat_valid),
        .w         (dense1_w),
        .b         (dense1_b),
        .dout_valid(d1_valid),
        .dout      (d1_out)
    );

    // =========================================================
    // STAGE 7: DENSE ENGINE 2 (16 → 1, no ReLU, raw logit)
    // Serialize d1_out 16 elements into dense_engine stream
    // =========================================================
    reg  d2_ser_active;
    reg  [$clog2(DENSE1_OUT):0] d2_ser_idx;
    reg  d2_ser_valid;
    reg  signed [DATA_W-1:0] d2_ser_data;
    reg  d2_start;
    reg  signed [DATA_W-1:0] d2_buf [0:DENSE1_OUT-1];

    always @(posedge clk or negedge rst_n) begin : d2_serializer
        integer di;
        if (!rst_n) begin
            d2_ser_active <= 0;
            d2_ser_idx    <= 0;
            d2_ser_valid  <= 0;
            d2_ser_data   <= 0;
            d2_start      <= 0;
        end else begin
            d2_ser_valid <= 0;
            d2_start     <= 0;
            if (d1_valid) begin
                for (di = 0; di < DENSE1_OUT; di = di+1)
                    d2_buf[di] <= d1_out[di];
                d2_ser_idx    <= 0;
                d2_ser_active <= 1;
                d2_start      <= 1;
            end
            if (d2_ser_active) begin
                d2_ser_data  <= d2_buf[d2_ser_idx];
                d2_ser_valid <= 1;
                if (d2_ser_idx == DENSE1_OUT - 1) begin
                    d2_ser_active <= 0;
                    d2_ser_idx    <= 0;
                end else begin
                    d2_ser_idx <= d2_ser_idx + 1;
                end
            end
        end
    end

    // Out weight reshaped as [DENSE1_OUT][1]
    wire        d2_valid;
    wire signed [DATA_W-1:0] d2_out [0:0];

    dense_engine #(
        .IN_DIM   (DENSE1_OUT),
        .OUT_DIM  (1),
        .DATA_W   (DATA_W),
        .ACC_W    (ACC_W),
        .SCALE_SH (7),
        .USE_RELU (0)
    ) u_dense2 (
        .clk       (clk),
        .rst_n     (rst_n),
        .start     (d2_start),
        .din       (d2_ser_data),
        .din_valid (d2_ser_valid),
        .w         (out_w),
        .b         (out_b),
        .dout_valid(d2_valid),
        .dout      (d2_out)
    );

    // =========================================================
    // STAGE 8: SIGMOID CLASSIFIER
    // =========================================================
    wire        cls_valid;
    wire [7:0]  cls_confidence;
    wire        cls_result;

    sigmoid_classifier #(
        .DATA_W   (16),
        .CONF_W   (8),
        .THRESHOLD(128)
    ) u_sigmoid (
        .clk           (clk),
        .rst_n         (rst_n),
        .valid_in      (d2_valid),
        .logit_in      ({{8{d2_out[0][DATA_W-1]}}, d2_out[0]}),
        .threshold_cfg (cfg_threshold),
        .valid_out     (cls_valid),
        .confidence    (cls_confidence),
        .classification(cls_result)
    );

    assign confidence    = cls_confidence;
    assign arrhythmia_det = cls_result;
    assign result_valid  = cls_valid;

    // =========================================================
    // STAGE 9: SECURE ALERT
    // =========================================================
    secure_alert #(
        .KEY_W     (8),
        .STATIC_KEY(ALERT_KEY)
    ) u_alert (
        .clk                (clk),
        .rst_n              (rst_n),
        .alert_trigger      (cls_valid),
        .arrhythmia_detected(cls_result),
        .confidence         (cls_confidence),
        .timestamp          (32'd0),          // TODO: connect real timestamp counter
        .secure_enable      (cfg_secure_en),
        .key_override       (cfg_enc_key),
        .key_override_en    (cfg_key_override),
        .alert_valid        (),
        .alert_byte_0       (alert_byte_0),
        .alert_byte_1       (alert_byte_1),
        .alert_byte_2       (alert_byte_2),
        .alert_byte_3       (alert_byte_3),
        .alert_severity     (alert_severity)
    );

endmodule
