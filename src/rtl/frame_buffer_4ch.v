`timescale 1ns / 1ps

module frame_buffer_4ch #(
    parameter integer FRAME_LEN  = 1920,
    parameter integer HOP_LEN    = 480,
    parameter integer DATA_WIDTH = 16,
    parameter integer ADDR_WIDTH = 11
)(
    input  wire                         clk,
    input  wire                         rst_n,

    input  wire                         sample_valid,
    input  wire signed [DATA_WIDTH-1:0] x1,
    input  wire signed [DATA_WIDTH-1:0] x2,
    input  wire signed [DATA_WIDTH-1:0] x3,
    input  wire signed [DATA_WIDTH-1:0] x4,

    input  wire [ADDR_WIDTH-1:0]        rd_addr,
    output wire signed [DATA_WIDTH-1:0] x1_rd,
    output wire signed [DATA_WIDTH-1:0] x2_rd,
    output wire signed [DATA_WIDTH-1:0] x3_rd,
    output wire signed [DATA_WIDTH-1:0] x4_rd,

    output reg                          frame_valid,
    output reg                          frame_sel
);

    localparam integer RING_DEPTH = FRAME_LEN + HOP_LEN;
    localparam integer MEM_AW     = $clog2(RING_DEPTH);

    (* ram_style = "block" *)
    reg [4*DATA_WIDTH-1:0] mem [0:RING_DEPTH-1];

    reg [MEM_AW-1:0]     wr_ptr;
    reg [MEM_AW-1:0]     frame_start;
    reg [ADDR_WIDTH-1:0] fill_count;
    reg [ADDR_WIDTH-1:0] hop_count;

    reg filled;

    wire [4*DATA_WIDTH-1:0] sample_pack;
    wire [4*DATA_WIDTH-1:0] rd_word_r;

    wire [MEM_AW:0] rd_sum;
    wire [MEM_AW-1:0] rd_full_addr;

    wire [MEM_AW:0] next_frame_sum;
    wire [MEM_AW-1:0] next_frame_start;

    assign sample_pack = {x1, x2, x3, x4};

    assign rd_sum = frame_start + rd_addr;

    assign rd_full_addr =
        (rd_sum >= RING_DEPTH) ?
        rd_sum - RING_DEPTH :
        rd_sum[MEM_AW-1:0];

    assign next_frame_sum = frame_start + HOP_LEN;

    assign next_frame_start =
        (next_frame_sum >= RING_DEPTH) ?
        next_frame_sum - RING_DEPTH :
        next_frame_sum[MEM_AW-1:0];

    // 同步读端口
    reg [4*DATA_WIDTH-1:0] rd_data_reg;

    always @(posedge clk) begin
        rd_data_reg <= mem[rd_full_addr];
    end

    assign rd_word_r = rd_data_reg;

    assign x1_rd = rd_word_r[4*DATA_WIDTH-1 -: DATA_WIDTH];
    assign x2_rd = rd_word_r[3*DATA_WIDTH-1 -: DATA_WIDTH];
    assign x3_rd = rd_word_r[2*DATA_WIDTH-1 -: DATA_WIDTH];
    assign x4_rd = rd_word_r[1*DATA_WIDTH-1 -: DATA_WIDTH];

    // 写端口
    always @(posedge clk) begin
        if (sample_valid)
            mem[wr_ptr] <= sample_pack;
    end

    // 写地址、帧起点和 frame_valid
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr      <= {MEM_AW{1'b0}};
            frame_start <= {MEM_AW{1'b0}};

            fill_count  <= {ADDR_WIDTH{1'b0}};
            hop_count   <= {ADDR_WIDTH{1'b0}};

            filled      <= 1'b0;
            frame_valid <= 1'b0;
            frame_sel   <= 1'b0;
        end else begin
            frame_valid <= 1'b0;

            if (sample_valid) begin
                if (wr_ptr == RING_DEPTH-1)
                    wr_ptr <= {MEM_AW{1'b0}};
                else
                    wr_ptr <= wr_ptr + 1'b1;

                if (!filled) begin
                    if (fill_count == FRAME_LEN-1) begin
                        filled      <= 1'b1;
                        frame_start <= {MEM_AW{1'b0}};
                        hop_count   <= {ADDR_WIDTH{1'b0}};
                        frame_valid <= 1'b1;
                        frame_sel   <= 1'b0;
                    end else begin
                        fill_count <= fill_count + 1'b1;
                    end
                end else begin
                    if (hop_count == HOP_LEN-1) begin
                        hop_count   <= {ADDR_WIDTH{1'b0}};
                        frame_start <= next_frame_start;
                        frame_valid <= 1'b1;
                        frame_sel   <= ~frame_sel;
                    end else begin
                        hop_count <= hop_count + 1'b1;
                    end
                end
            end
        end
    end

endmodule