`timescale 1ns / 1ps
// J3 水平 270° 舵机。中位 1500 us = 正前方。
// 中位以麦克风“上”为正前方。REVERSE_DIRECTION 适配舵机的实际安装转向。
// 基础角度表：上 0°，左上/右上 ±45°，左/右 ±90°，左下/右下 ±120°。
// 正下是后方；REAR_NEAREST_ENDPOINT=1 时选择较近的既有 ±120° 端点。
// conf < 80 时保持当前角度，不回中。force_center=1 时才慢慢回到 1500 us。
// 复位和上电后的第一段脉宽就是 1500 us，输出在 boot 期间保持低。
// 本模块不再区分俯仰轴。J5 不能再接到这个 PWM。
module servo_pwm #(
    parameter integer CLK_HZ     = 100_000_000,
    parameter integer SIMULATION = 0,
    parameter integer REVERSE_DIRECTION = 0,
    parameter integer REAR_NEAREST_ENDPOINT = 0
) (
    input  wire        clk,
    input  wire        rst,
    input  wire [2:0]  dir,
    input  wire [7:0]  conf,
    input  wire        force_center,
    output reg         pwm,
    output wire        moving,
    output wire [31:0] pulse_ticks
);
    localparam integer CONF_MIN = 80;
    localparam integer PERIOD   = SIMULATION ? 2000 : CLK_HZ / 50;
    localparam integer CENTER   = SIMULATION ? 150  : (CLK_HZ / 1000) * 3 / 2;
    localparam integer STEP_LIM = SIMULATION ? 100_000 : CLK_HZ / 50000;
    // 与 servo270 相同的整数截断：deg * 200000 / 270。仿真把脉宽缩小到同一比例。
    localparam integer SPAN     = SIMULATION ? 200 : (CLK_HZ / 1000) * 2;
    localparam integer OFF45    = 45 * SPAN / 270;
    localparam integer OFF90    = 90 * SPAN / 270;
    localparam integer OFF120   = 120 * SPAN / 270;

    reg [$clog2(PERIOD)-1:0] cnt = 0;
    reg [7:0] boot = 8'd0;
    integer pulse = CENTER;
    integer offset = 0;
    integer target, err, step;
    integer step_r = 0;

    assign moving = (boot != 8'hFF) || (pulse != target);
    assign pulse_ticks = pulse;

    function integer angle_offset;
        input [2:0] d;
        begin
            case (d)
                3'd2, 3'd6: angle_offset = 0;
                3'd3:       angle_offset = -OFF45;
                3'd4:       angle_offset = -OFF90;
                3'd5:       angle_offset = -OFF120;
                3'd1:       angle_offset =  OFF45;
                3'd0:       angle_offset =  OFF90;
                3'd7:       angle_offset =  OFF120;
                default:    angle_offset = 0;
            endcase
        end
    endfunction

    always @(*) begin
        target = CENTER + (REVERSE_DIRECTION ? -offset : offset);
        err = target - pulse;
        if (SIMULATION)
            step = err;
        else
            step = err >>> 3;
        if (step == 0 && err > 0)
            step = 1;
        else if (step == 0 && err < 0)
            step = -1;
        if (step > STEP_LIM)
            step = STEP_LIM;
        else if (step < -STEP_LIM)
            step = -STEP_LIM;
    end

    always @(posedge clk) begin
        if (boot != 8'hFF) begin
            boot    <= boot + 8'd1;
            cnt     <= 0;
            pwm     <= 1'b0;
            pulse   <= CENTER;
            offset  <= 0;
            step_r  <= 0;
        end else if (!rst) begin
            cnt     <= 0;
            pwm     <= 1'b0;
            pulse   <= CENTER;
            offset  <= 0;
            step_r  <= 0;
        end else begin
            step_r <= step;
            if (force_center)
                offset <= 0;
            else if (conf >= CONF_MIN) begin
                if (dir == 3'd6 && REAR_NEAREST_ENDPOINT) begin
                    // Select by current pulse, so reversing the mounting does
                    // not change which physical endpoint is nearer. At home,
                    // equal distances consistently select logical left.
                    if (pulse < CENTER)
                        offset <= REVERSE_DIRECTION ? OFF120 : -OFF120;
                    else if (pulse > CENTER)
                        offset <= REVERSE_DIRECTION ? -OFF120 : OFF120;
                    else
                        offset <= -OFF120;
                end else
                    offset <= angle_offset(dir);
            end

            if (cnt >= PERIOD - 1) begin
                cnt   <= 0;
                pulse <= pulse + step_r;
            end else begin
                cnt <= cnt + 1;
            end

            pwm <= (cnt < pulse);
        end
    end
endmodule
