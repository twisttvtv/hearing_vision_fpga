`timescale 1ns / 1ps

// Sample-rate voice activity detector.
//
// This module sees every I2S sample exactly once, unlike the original
// frame-based scanner which reads overlapping 1920-sample frames four times.
// A DC blocker and one-pole low-pass keep most rumble and high-frequency
// hiss out of the energy estimate. Temporal hysteresis prevents single
// transients from turning the direction display on.
module voice_band_energy_vad_v2 #(
    parameter integer HOP_LEN          = 480,
    parameter integer INIT_HOPS        = 50,
    parameter integer ATTACK_HOPS      = 6,
    parameter integer RELEASE_HOPS     = 25,
    parameter integer ABS_MEAN_POWER   = 32,
    parameter integer NOISE_MULT_SHIFT = 2,
    parameter integer STOP_MULT_SHIFT  = 1,
    // Zero preserves the mean-power parameter; positive values set exact energy.
    parameter integer ABS_FRAME_ENERGY_OVERRIDE = 0
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sample_valid,

    input  wire signed [15:0] x1,
    input  wire signed [15:0] x2,
    input  wire signed [15:0] x3,
    input  wire signed [15:0] x4,

    output wire [47:0]        frame_energy,
    output wire [47:0]        noise_floor,
    output reg                voice_active,
    output reg                hop_valid
);

    localparam integer EW = 42;

    // Total four-channel energy over one hop. An exact override takes priority
    // over the legacy mean-power parameter (6000 is not divisible by 480 * 4).
    localparam [EW-1:0] ABS_FRAME_ENERGY =
        ABS_FRAME_ENERGY_OVERRIDE > 0 ? ABS_FRAME_ENERGY_OVERRIDE :
        HOP_LEN * 4 * ABS_MEAN_POWER;

    localparam [2:0] S_SAMPLE = 3'd0;
    localparam [2:0] S_HP     = 3'd1;
    localparam [2:0] S_LP     = 3'd2;
    localparam [2:0] S_SQ     = 3'd3;
    localparam [2:0] S_ACCUM  = 3'd4;
    localparam [2:0] S_DECIDE = 3'd5;
    localparam [2:0] S_APPLY  = 3'd6;

    reg [2:0]  state;
    reg [15:0] hop_count;
    reg [7:0]  init_count;
    reg [7:0]  attack_count;
    reg [7:0]  release_count;

    reg        init_started;
    reg        init_done;
    reg [EW-1:0] init_min;
    reg [EW-1:0] energy_acc;
    reg [EW-1:0] frame_energy_i;
    reg [EW-1:0] noise_floor_i;

    // The hop decision is split into two clock cycles. This keeps 42-bit
    // subtract/compare logic out of the sample-processing path and is still
    // far faster than the 480-sample hop interval at 48.8 kHz.
    reg [EW-1:0] pending_energy;
    reg [EW-1:0] pending_noise;
    reg [EW-1:0] pending_min;
    reg          pending_attack;
    reg          pending_release;

    // One input sample is processed over several clocks. The I2S sample
    // interval is about 2048 clocks at 100 MHz, so this costs no throughput
    // but removes the filter -> square -> 42-bit accumulator critical path.
    reg signed [15:0] sample_x1;
    reg signed [15:0] sample_x2;
    reg signed [15:0] sample_x3;
    reg signed [15:0] sample_x4;
    reg               sample_is_hop_end;
    reg signed [15:0] bp1_r;
    reg signed [15:0] bp2_r;
    reg signed [15:0] bp3_r;
    reg signed [15:0] bp4_r;
    reg [33:0]        sample_energy_r;

    reg signed [23:0] x1_prev;
    reg signed [23:0] x2_prev;
    reg signed [23:0] x3_prev;
    reg signed [23:0] x4_prev;

    reg signed [23:0] hp1;
    reg signed [23:0] hp2;
    reg signed [23:0] hp3;
    reg signed [23:0] hp4;

    reg signed [23:0] lp1;
    reg signed [23:0] lp2;
    reg signed [23:0] lp3;
    reg signed [23:0] lp4;

    // y[n] = x[n] - x[n-1] + (255/256) * y[n-1]
    wire signed [23:0] sample_x1_ext = {{8{sample_x1[15]}}, sample_x1};
    wire signed [23:0] sample_x2_ext = {{8{sample_x2[15]}}, sample_x2};
    wire signed [23:0] sample_x3_ext = {{8{sample_x3[15]}}, sample_x3};
    wire signed [23:0] sample_x4_ext = {{8{sample_x4[15]}}, sample_x4};

    wire signed [23:0] hp1_calc =
        sample_x1_ext - x1_prev + hp1 - (hp1 >>> 8);
    wire signed [23:0] hp2_calc =
        sample_x2_ext - x2_prev + hp2 - (hp2 >>> 8);
    wire signed [23:0] hp3_calc =
        sample_x3_ext - x3_prev + hp3 - (hp3 >>> 8);
    wire signed [23:0] hp4_calc =
        sample_x4_ext - x4_prev + hp4 - (hp4 >>> 8);

    // Wide, one-pole low-pass. Shift by one gives an approximate 5 kHz cutoff
    // at the configured 48.8 kHz sample rate.
    wire signed [23:0] lp1_calc = lp1 + ((hp1 - lp1) >>> 1);
    wire signed [23:0] lp2_calc = lp2 + ((hp2 - lp2) >>> 1);
    wire signed [23:0] lp3_calc = lp3 + ((hp3 - lp3) >>> 1);
    wire signed [23:0] lp4_calc = lp4 + ((hp4 - lp4) >>> 1);

    wire signed [31:0] bp1_ext = {{16{bp1_r[15]}}, bp1_r};
    wire signed [31:0] bp2_ext = {{16{bp2_r[15]}}, bp2_r};
    wire signed [31:0] bp3_ext = {{16{bp3_r[15]}}, bp3_r};
    wire signed [31:0] bp4_ext = {{16{bp4_r[15]}}, bp4_r};

    wire signed [31:0] sq1 = bp1_ext * bp1_ext;
    wire signed [31:0] sq2 = bp2_ext * bp2_ext;
    wire signed [31:0] sq3 = bp3_ext * bp3_ext;
    wire signed [31:0] sq4 = bp4_ext * bp4_ext;

    wire [33:0] sample_energy_next =
        {2'b00, sq1} + {2'b00, sq2} + {2'b00, sq3} + {2'b00, sq4};

    wire [EW-1:0] energy_after_sample =
        energy_acc + {{(EW-34){1'b0}}, sample_energy_r};

    wire [EW-1:0] start_noise_level =
        noise_floor_i <<< NOISE_MULT_SHIFT;
    wire [EW-1:0] stop_noise_level =
        noise_floor_i <<< STOP_MULT_SHIFT;
    wire [EW-1:0] stop_abs_level = ABS_FRAME_ENERGY >>> 1;

    wire [EW-1:0] start_level =
        (start_noise_level > ABS_FRAME_ENERGY) ?
        start_noise_level : ABS_FRAME_ENERGY;

    wire [EW-1:0] stop_level =
        (stop_noise_level > stop_abs_level) ?
        stop_noise_level : stop_abs_level;

    wire [EW-1:0] noise_down_delta = noise_floor_i - pending_energy;
    wire [EW-1:0] noise_up_delta   = pending_energy - noise_floor_i;
    wire [EW-1:0] noise_down_next =
        noise_floor_i - (noise_down_delta >>> 3);
    wire [EW-1:0] noise_up_next =
        noise_floor_i + (noise_up_delta >>> 6);

    wire [EW-1:0] noise_next =
        (pending_energy < noise_floor_i) ?
        noise_down_next : noise_up_next;

    wire [EW-1:0] init_min_next =
        (!init_started || (pending_energy < init_min)) ?
        pending_energy : init_min;

    assign frame_energy = {{(48-EW){1'b0}}, frame_energy_i};
    assign noise_floor  = {{(48-EW){1'b0}}, noise_floor_i};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= S_SAMPLE;
            hop_count     <= 16'd0;
            init_count    <= 8'd0;
            attack_count  <= 8'd0;
            release_count <= 8'd0;

            init_started  <= 1'b0;
            init_done     <= 1'b0;
            init_min      <= {EW{1'b0}};
            energy_acc    <= {EW{1'b0}};
            frame_energy_i <= {EW{1'b0}};
            noise_floor_i  <= {EW{1'b0}};

            pending_energy  <= {EW{1'b0}};
            pending_noise   <= {EW{1'b0}};
            pending_min     <= {EW{1'b0}};
            pending_attack  <= 1'b0;
            pending_release <= 1'b0;

            sample_x1 <= 16'sd0;
            sample_x2 <= 16'sd0;
            sample_x3 <= 16'sd0;
            sample_x4 <= 16'sd0;
            sample_is_hop_end <= 1'b0;
            bp1_r <= 16'sd0;
            bp2_r <= 16'sd0;
            bp3_r <= 16'sd0;
            bp4_r <= 16'sd0;
            sample_energy_r <= 34'd0;

            x1_prev       <= 24'sd0;
            x2_prev       <= 24'sd0;
            x3_prev       <= 24'sd0;
            x4_prev       <= 24'sd0;
            hp1           <= 24'sd0;
            hp2           <= 24'sd0;
            hp3           <= 24'sd0;
            hp4           <= 24'sd0;
            lp1           <= 24'sd0;
            lp2           <= 24'sd0;
            lp3           <= 24'sd0;
            lp4           <= 24'sd0;

            voice_active  <= 1'b0;
            hop_valid     <= 1'b0;
        end else begin
            hop_valid <= 1'b0;

            case (state)
                S_SAMPLE: begin
                    if (sample_valid) begin
                        sample_x1 <= x1;
                        sample_x2 <= x2;
                        sample_x3 <= x3;
                        sample_x4 <= x4;
                        sample_is_hop_end <=
                            (hop_count == HOP_LEN - 1);
                        state <= S_HP;
                    end
                end

                S_HP: begin
                    x1_prev <= sample_x1_ext;
                    x2_prev <= sample_x2_ext;
                    x3_prev <= sample_x3_ext;
                    x4_prev <= sample_x4_ext;

                    hp1 <= hp1_calc;
                    hp2 <= hp2_calc;
                    hp3 <= hp3_calc;
                    hp4 <= hp4_calc;
                    state <= S_LP;
                end

                S_LP: begin
                    lp1 <= lp1_calc;
                    lp2 <= lp2_calc;
                    lp3 <= lp3_calc;
                    lp4 <= lp4_calc;

                    bp1_r <= lp1_calc[23:8];
                    bp2_r <= lp2_calc[23:8];
                    bp3_r <= lp3_calc[23:8];
                    bp4_r <= lp4_calc[23:8];
                    state <= S_SQ;
                end

                S_SQ: begin
                    sample_energy_r <= sample_energy_next;
                    state <= S_ACCUM;
                end

                S_ACCUM: begin
                    if (sample_is_hop_end) begin
                        pending_energy <= energy_after_sample;
                        energy_acc     <= {EW{1'b0}};
                        hop_count      <= 16'd0;
                        state          <= S_DECIDE;
                    end else begin
                        energy_acc <= energy_after_sample;
                        hop_count  <= hop_count + 1'b1;
                        state      <= S_SAMPLE;
                    end
                end

                S_DECIDE: begin
                    pending_noise   <= noise_next;
                    pending_min     <= init_min_next;
                    pending_attack  <= (pending_energy > start_level);
                    pending_release <= (pending_energy < stop_level);
                    state <= S_APPLY;
                end

                S_APPLY: begin
                    frame_energy_i <= pending_energy;
                    hop_valid      <= 1'b1;

                    if (!init_done) begin
                        init_started <= 1'b1;
                        init_min     <= pending_min;

                        if (init_count == INIT_HOPS - 1) begin
                            noise_floor_i <= pending_min;
                            init_done     <= 1'b1;
                            attack_count  <= 8'd0;
                            release_count <= 8'd0;
                            voice_active  <= 1'b0;
                        end else begin
                            init_count <= init_count + 1'b1;
                        end
                    end else if (!voice_active) begin
                        release_count <= 8'd0;

                        if (pending_attack) begin
                            // Do not let a speech candidate pull the noise
                            // floor upward. Require a run of consecutive hops.
                            if (attack_count >= ATTACK_HOPS - 1) begin
                                attack_count <= 8'd0;
                                voice_active <= 1'b1;
                            end else begin
                                attack_count <= attack_count + 1'b1;
                            end
                        end else begin
                            attack_count <= 8'd0;
                            noise_floor_i <= pending_noise;
                        end
                    end else begin
                        attack_count <= 8'd0;

                        if (pending_release) begin
                            if (release_count >= RELEASE_HOPS - 1) begin
                                release_count <= 8'd0;
                                voice_active  <= 1'b0;
                                noise_floor_i <= pending_noise;
                            end else begin
                                release_count <= release_count + 1'b1;
                            end
                        end else begin
                            release_count <= 8'd0;
                        end
                    end

                    state <= S_SAMPLE;
                end

                default: begin
                    state <= S_SAMPLE;
                end
            endcase
        end
    end

endmodule
