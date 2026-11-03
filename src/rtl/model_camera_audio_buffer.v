`timescale 1ns/1ps
// Same-clock two-block PCM mailbox. Never overwrite a published bank.
module model_camera_audio_buffer #(
    parameter integer BLOCK_SAMPLES=480
)(
    input wire clk,rst_n,sample_valid,
    input wire signed [15:0] sample_data,
    input wire [63:0] sample_time,
    input wire block_release,
    input wire [9:0] read_addr,
    output reg signed [15:0] read_data,
    output wire block_ready,
    output wire [63:0] block_time,block_start_sample,
    output wire [31:0] block_sequence,
    output reg [31:0] dropped_blocks
);
    (* ram_style="block" *) reg [15:0] memory[0:2*BLOCK_SAMPLES-1];
    reg [1:0] write_ptr,read_ptr;
    reg [9:0] index;
    reg discard_block;
    reg [63:0] sample_index,time_meta[0:1],sample_meta[0:1];
    reg [31:0] sequence_index,sequence_meta[0:1];
    wire full=(write_ptr[1]!=read_ptr[1]) && (write_ptr[0]==read_ptr[0]);
    assign block_ready=write_ptr!=read_ptr;
    assign block_time=time_meta[read_ptr[0]];
    assign block_start_sample=sample_meta[read_ptr[0]];
    assign block_sequence=sequence_meta[read_ptr[0]];
    always @(posedge clk) begin
        if(read_addr<BLOCK_SAMPLES)read_data<=memory[(read_ptr[0] ? BLOCK_SAMPLES : 0)+read_addr];
        else read_data<=0;
        if(rst_n && sample_valid && ((index==0 && !full) || (index!=0 && !discard_block)))
            memory[(write_ptr[0] ? BLOCK_SAMPLES : 0)+index]<=sample_data;
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            write_ptr<=0;read_ptr<=0;index<=0;discard_block<=0;
            sample_index<=0;sequence_index<=0;dropped_blocks<=0;
            time_meta[0]<=0;time_meta[1]<=0;sample_meta[0]<=0;sample_meta[1]<=0;
            sequence_meta[0]<=0;sequence_meta[1]<=0;
        end else begin
            if(block_release && block_ready)read_ptr<=read_ptr+1'b1;
            if(sample_valid) begin
                sample_index<=sample_index+1'b1;
                if(index==0) begin
                    discard_block<=full;
                    if(!full) begin
                        time_meta[write_ptr[0]]<=sample_time;sample_meta[write_ptr[0]]<=sample_index;
                        sequence_meta[write_ptr[0]]<=sequence_index;
                    end
                end
                if(index==BLOCK_SAMPLES-1) begin
                    index<=0;sequence_index<=sequence_index+1'b1;
                    if((index==0 && full) || (index!=0 && discard_block))dropped_blocks<=dropped_blocks+1'b1;
                    else write_ptr<=write_ptr+1'b1;
                end else index<=index+1'b1;
            end
        end
    end
endmodule
