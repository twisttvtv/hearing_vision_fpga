`timescale 1ns / 1ps

// Frame statistics + TDOA scheduler with a correlation-confidence gate.
//
// The original energy_vad module is retained only for per-frame means,
// raw frame energy, and an aligned scan state machine. Voice activity is
// supplied by voice_band_energy_vad_v2, which runs once per input sample.
module tdoa_scheduler_v2 #(
    parameter integer FRAME_LEN       = 1920,
    parameter integer MAX_DELAY       = 6,
    parameter integer ADDR_WIDTH      = 11,
    parameter integer VAD_INIT_FRAMES = 64,
    parameter integer CORR_CONF_SHIFT = 4
)(
    input  wire                         clk,
    input  wire                         rst_n,

    input  wire                         frame_valid,
    input  wire                         voice_active,

    input  wire signed [15:0]           x1_rd,
    input  wire signed [15:0]           x2_rd,
    input  wire signed [15:0]           x3_rd,
    input  wire signed [15:0]           x4_rd,

    output wire [ADDR_WIDTH-1:0]        rd_addr,

    output reg  signed [15:0]           smooth_dx_q8_8,
    output reg  signed [15:0]           smooth_dy_q8_8,
    output reg  signed [15:0]           raw_dx_q8_8,
    output reg  signed [15:0]           raw_dy_q8_8,

    output reg                          result_valid,
    output reg                          confidence_valid
);

    localparam [1:0] S_IDLE    = 2'd0;
    localparam [1:0] S_DX_WAIT = 2'd1;
    localparam [1:0] S_DY_WAIT = 2'd2;

    reg [1:0] state;

    wire [ADDR_WIDTH-1:0] energy_rd_addr;
    wire [ADDR_WIDTH-1:0] corr_rd_addr;

    reg       rd_sel;
    reg       pair_sel;
    reg       corr_start;
    reg       smooth_init;
    reg       dx_conf_ok;
    reg signed [15:0] dx_result_q8_8;

    wire        energy_valid;
    wire        mean_valid;
    wire        voice_active_energy_unused;
    wire [47:0] frame_energy;
    wire [47:0] noise_floor_unused;

    wire signed [31:0] sum1_out;
    wire signed [31:0] sum2_out;
    wire signed [31:0] sum3_out;
    wire signed [31:0] sum4_out;

    wire signed [15:0] mean1;
    wire signed [15:0] mean2;
    wire signed [15:0] mean3;
    wire signed [15:0] mean4;

    wire signed [15:0] tdoa_int;
    wire signed [15:0] tdoa_frac_q8_8;
    wire signed [47:0] max_corr;

    wire corr_done;
    wire corr_busy;

    wire signed [15:0] corr_total_q8_8 =
        (tdoa_int <<< 8) + tdoa_frac_q8_8;

    wire [47:0] corr_peak_floor =
        frame_energy >>> CORR_CONF_SHIFT;

    wire corr_peak_ok =
        (max_corr > 48'sd0) &&
        (max_corr[47:0] > corr_peak_floor);

    wire signed [16:0] smooth_dx_calc =
        smooth_dx_q8_8 +
        ((dx_result_q8_8 - smooth_dx_q8_8) >>> 3);

    wire signed [16:0] smooth_dy_calc =
        smooth_dy_q8_8 +
        ((corr_total_q8_8 - smooth_dy_q8_8) >>> 3);

    assign rd_addr = rd_sel ? corr_rd_addr : energy_rd_addr;

    // The original module is used as a frame scanner. Its own voice_active
    // output is intentionally ignored because the sample-rate VAD is used.
    energy_vad #(
        .FRAME_LEN       (FRAME_LEN),
        .ADDR_WIDTH      (ADDR_WIDTH),
        .VAD_INIT_FRAMES (VAD_INIT_FRAMES)
    ) u_frame_stats (
        .clk          (clk),
        .rst_n        (rst_n),
        .frame_valid  (frame_valid),

        .x1_rd        (x1_rd),
        .x2_rd        (x2_rd),
        .x3_rd        (x3_rd),
        .x4_rd        (x4_rd),

        .rd_addr      (energy_rd_addr),

        .frame_energy (frame_energy),
        .energy_valid (energy_valid),
        .voice_active (voice_active_energy_unused),
        .noise_floor  (noise_floor_unused),

        .sum1_out     (sum1_out),
        .sum2_out     (sum2_out),
        .sum3_out     (sum3_out),
        .sum4_out     (sum4_out),

        .mean1        (mean1),
        .mean2        (mean2),
        .mean3        (mean3),
        .mean4        (mean4),
        .mean_valid   (mean_valid)
    );

    corr_engine #(
        .FRAME_LEN  (FRAME_LEN),
        .MAX_DELAY  (MAX_DELAY),
        .ADDR_WIDTH (ADDR_WIDTH)
    ) u_corr_engine (
        .clk             (clk),
        .rst_n           (rst_n),

        .start           (corr_start),
        .pair_sel        (pair_sel),

        .mean1           (mean1),
        .mean2           (mean2),
        .mean3           (mean3),
        .mean4           (mean4),

        .x1_rd           (x1_rd),
        .x2_rd           (x2_rd),
        .x3_rd           (x3_rd),
        .x4_rd           (x4_rd),

        .rd_addr         (corr_rd_addr),

        .tdoa_int        (tdoa_int),
        .tdoa_frac_q8_8  (tdoa_frac_q8_8),
        .max_corr        (max_corr),
        .done            (corr_done),
        .busy            (corr_busy)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state               <= S_IDLE;
            rd_sel              <= 1'b0;
            pair_sel            <= 1'b0;
            corr_start          <= 1'b0;
            smooth_init         <= 1'b0;
            dx_conf_ok          <= 1'b0;
            dx_result_q8_8      <= 16'sd0;

            raw_dx_q8_8         <= 16'sd0;
            raw_dy_q8_8         <= 16'sd0;
            smooth_dx_q8_8      <= 16'sd0;
            smooth_dy_q8_8      <= 16'sd0;

            result_valid        <= 1'b0;
            confidence_valid    <= 1'b0;
        end else begin
            corr_start       <= 1'b0;
            result_valid     <= 1'b0;
            confidence_valid <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (energy_valid && mean_valid && voice_active) begin
                        pair_sel   <= 1'b0;
                        corr_start <= 1'b1;
                        rd_sel     <= 1'b1;
                        state      <= S_DX_WAIT;
                    end
                end

                S_DX_WAIT: begin
                    if (corr_done) begin
                        dx_result_q8_8 <= corr_total_q8_8;
                        dx_conf_ok     <= corr_peak_ok;

                        pair_sel   <= 1'b1;
                        corr_start <= 1'b1;
                        state      <= S_DY_WAIT;
                    end
                end

                S_DY_WAIT: begin
                    if (corr_done) begin
                        rd_sel <= 1'b0;

                        if (voice_active && dx_conf_ok && corr_peak_ok) begin
                            raw_dx_q8_8 <= dx_result_q8_8;
                            raw_dy_q8_8 <= corr_total_q8_8;

                            if (!smooth_init) begin
                                smooth_dx_q8_8 <= dx_result_q8_8;
                                smooth_dy_q8_8 <= corr_total_q8_8;
                                smooth_init    <= 1'b1;
                            end else begin
                                smooth_dx_q8_8 <= smooth_dx_calc[15:0];
                                smooth_dy_q8_8 <= smooth_dy_calc[15:0];
                            end

                            result_valid     <= 1'b1;
                            confidence_valid <= 1'b1;
                        end

                        state <= S_IDLE;
                    end
                end

                default: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule
