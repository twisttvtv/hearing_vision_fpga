`timescale 1ns / 1ps

module cordic_atan2 #(
    parameter integer DATA_WIDTH   = 16,
    parameter integer CORDIC_WIDTH = 20,
    parameter integer ITERATIONS   = 16
)(
    input  wire                         clk,
    input  wire                         rst_n,

    input  wire                         start,
    input  wire signed [DATA_WIDTH-1:0] dx_q8_8,
    input  wire signed [DATA_WIDTH-1:0] dy_q8_8,

    output reg  [15:0]                  angle_bin,
    output reg                          done,
    output reg                          busy
);

    localparam [1:0] S_IDLE = 2'd0;
    localparam [1:0] S_RUN  = 2'd1;
    localparam [1:0] S_QUAD = 2'd2;

    reg [1:0] state;

    reg start_d;
    wire start_pulse = start & ~start_d;

    reg x_sign;
    reg y_sign;

    reg signed [CORDIC_WIDTH-1:0] x_reg;
    reg signed [CORDIC_WIDTH-1:0] y_reg;

    // 比 16 bit 多一位，允许 CORDIC 中间角度略有负值
    reg signed [16:0] z_reg;

    reg [4:0]  iter;
    reg [15:0] base_angle;

    // atan(2^-i) 的二进制角度表
    // 65536 表示 360 度，8192 表示 45 度
    function [15:0] atan_value;
        input [4:0] index;
        begin
            case (index)
                5'd0:  atan_value = 16'd8192;  // 45.0000°
                5'd1:  atan_value = 16'd4836;  // 26.5651°
                5'd2:  atan_value = 16'd2555;  // 14.0362°
                5'd3:  atan_value = 16'd1297;  //  7.1250°
                5'd4:  atan_value = 16'd651;   //  3.5763°
                5'd5:  atan_value = 16'd326;   //  1.7899°
                5'd6:  atan_value = 16'd163;   //  0.8952°
                5'd7:  atan_value = 16'd81;    //  0.4476°
                5'd8:  atan_value = 16'd41;    //  0.2238°
                5'd9:  atan_value = 16'd20;    //  0.1119°
                5'd10: atan_value = 16'd10;    //  0.0560°
                5'd11: atan_value = 16'd5;     //  0.0280°
                5'd12: atan_value = 16'd3;     //  0.0140°
                5'd13: atan_value = 16'd1;     //  0.0070°
                5'd14: atan_value = 16'd1;     //  0.0035°
                5'd15: atan_value = 16'd0;     //  0.0017°
                default: atan_value = 16'd0;
            endcase
        end
    endfunction

    // 扩展为 CORDIC_WIDTH bit 有符号数
    wire signed [CORDIC_WIDTH-1:0] dx_ext =
        {{(CORDIC_WIDTH-DATA_WIDTH){dx_q8_8[DATA_WIDTH-1]}},
          dx_q8_8};

    wire signed [CORDIC_WIDTH-1:0] dy_ext =
        {{(CORDIC_WIDTH-DATA_WIDTH){dy_q8_8[DATA_WIDTH-1]}},
          dy_q8_8};

    // 第一象限使用绝对值
    wire signed [CORDIC_WIDTH-1:0] dx_abs =
        dx_ext[CORDIC_WIDTH-1] ? -dx_ext : dx_ext;

    wire signed [CORDIC_WIDTH-1:0] dy_abs =
        dy_ext[CORDIC_WIDTH-1] ? -dy_ext : dy_ext;

    wire signed [15:0] atan_step_value =
        atan_value(iter);

    wire signed [16:0] atan_step =
        {1'b0, atan_step_value[15:0]};

    wire signed [CORDIC_WIDTH-1:0] x_shift =
        x_reg >>> iter;

    wire signed [CORDIC_WIDTH-1:0] y_shift =
        y_reg >>> iter;

    // CORDIC 向量模式
    wire signed [CORDIC_WIDTH-1:0] x_next =
        y_reg[CORDIC_WIDTH-1] ?
        (x_reg - y_shift) :
        (x_reg + y_shift);

    wire signed [CORDIC_WIDTH-1:0] y_next =
        y_reg[CORDIC_WIDTH-1] ?
        (y_reg + x_shift) :
        (y_reg - x_shift);

    wire signed [16:0] z_next =
        y_reg[CORDIC_WIDTH-1] ?
        (z_reg - atan_step) :
        (z_reg + atan_step);

    // 这一拍直接使用当前 z_reg，不能使用旧的 base_angle
    wire [15:0] base_angle_now =
        (z_reg < 0) ? 16'd0 :
        (z_reg > 17'sd16384) ? 16'd16384 :
        z_reg[15:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;

            start_d    <= 1'b0;
            x_sign     <= 1'b0;
            y_sign     <= 1'b0;

            x_reg      <= {CORDIC_WIDTH{1'b0}};
            y_reg      <= {CORDIC_WIDTH{1'b0}};
            z_reg      <= 17'sd0;
            iter       <= 5'd0;
            base_angle <= 16'd0;

            angle_bin  <= 16'd0;
            done       <= 1'b0;
            busy       <= 1'b0;
        end else begin
            start_d <= start;
            done    <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start_pulse) begin
                        x_sign <= dx_q8_8[DATA_WIDTH-1];
                        y_sign <= dy_q8_8[DATA_WIDTH-1];

                        busy <= 1'b1;

                        if ((dx_abs == 0) && (dy_abs == 0)) begin
                            // atan2(0,0) 定义为 0 度
                            z_reg <= 17'sd0;
                            state <= S_QUAD;
                        end else if (dx_abs == 0) begin
                            // 角度为 +90 度或 -90 度
                            z_reg <= 17'sd16384;
                            state <= S_QUAD;
                        end else if (dy_abs == 0) begin
                            // 角度为 0 度或 180 度
                            z_reg <= 17'sd0;
                            state <= S_QUAD;
                        end else begin
                            x_reg <= dx_abs;
                            y_reg <= dy_abs;
                            z_reg <= 17'sd0;
                            iter  <= 5'd0;
                            state <= S_RUN;
                        end
                    end
                end

                S_RUN: begin
                    x_reg <= x_next;
                    y_reg <= y_next;
                    z_reg <= z_next;

                    if (iter == (ITERATIONS-1)) begin
                        state <= S_QUAD;
                    end else begin
                        iter <= iter + 1'b1;
                    end
                end

                S_QUAD: begin
                    base_angle <= base_angle_now;

                    // 根据 dx、dy 的符号恢复完整 0~360 度
                    case ({x_sign, y_sign})
                        2'b00: begin
                            // dx >= 0, dy >= 0
                            angle_bin <= base_angle_now;
                        end

                        2'b10: begin
                            // dx < 0, dy >= 0
                            angle_bin <= 16'h8000 - base_angle_now;
                        end

                        2'b11: begin
                            // dx < 0, dy < 0
                            angle_bin <= 16'h8000 + base_angle_now;
                        end

                        2'b01: begin
                            // dx >= 0, dy < 0
                            // 16 bit 自动回绕
                            angle_bin <= 16'h0000 - base_angle_now;
                        end

                        default: begin
                            angle_bin <= 16'd0;
                        end
                    endcase

                    busy  <= 1'b0;
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule