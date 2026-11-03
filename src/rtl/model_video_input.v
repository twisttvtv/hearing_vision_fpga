`timescale 1ns/1ps
// 全画面等比例抽样：1280x720 -> 320x180。保留 RGB565，供后端找脸后裁出 112x112。
// 这里不把整幅缩略图冒充人脸，也不进行说话人判定。
module model_video_input #(
    parameter integer SOURCE_WIDTH=1280,
    parameter integer SOURCE_HEIGHT=720,
    parameter integer STEP_BITS=2
)(
    input wire camera_clk,rst_n,
    input wire [15:0] pixel_data,
    input wire pixel_valid,
    input wire [11:0] pixel_x,pixel_y,
    output reg [15:0] video_data,
    output reg video_valid,
    output reg [8:0] video_x,
    output reg [7:0] video_y
);
    localparam integer MASK=(1<<STEP_BITS)-1;
    always @(posedge camera_clk or negedge rst_n) begin
        if(!rst_n) begin video_data<=0;video_valid<=0;video_x<=0;video_y<=0;end
        else begin
            video_valid<=0;
            if(pixel_valid && pixel_x<SOURCE_WIDTH && pixel_y<SOURCE_HEIGHT &&
               (pixel_x&MASK)==0 && (pixel_y&MASK)==0) begin
                video_data<=pixel_data;video_valid<=1;
                video_x<=pixel_x>>STEP_BITS;video_y<=pixel_y>>STEP_BITS;
            end
        end
    end
endmodule
