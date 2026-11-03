`timescale 1ns / 1ps

module energy_vad #(
    parameter integer FRAME_LEN       = 1920,
    parameter integer ADDR_WIDTH      = 11,
    parameter integer VAD_INIT_FRAMES = 64,
    parameter integer START_CONFIRM_FRAMES = 2
)(
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         frame_valid,

    input  wire signed [15:0]           x1_rd,
    input  wire signed [15:0]           x2_rd,
    input  wire signed [15:0]           x3_rd,
    input  wire signed [15:0]           x4_rd,

    output reg  [ADDR_WIDTH-1:0]        rd_addr,

    output reg  [47:0]                  frame_energy,
    output reg                          energy_valid,
    output reg                          voice_active,
    output reg  [47:0]                  noise_floor,

    output reg signed [31:0]            sum1_out,
    output reg signed [31:0]            sum2_out,
    output reg signed [31:0]            sum3_out,
    output reg signed [31:0]            sum4_out,

    output reg signed [15:0]            mean1,
    output reg signed [15:0]            mean2,
    output reg signed [15:0]            mean3,
    output reg signed [15:0]            mean4,
    output reg                          mean_valid
);

    localparam [2:0] S_IDLE     = 3'd0;
    localparam [2:0] S_RD_WAIT  = 3'd1;
    localparam [2:0] S_SCAN_SQ  = 3'd2;
    localparam [2:0] S_SCAN_SUM = 3'd3;
    localparam [2:0] S_SCAN_ACC = 3'd4;
    localparam [2:0] S_MEAN_MUL = 3'd5;
    localparam [2:0] S_MEAN_OUT = 3'd6;

    localparam [ADDR_WIDTH-1:0] LAST_ADDR = FRAME_LEN - 1;

    // VAD_INIT_FRAMES 必须是 2 的整数次幂
    localparam integer INIT_SHIFT = $clog2(VAD_INIT_FRAMES);

    // 1/FRAME_LEN 的定点近似
    localparam integer MEAN_SHIFT = 22;

    localparam signed [43:0] MEAN_MUL =
        (((1 << MEAN_SHIFT) + (FRAME_LEN / 2)) / FRAME_LEN);

    localparam signed [43:0] MEAN_ROUND =
        44'sd2097152;

    reg [2:0] state;

    reg [47:0] energy_acc;
    reg [47:0] energy_latched;

    reg [31:0] sq1_r;
    reg [31:0] sq2_r;
    reg [31:0] sq3_r;
    reg [31:0] sq4_r;
    
    reg [7:0] start_count;

    reg [33:0] sample_energy_r;

    wire [47:0] energy_acc_next =
        energy_acc + {14'd0, sample_energy_r};

    reg signed [31:0] sum1_acc;
    reg signed [31:0] sum2_acc;
    reg signed [31:0] sum3_acc;
    reg signed [31:0] sum4_acc;

    reg signed [31:0] sum1_latched;
    reg signed [31:0] sum2_latched;
    reg signed [31:0] sum3_latched;
    reg signed [31:0] sum4_latched;

    reg signed [43:0] mean1_prod;
    reg signed [43:0] mean2_prod;
    reg signed [43:0] mean3_prod;
    reg signed [43:0] mean4_prod;

    // 32 帧能量累加，用于计算平均噪声底
    reg [7:0]  init_count;
    reg [55:0] init_sum;
    reg        init_done;

    wire [55:0] init_sum_next =
        init_sum + {8'd0, energy_latched};

    // 16 bit 有符号样本扩展到 32 bit
    wire signed [31:0] x1_ext = {{16{x1_rd[15]}}, x1_rd};
    wire signed [31:0] x2_ext = {{16{x2_rd[15]}}, x2_rd};
    wire signed [31:0] x3_ext = {{16{x3_rd[15]}}, x3_rd};
    wire signed [31:0] x4_ext = {{16{x4_rd[15]}}, x4_rd};

    wire signed [31:0] sq1 = x1_ext * x1_ext;
    wire signed [31:0] sq2 = x2_ext * x2_ext;
    wire signed [31:0] sq3 = x3_ext * x3_ext;
    wire signed [31:0] sq4 = x4_ext * x4_ext;

    wire [33:0] square_sum =
        {2'b00, sq1_r} +
        {2'b00, sq2_r} +
        {2'b00, sq3_r} +
        {2'b00, sq4_r};

    wire signed [31:0] sum1_total = sum1_acc + x1_ext;
    wire signed [31:0] sum2_total = sum2_acc + x2_ext;
    wire signed [31:0] sum3_total = sum3_acc + x3_ext;
    wire signed [31:0] sum4_total = sum4_acc + x4_ext;

    wire signed [43:0] sum1_latched_ext =
        {{12{sum1_latched[31]}}, sum1_latched};

    wire signed [43:0] sum2_latched_ext =
        {{12{sum2_latched[31]}}, sum2_latched};

    wire signed [43:0] sum3_latched_ext =
        {{12{sum3_latched[31]}}, sum3_latched};

    wire signed [43:0] sum4_latched_ext =
        {{12{sum4_latched[31]}}, sum4_latched};

    wire signed [48:0] noise_floor_ext =
        {1'b0, noise_floor};

    wire signed [48:0] energy_latched_ext =
        {1'b0, energy_latched};

    wire signed [48:0] noise_error =
        energy_latched_ext - noise_floor_ext;

    // 启动阈值约为 noise × 1.5
    wire signed [48:0] start_threshold =
         noise_floor_ext <<< 1;

    // 停止阈值约为 noise × 1.25
    wire signed [48:0] stop_threshold =
         noise_floor_ext + (noise_floor_ext >>> 1);
    // 噪声底更新约为 1/16
    wire signed [48:0] next_noise_floor_signed =
        noise_floor_ext + (noise_error >>> 4);

    wire [47:0] next_noise_floor =
        next_noise_floor_signed[47:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= S_IDLE;
            rd_addr         <= {ADDR_WIDTH{1'b0}};

            energy_acc      <= 48'd0;
            energy_latched  <= 48'd0;

            sq1_r           <= 32'd0;
            sq2_r           <= 32'd0;
            sq3_r           <= 32'd0;
            sq4_r           <= 32'd0;

            sample_energy_r <= 34'd0;

            frame_energy    <= 48'd0;
            energy_valid    <= 1'b0;

            voice_active    <= 1'b0;
            noise_floor     <= 48'd0;

            sum1_acc        <= 32'sd0;
            sum2_acc        <= 32'sd0;
            sum3_acc        <= 32'sd0;
            sum4_acc        <= 32'sd0;

            sum1_latched    <= 32'sd0;
            sum2_latched    <= 32'sd0;
            sum3_latched    <= 32'sd0;
            sum4_latched    <= 32'sd0;

            sum1_out        <= 32'sd0;
            sum2_out        <= 32'sd0;
            sum3_out        <= 32'sd0;
            sum4_out        <= 32'sd0;

            mean1_prod      <= 44'sd0;
            mean2_prod      <= 44'sd0;
            mean3_prod      <= 44'sd0;
            mean4_prod      <= 44'sd0;

            mean1           <= 16'sd0;
            mean2           <= 16'sd0;
            mean3           <= 16'sd0;
            mean4           <= 16'sd0;
            mean_valid      <= 1'b0;

            init_count      <= 8'd0;
            init_sum        <= 56'd0;
            init_done       <= 1'b0;
        end else begin
            energy_valid <= 1'b0;
            mean_valid   <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (frame_valid) begin
                        energy_acc      <= 48'd0;
                        sample_energy_r <= 34'd0;

                        sq1_r <= 32'd0;
                        sq2_r <= 32'd0;
                        sq3_r <= 32'd0;
                        sq4_r <= 32'd0;

                        sum1_acc <= 32'sd0;
                        sum2_acc <= 32'sd0;
                        sum3_acc <= 32'sd0;
                        sum4_acc <= 32'sd0;

                        rd_addr <= {ADDR_WIDTH{1'b0}};
                        state   <= S_RD_WAIT;
                    end
                end

                S_RD_WAIT: begin
                    state <= S_SCAN_SQ;
                end

                S_SCAN_SQ: begin
                    sq1_r <= sq1;
                    sq2_r <= sq2;
                    sq3_r <= sq3;
                    sq4_r <= sq4;
                    state <= S_SCAN_SUM;
                end

                S_SCAN_SUM: begin
                    sample_energy_r <= square_sum;
                    state           <= S_SCAN_ACC;
                end

                S_SCAN_ACC: begin
                    energy_acc <= energy_acc_next;

                    sum1_acc <= sum1_total;
                    sum2_acc <= sum2_total;
                    sum3_acc <= sum3_total;
                    sum4_acc <= sum4_total;

                    if (rd_addr == LAST_ADDR) begin
                        sum1_out <= sum1_total;
                        sum2_out <= sum2_total;
                        sum3_out <= sum3_total;
                        sum4_out <= sum4_total;

                        energy_latched <= energy_acc_next;

                        sum1_latched <= sum1_total;
                        sum2_latched <= sum2_total;
                        sum3_latched <= sum3_total;
                        sum4_latched <= sum4_total;

                        state <= S_MEAN_MUL;
                    end else begin
                        rd_addr <= rd_addr + 1'b1;
                        state   <= S_RD_WAIT;
                    end
                end

                S_MEAN_MUL: begin
                    mean1_prod <= sum1_latched_ext * MEAN_MUL;
                    mean2_prod <= sum2_latched_ext * MEAN_MUL;
                    mean3_prod <= sum3_latched_ext * MEAN_MUL;
                    mean4_prod <= sum4_latched_ext * MEAN_MUL;

                    state <= S_MEAN_OUT;
                end

                S_MEAN_OUT: begin
                    mean1 <=
                        (mean1_prod + MEAN_ROUND) >>> MEAN_SHIFT;

                    mean2 <=
                        (mean2_prod + MEAN_ROUND) >>> MEAN_SHIFT;

                    mean3 <=
                        (mean3_prod + MEAN_ROUND) >>> MEAN_SHIFT;

                    mean4 <=
                        (mean4_prod + MEAN_ROUND) >>> MEAN_SHIFT;

                    frame_energy <= energy_latched;
                    energy_valid <= 1'b1;
                    mean_valid   <= 1'b1;

                    if (!init_done) begin
                        // 前 32 帧能量累加
                        init_sum <= init_sum_next;

                        if (init_count == VAD_INIT_FRAMES-1) begin
                            // 32 帧平均值，INIT_SHIFT=5
                            noise_floor <=
                                init_sum_next >>> INIT_SHIFT;

                            init_done    <= 1'b1;
                            voice_active <= 1'b0;
                        end else begin
                            init_count <= init_count + 1'b1;
                        end
                    end else if (!voice_active) begin
                            /*
                             * 需要连续 START_CONFIRM_FRAMES 帧
                             * 超过启动阈值才进入语音状态。
                             */
                            if (energy_latched_ext > start_threshold) begin
                                if (start_count >= START_CONFIRM_FRAMES-1) begin
                                    voice_active <= 1'b1;
                                    start_count  <= 8'd0;
                                end else begin
                                    start_count <= start_count + 1'b1;
                                end
                            end else begin
                                start_count <= 8'd0;
                                noise_floor <= next_noise_floor;
                            end
                        end else begin
                            // 低于停止阈值，退出语音状态
                            if (energy_latched_ext < stop_threshold) begin
                                voice_active <= 1'b0;
                                start_count  <= 8'd0;
                                noise_floor  <= next_noise_floor;
                            end
                        end 
                        
                    state <= S_IDLE;
                end

                default: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule