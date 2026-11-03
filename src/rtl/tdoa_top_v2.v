`timescale 1ns / 1ps

module tdoa_top_v2 #(
    parameter integer CLK_DIV              = 32,
    parameter integer FRAME_LEN            = 1920,
    parameter integer HOP_LEN              = 480,
    parameter integer MAX_DELAY            = 6,
    parameter integer ADDR_WIDTH           = 11,
    parameter integer VAD_INIT_FRAMES      = 64,

    parameter integer VAD_INIT_HOPS        = 50,
    parameter integer VAD_ATTACK_HOPS      = 6,
    parameter integer VAD_RELEASE_HOPS     = 25,
    parameter integer VAD_ABS_MEAN_POWER   = 32,
    parameter integer VAD_NOISE_MULT_SHIFT = 2,
    parameter integer VAD_STOP_MULT_SHIFT  = 1,
    parameter integer CORR_CONF_SHIFT      = 4,
    parameter integer VAD_ABS_FRAME_ENERGY = 0
)(
    input  wire                         clk,
    input  wire                         rst_n,

    output wire                         mic_sck,
    output wire                         mic_ws,
    input  wire                         mic_sd_lr,
    input  wire                         mic_sd_ud,

    output wire signed [15:0]           smooth_dx_q8_8,
    output wire signed [15:0]           smooth_dy_q8_8,
    output wire signed [15:0]           raw_dx_q8_8,
    output wire signed [15:0]           raw_dy_q8_8,

    output wire                         result_valid,
    output wire                         voice_active,

    output wire [15:0]                  angle_bin,
    output wire [2:0]                   direction_index,
    output wire                         angle_valid,

    output wire                         mic_sample_valid_dbg,
    output wire                         frame_valid_dbg,
    output wire                         frame_sel_dbg,
    output wire signed [23:0]            pcm_left,pcm_up,pcm_right,pcm_down,
    output wire [47:0]                   vad_energy,vad_noise,
    output wire                         pcm_valid
);

    wire signed [23:0] mic_left_24;
    wire signed [23:0] mic_right_24;
    wire signed [23:0] mic_up_24;
    wire signed [23:0] mic_down_24;
    wire               mic_sample_valid;
    assign pcm_left=mic_left_24;
    assign pcm_up=mic_up_24;
    assign pcm_right=mic_right_24;
    assign pcm_down=mic_down_24;
    assign pcm_valid=mic_sample_valid;

    inmp441_4ch_rx #(
        .CLK_DIV (CLK_DIV)
    ) u_inmp441_rx (
        .clk          (clk),
        .rst_n        (rst_n),

        .sck          (mic_sck),
        .ws           (mic_ws),

        .sd_lr        (mic_sd_lr),
        .sd_ud        (mic_sd_ud),

        .mic_left     (mic_left_24),
        .mic_right    (mic_right_24),
        .mic_up       (mic_up_24),
        .mic_down     (mic_down_24),

        .sample_valid (mic_sample_valid)
    );

    wire signed [15:0] mic_left_16  = mic_left_24[23:8];
    wire signed [15:0] mic_right_16 = mic_right_24[23:8];
    wire signed [15:0] mic_up_16    = mic_up_24[23:8];
    wire signed [15:0] mic_down_16  = mic_down_24[23:8];

    // Sample-rate VAD. It runs on the live stream, so its IIR filter state
    // advances exactly once per sample instead of once per overlapping frame.
    wire [47:0] vad_frame_energy;
    wire [47:0] vad_noise_floor;
    assign vad_energy=vad_frame_energy;
    assign vad_noise=vad_noise_floor;
    wire        vad_hop_valid;

    wire voice_active_vad;
    wire [47:0] vad_frame_energy_dbg = vad_frame_energy;
    wire [47:0] vad_noise_floor_dbg = vad_noise_floor;

    voice_band_energy_vad_v2 #(
        .HOP_LEN          (HOP_LEN),
        .INIT_HOPS        (VAD_INIT_HOPS),
        .ATTACK_HOPS      (VAD_ATTACK_HOPS),
        .RELEASE_HOPS     (VAD_RELEASE_HOPS),
        .ABS_MEAN_POWER   (VAD_ABS_MEAN_POWER),
        .ABS_FRAME_ENERGY_OVERRIDE (VAD_ABS_FRAME_ENERGY),
        .NOISE_MULT_SHIFT (VAD_NOISE_MULT_SHIFT),
        .STOP_MULT_SHIFT  (VAD_STOP_MULT_SHIFT)
    ) u_voice_vad (
        .clk          (clk),
        .rst_n        (rst_n),
        .sample_valid (mic_sample_valid),

        .x1           (mic_left_16),
        .x2           (mic_up_16),
        .x3           (mic_right_16),
        .x4           (mic_down_16),

        .frame_energy (vad_frame_energy),
        .noise_floor  (vad_noise_floor),
        .voice_active (voice_active_vad),
        .hop_valid    (vad_hop_valid)
    );

    assign voice_active = voice_active_vad;

    wire [ADDR_WIDTH-1:0] frame_rd_addr;

    wire signed [15:0] frame_x1_rd;
    wire signed [15:0] frame_x2_rd;
    wire signed [15:0] frame_x3_rd;
    wire signed [15:0] frame_x4_rd;

    wire frame_valid;
    wire frame_sel;

    frame_buffer_4ch #(
        .FRAME_LEN  (FRAME_LEN),
        .HOP_LEN    (HOP_LEN),
        .DATA_WIDTH (16),
        .ADDR_WIDTH (ADDR_WIDTH)
    ) u_frame_buffer (
        .clk          (clk),
        .rst_n        (rst_n),

        .sample_valid (mic_sample_valid),

        .x1           (mic_left_16),
        .x2           (mic_up_16),
        .x3           (mic_right_16),
        .x4           (mic_down_16),

        .rd_addr      (frame_rd_addr),

        .x1_rd        (frame_x1_rd),
        .x2_rd        (frame_x2_rd),
        .x3_rd        (frame_x3_rd),
        .x4_rd        (frame_x4_rd),

        .frame_valid  (frame_valid),
        .frame_sel    (frame_sel)
    );

    wire result_valid_sched;
    wire corr_confident;

    tdoa_scheduler_v2 #(
        .FRAME_LEN       (FRAME_LEN),
        .MAX_DELAY       (MAX_DELAY),
        .ADDR_WIDTH      (ADDR_WIDTH),
        .VAD_INIT_FRAMES (VAD_INIT_FRAMES),
        .CORR_CONF_SHIFT (CORR_CONF_SHIFT)
    ) u_tdoa_scheduler (
        .clk              (clk),
        .rst_n            (rst_n),

        .frame_valid      (frame_valid),
        .voice_active     (voice_active_vad),

        .x1_rd            (frame_x1_rd),
        .x2_rd            (frame_x2_rd),
        .x3_rd            (frame_x3_rd),
        .x4_rd            (frame_x4_rd),

        .rd_addr          (frame_rd_addr),

        .smooth_dx_q8_8   (smooth_dx_q8_8),
        .smooth_dy_q8_8   (smooth_dy_q8_8),
        .raw_dx_q8_8      (raw_dx_q8_8),
        .raw_dy_q8_8      (raw_dy_q8_8),

        .result_valid     (result_valid_sched),
        .confidence_valid (corr_confident)
    );

    assign result_valid = result_valid_sched;

    wire cordic_done;
    wire cordic_busy;

    cordic_atan2 #(
        .DATA_WIDTH   (16),
        .CORDIC_WIDTH (20),
        .ITERATIONS   (16)
    ) u_cordic_atan2 (
        .clk       (clk),
        .rst_n     (rst_n),

        .start     (result_valid_sched),
        .dx_q8_8   (smooth_dx_q8_8),
        .dy_q8_8   (smooth_dy_q8_8),

        .angle_bin (angle_bin),
        .done      (cordic_done),
        .busy      (cordic_busy)
    );

    assign angle_valid = cordic_done;

    // 0=right, 1=upper-right, 2=up, 3=upper-left,
    // 4=left, 5=lower-left, 6=down, 7=lower-right.
    assign direction_index =
        ((angle_bin + 16'h1000) >> 13) & 3'b111;

    assign mic_sample_valid_dbg = mic_sample_valid;
    assign frame_valid_dbg      = frame_valid;
    assign frame_sel_dbg        = frame_sel;

endmodule
