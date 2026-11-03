`timescale 1ns / 1ps

module inmp441_4ch_rx #(
    parameter integer CLK_DIV = 32
)(
    input  wire        clk,
    input  wire        rst_n,

    output reg         sck,
    output reg         ws,

    input  wire        sd_lr,
    input  wire        sd_ud,

    output reg signed [23:0] mic_left,
    output reg signed [23:0] mic_right,
    output reg signed [23:0] mic_up,
    output reg signed [23:0] mic_down,
    output reg               sample_valid
);

    wire sck_toggle;
    wire sck_rise;
    wire sck_fall;

    reg [15:0] div_cnt;
    reg [5:0]  bit_cnt;

    reg [23:0] slot_lr_l;
    reg [23:0] slot_lr_r;
    reg [23:0] slot_ud_l;
    reg [23:0] slot_ud_r;

    assign sck_toggle = (div_cnt == (CLK_DIV/2 - 1));
    assign sck_rise   = sck_toggle && !sck;
    assign sck_fall   = sck_toggle &&  sck;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_cnt      <= 16'd0;
            sck          <= 1'b0;
            ws           <= 1'b0;
            bit_cnt      <= 6'd0;

            slot_lr_l    <= 24'sd0;
            slot_lr_r    <= 24'sd0;
            slot_ud_l    <= 24'sd0;
            slot_ud_r    <= 24'sd0;

            mic_left     <= 24'sd0;
            mic_right    <= 24'sd0;
            mic_up       <= 24'sd0;
            mic_down     <= 24'sd0;
            sample_valid <= 1'b0;
        end else begin
            sample_valid <= 1'b0;

            if (sck_toggle) begin
                div_cnt <= 16'd0;
                sck     <= ~sck;
            end else begin
                div_cnt <= div_cnt + 1'b1;
            end

            // 跳过每个声道的第一个填充位，
            // 只捕获后面的 24 个数据位。
            if (sck_rise) begin
                if ((bit_cnt >= 6'd2) && (bit_cnt <= 6'd25)) begin
                    slot_lr_l <= {slot_lr_l[22:0], sd_lr};
                    slot_ud_l <= {slot_ud_l[22:0], sd_ud};
                end else if ((bit_cnt >= 6'd34) &&
                             (bit_cnt <= 6'd57)) begin
                    slot_lr_r <= {slot_lr_r[22:0], sd_lr};
                    slot_ud_r <= {slot_ud_r[22:0], sd_ud};
                end
            end

            if (sck_fall) begin
                if (bit_cnt == 6'd32)
                    ws <= 1'b1;
                else if (bit_cnt == 6'd63)
                    ws <= 1'b0;

                // 右侧最后一个数据位已经捕获完成
                if (bit_cnt == 6'd57) begin
                    mic_left     <= slot_lr_l;
                    mic_right    <= slot_lr_r;
                    mic_up       <= slot_ud_l;
                    mic_down     <= slot_ud_r;
                    sample_valid <= 1'b1;
                end

                if (bit_cnt == 6'd63)
                    bit_cnt <= 6'd0;
                else
                    bit_cnt <= bit_cnt + 1'b1;
            end
        end
    end

endmodule