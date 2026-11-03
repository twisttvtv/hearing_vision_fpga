`timescale 1ns/1ps
// 双帧异步邮箱。cam_pclk 写、系统 clk 读；最多保留两张完整图像。
// 发布/释放指针采用 Gray CDC，读端释放前不会覆盖该帧。
module model_frame_buffer #(
    parameter integer WIDTH=320,
    parameter integer HEIGHT=180,
    parameter integer ADDR_BITS=16
)(
    input wire rst_n,write_clk,read_clk,frame_sync,
    input wire [15:0] pixel_data,
    input wire pixel_valid,
    input wire [8:0] pixel_x,
    input wire [7:0] pixel_y,
    input wire [63:0] capture_time,
    input wire frame_release,
    input wire [ADDR_BITS-1:0] read_addr,
    output reg [15:0] read_data,
    output wire frame_ready,
    output wire [63:0] frame_time,
    output wire [31:0] frame_sequence,dropped_frames,bad_frames
);
    localparam integer PIXELS=WIDTH*HEIGHT;
    // rst_n 可来自另一个时钟域；每一侧独立同步释放复位。
    (* ASYNC_REG="TRUE" *) reg [1:0] write_reset_sync,read_reset_sync;
    wire write_reset_n=write_reset_sync[1];
    wire read_reset_n=read_reset_sync[1];
    always @(posedge write_clk or negedge rst_n) begin
        if(!rst_n) write_reset_sync<=0;
        else write_reset_sync<={write_reset_sync[0],1'b1};
    end
    always @(posedge read_clk or negedge rst_n) begin
        if(!rst_n) read_reset_sync<=0;
        else read_reset_sync<={read_reset_sync[0],1'b1};
    end
    (* ram_style="block" *) reg [15:0] memory[0:2*PIXELS-1];
    reg [1:0] write_ptr,write_gray,read_ptr,read_gray;
    (* ASYNC_REG="TRUE" *) reg [1:0] read_ff1,read_ff2,write_ff1,write_ff2;
    reg [63:0] time_meta[0:1];
    reg [31:0] sequence_meta[0:1];
    reg [63:0] head_time;
    reg [31:0] head_sequence;
    reg metadata_valid;
    reg [31:0] sequence_index,drop_count,error_count,drop_gray,error_gray;
    (* ASYNC_REG="TRUE" *) reg [31:0] drop_ff1,drop_ff2,error_ff1,error_ff2;
    reg capturing;
    reg [ADDR_BITS-1:0] expected_addr;
    wire [1:0] read_binary_sync={read_ff2[1],read_ff2[1]^read_ff2[0]};
    wire full=(write_ptr[1]!=read_binary_sync[1]) && (write_ptr[0]==read_binary_sync[0]);
    wire [1:0] next_write=write_ptr+1'b1;
    wire [1:0] next_read=read_ptr+1'b1;
    wire in_range=pixel_x<WIDTH && pixel_y<HEIGHT;
    wire first_pixel=pixel_x==0 && pixel_y==0;
    wire [ADDR_BITS-1:0] address=pixel_y*WIDTH+pixel_x;
    wire accept_pixel=!frame_sync && !full && pixel_valid && in_range &&
                      (first_pixel || (capturing && address==expected_addr));
    wire [ADDR_BITS:0] write_address=address+(write_ptr[0] ? PIXELS : 0);
    wire [ADDR_BITS:0] read_address=read_addr+(read_ptr[0] ? PIXELS : 0);
    function [31:0] from_gray32;
        input [31:0] g;
        integer i;
        begin
            from_gray32[31]=g[31];
            for(i=30;i>=0;i=i-1) from_gray32[i]=from_gray32[i+1]^g[i];
        end
    endfunction
    wire queue_nonempty=write_ff2!=read_gray;
    // 写端先保存元数据，再在整帧结束时发布 Gray 指针。
    // 经过两级指针同步后，读端锁存稳定的多位元数据，随后才公开 frame_ready。
    // 发布到释放期间写端不改该 bank；XDC 对该 bundled-data 通路限最大延时。
    assign frame_ready=metadata_valid && queue_nonempty;
    assign frame_time=frame_ready ? head_time : 64'd0;
    assign frame_sequence=frame_ready ? head_sequence : 32'd0;
    assign dropped_frames=from_gray32(drop_ff2);
    assign bad_frames=from_gray32(error_ff2);
    always @(posedge write_clk) begin
        if(write_reset_n && accept_pixel) memory[write_address]<=pixel_data;
    end
    always @(posedge read_clk) begin
        if(read_addr<PIXELS) read_data<=memory[read_address];
        else read_data<=0;
    end
    always @(posedge write_clk or negedge write_reset_n) begin
        if(!write_reset_n) begin
            write_ptr<=0;write_gray<=0;read_ff1<=0;read_ff2<=0;
            sequence_index<=0;capturing<=0;expected_addr<=0;
            drop_count<=0;error_count<=0;drop_gray<=0;error_gray<=0;
            time_meta[0]<=0;time_meta[1]<=0;sequence_meta[0]<=0;sequence_meta[1]<=0;
        end else begin
            read_ff1<=read_gray;read_ff2<=read_ff1;
            if(frame_sync) begin
                if(capturing) begin
                    error_count<=error_count+1'b1;
                    error_gray<=(error_count+1'b1)^((error_count+1'b1)>>1);
                end
                capturing<=0;expected_addr<=0;
            end else begin
                if(pixel_valid && in_range && first_pixel) begin
                    sequence_index<=sequence_index+1'b1;
                    if(full) begin
                        drop_count<=drop_count+1'b1;
                        drop_gray<=(drop_count+1'b1)^((drop_count+1'b1)>>1);
                    end else begin
                        time_meta[write_ptr[0]]<=capture_time;
                        sequence_meta[write_ptr[0]]<=sequence_index;
                    end
                    if(capturing) begin
                        error_count<=error_count+1'b1;
                        error_gray<=(error_count+1'b1)^((error_count+1'b1)>>1);
                    end
                end
                if(accept_pixel) begin
                    if(address==PIXELS-1) begin
                        write_ptr<=next_write;write_gray<=next_write^(next_write>>1);
                        capturing<=0;expected_addr<=0;
                    end else begin capturing<=1;expected_addr<=address+1'b1;end
                end else if(pixel_valid && in_range && capturing) begin
                    capturing<=0;expected_addr<=0;
                    error_count<=error_count+1'b1;
                    error_gray<=(error_count+1'b1)^((error_count+1'b1)>>1);
                end
            end
        end
    end
    always @(posedge read_clk or negedge read_reset_n) begin
        if(!read_reset_n) begin
            read_ptr<=0;read_gray<=0;write_ff1<=0;write_ff2<=0;
            drop_ff1<=0;drop_ff2<=0;error_ff1<=0;error_ff2<=0;
            head_time<=0;head_sequence<=0;metadata_valid<=0;
        end else begin
            write_ff1<=write_gray;write_ff2<=write_ff1;
            drop_ff1<=drop_gray;drop_ff2<=drop_ff1;
            error_ff1<=error_gray;error_ff2<=error_ff1;
            if(frame_release && frame_ready) begin
                read_ptr<=next_read;read_gray<=next_read^(next_read>>1);
                metadata_valid<=0;
            end else if(!metadata_valid && queue_nonempty) begin
                head_time<=time_meta[read_ptr[0]];
                head_sequence<=sequence_meta[read_ptr[0]];
                metadata_valid<=1;
            end
        end
    end
endmodule
