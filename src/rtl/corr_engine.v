`timescale 1ns / 1ps

module corr_engine #(
    parameter integer FRAME_LEN  = 1920,
    parameter integer MAX_DELAY  = 6,
    parameter integer ADDR_WIDTH = 11
)(
    input  wire                         clk,
    input  wire                         rst_n,

    input  wire                         start,
    input  wire                         pair_sel,
    // 0: dx = corr(x3, x1)
    // 1: dy = corr(x2, x4)

    input  wire signed [15:0]           mean1,
    input  wire signed [15:0]           mean2,
    input  wire signed [15:0]           mean3,
    input  wire signed [15:0]           mean4,

    input  wire signed [15:0]           x1_rd,
    input  wire signed [15:0]           x2_rd,
    input  wire signed [15:0]           x3_rd,
    input  wire signed [15:0]           x4_rd,

    output reg  [ADDR_WIDTH-1:0]        rd_addr,
    output reg  signed [15:0]           tdoa_int,
    output reg  signed [15:0]           tdoa_frac_q8_8,
    output reg  signed [47:0]           max_corr,
    output reg                          done,
    output reg                          busy
);

    localparam integer NUM_LAGS = 2 * MAX_DELAY + 1;
    localparam integer CALC_LEN = FRAME_LEN - 2 * MAX_DELAY;

    localparam [ADDR_WIDTH-1:0] MAX_DELAY_V = MAX_DELAY;
    localparam signed [15:0]    MAX_DELAY_S = MAX_DELAY;

    localparam [3:0] S_IDLE     = 4'd0;
    localparam [3:0] S_REF_WAIT = 4'd1;
    localparam [3:0] S_REF_CAP  = 4'd2;
    localparam [3:0] S_DEL_WAIT = 4'd3;
    localparam [3:0] S_DEL_CAP  = 4'd4;
    localparam [3:0] S_MAC_MUL  = 4'd5;
    localparam [3:0] S_MAC_ACC  = 4'd6;
    localparam [3:0] S_LAG_DONE = 4'd7;
    localparam [3:0] S_FINISH   = 4'd8;
    localparam [3:0] S_DONE     = 4'd9;

    reg [3:0] state;

    reg start_d;
    wire start_pulse = start & ~start_d;

    reg pair_sel_r;
    reg signed [15:0] mean_ref_r;
    reg signed [15:0] mean_del_r;

    reg [4:0] lag_sel;
    reg [ADDR_WIDTH-1:0] cnt;

    reg signed [15:0] ref_sample;
    reg signed [15:0] del_sample;

    reg signed [47:0] acc;
    reg signed [47:0] product_r;
    reg signed [47:0] max_val;

    reg [4:0] max_idx;
    reg       max_valid;

    // 根据 pair_sel_r 选择参考信号和延迟信号
    wire signed [15:0] ref_sel =
        pair_sel_r ? x2_rd : x3_rd;

    wire signed [15:0] del_sel =
        pair_sel_r ? x4_rd : x1_rd;

    // 有符号数据扩展到 18 bit，防止减法溢出
    wire signed [17:0] ref_ext =
        {{2{ref_sample[15]}}, ref_sample};

    wire signed [17:0] del_ext =
        {{2{del_sample[15]}}, del_sample};

    wire signed [17:0] mean_ref_ext =
        {{2{mean_ref_r[15]}}, mean_ref_r};

    wire signed [17:0] mean_del_ext =
        {{2{mean_del_r[15]}}, mean_del_r};

    wire signed [17:0] ref_center =
        ref_ext - mean_ref_ext;

    wire signed [17:0] del_center =
        del_ext - mean_del_ext;

    // 18 bit x 18 bit
    wire signed [35:0] product_next =
        ref_center * del_center;

    wire signed [47:0] product_ext =
        {{12{product_next[35]}}, product_next};

    wire signed [47:0] acc_next =
        acc + product_r;

    wire signed [15:0] max_lag_calc =
        $signed({11'b0, max_idx}) - MAX_DELAY_S;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state             <= S_IDLE;

            start_d           <= 1'b0;
            pair_sel_r        <= 1'b0;
            mean_ref_r        <= 16'sd0;
            mean_del_r        <= 16'sd0;

            lag_sel           <= 5'd0;
            cnt               <= {ADDR_WIDTH{1'b0}};

            ref_sample        <= 16'sd0;
            del_sample        <= 16'sd0;

            acc               <= 48'sd0;
            product_r         <= 48'sd0;
            max_val           <= 48'sd0;

            max_idx           <= 5'd0;
            max_valid         <= 1'b0;

            rd_addr           <= {ADDR_WIDTH{1'b0}};
            tdoa_int          <= 16'sd0;
            tdoa_frac_q8_8    <= 16'sd0;
            max_corr          <= 48'sd0;

            done              <= 1'b0;
            busy              <= 1'b0;
        end else begin
            start_d <= start;
            done    <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start_pulse) begin
                        pair_sel_r <= pair_sel;

                        if (pair_sel) begin
                            mean_ref_r <= mean2;
                            mean_del_r <= mean4;
                        end else begin
                            mean_ref_r <= mean3;
                            mean_del_r <= mean1;
                        end

                        lag_sel   <= 5'd0;
                        cnt       <= {ADDR_WIDTH{1'b0}};

                        acc       <= 48'sd0;
                        product_r <= 48'sd0;
                        max_val   <= 48'sd0;
                        max_idx   <= 5'd0;
                        max_valid <= 1'b0;

                        rd_addr   <= MAX_DELAY_V;
                        busy      <= 1'b1;
                        state     <= S_REF_WAIT;
                    end
                end

                // 等待同步 BRAM 的参考信号数据
                S_REF_WAIT: begin
                    state <= S_REF_CAP;
                end

                // 捕获参考信号，并设置延迟信号地址
                S_REF_CAP: begin
                    ref_sample <= ref_sel;
                    rd_addr    <= cnt + lag_sel;
                    state      <= S_DEL_WAIT;
                end

                // 等待同步 BRAM 的延迟信号数据
                S_DEL_WAIT: begin
                    state <= S_DEL_CAP;
                end

                // 捕获延迟信号
                S_DEL_CAP: begin
                    del_sample <= del_sel;
                    state      <= S_MAC_MUL;
                end

                // 第一拍：减去均值并完成乘法
                S_MAC_MUL: begin
                    product_r <= product_ext;
                    state     <= S_MAC_ACC;
                end

                // 第二拍：完成 48 bit 累加
                S_MAC_ACC: begin
                    acc <= acc_next;

                    if (cnt == CALC_LEN-1) begin
                        state <= S_LAG_DONE;
                    end else begin
                        cnt     <= cnt + 1'b1;
                        rd_addr <= cnt + 1'b1 + MAX_DELAY_V;
                        state   <= S_REF_WAIT;
                    end
                end

                // 当前 lag 的全部点累加完成
                S_LAG_DONE: begin
                    if (!max_valid || (acc > max_val)) begin
                        max_val   <= acc;
                        max_idx   <= lag_sel;
                    end

                    max_valid <= 1'b1;

                    if (lag_sel == NUM_LAGS-1) begin
                        state <= S_FINISH;
                    end else begin
                        lag_sel   <= lag_sel + 1'b1;
                        cnt       <= {ADDR_WIDTH{1'b0}};
                        acc       <= 48'sd0;
                        rd_addr   <= MAX_DELAY_V;
                        state     <= S_REF_WAIT;
                    end
                end

                // 输出整数 TDOA，第一版不做小数插值
                S_FINISH: begin
                    tdoa_int       <= max_lag_calc;
                    tdoa_frac_q8_8 <= 16'sd0;
                    max_corr       <= max_val;
                    state          <= S_DONE;
                end

                S_DONE: begin
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
