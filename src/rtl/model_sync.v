`timescale 1ns/1ps
// 音频使用 system_ticks；视频通过 Gray 编码跨时钟域取得同一时基。
// 单位为系统 clk 周期；它不是摄像头曝光时间或麦克风内部滤波延迟的测量值。
module model_sync(
    input wire clk, camera_clk, rst_n,
    output reg [63:0] system_ticks,
    output wire [63:0] camera_ticks
);
    reg [63:0] ticks_gray;
    wire [63:0] next_ticks=system_ticks+1'b1;
    (* ASYNC_REG="TRUE" *) reg [63:0] gray_ff1,gray_ff2;
    (* ASYNC_REG="TRUE" *) reg [1:0] camera_reset_sync;
    wire camera_reset_n=camera_reset_sync[1];
    always @(posedge camera_clk or negedge rst_n) begin
        if(!rst_n) camera_reset_sync<=0;
        else camera_reset_sync<={camera_reset_sync[0],1'b1};
    end
    function [63:0] from_gray;
        input [63:0] g;
        integer i;
        begin
            from_gray[63]=g[63];
            for(i=62;i>=0;i=i-1) from_gray[i]=from_gray[i+1]^g[i];
        end
    endfunction
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin system_ticks<=0;ticks_gray<=0;end
        else begin system_ticks<=next_ticks;ticks_gray<=next_ticks^(next_ticks>>1);end
    end
    always @(posedge camera_clk or negedge camera_reset_n) begin
        if(!camera_reset_n) begin gray_ff1<=0;gray_ff2<=0;end
        else begin gray_ff1<=ticks_gray;gray_ff2<=gray_ff1;end
    end
    assign camera_ticks=from_gray(gray_ff2);
endmodule
