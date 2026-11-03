`timescale 1ns/1ps
// 8N1 TX + 16-byte FIFO. A fractional accumulator gives the requested average baud.
module model_uart #(
    parameter integer CLK_FREQ_HZ=100_000_000,
    parameter integer BAUD_RATE=921600
)(input wire clk,rst_n,input wire [7:0] data,input wire valid,
  output wire ready,busy,output wire uart_txd);
    reg [7:0] fifo[0:15];
    reg [3:0] wr,rd;
    reg [4:0] count;
    reg active;
    reg [9:0] shift;
    reg [3:0] bit_index;
    reg [31:0] phase;
    wire push=valid && ready;
    wire pop=!active && count!=0;
    assign ready=count<16;
    assign busy=active || count!=0;
    assign uart_txd=active ? shift[bit_index] : 1'b1;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin wr<=0;rd<=0;count<=0;active<=0;shift<=10'h3FF;bit_index<=0;phase<=0;end
        else begin
            if(push) begin fifo[wr]<=data;wr<=wr+1'b1;end
            if(pop) begin
                shift<={1'b1,fifo[rd],1'b0};rd<=rd+1'b1;
                active<=1;bit_index<=0;phase<=0;
            end else if(active) begin
                if(phase>=CLK_FREQ_HZ-BAUD_RATE) begin
                    phase<=phase+BAUD_RATE-CLK_FREQ_HZ;
                    if(bit_index==9) active<=0;
                    else bit_index<=bit_index+1'b1;
                end else phase<=phase+BAUD_RATE;
            end
            case({push,pop}) 2'b10:count<=count+1'b1;2'b01:count<=count-1'b1;default:count<=count;endcase
        end
    end
endmodule
