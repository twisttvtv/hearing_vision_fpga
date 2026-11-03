`timescale 1ns/1ps
// 摄像头 + AXI + 调试串口 IP；BD 中连接 PS M_AXI_GP0，读缓存不再引出外部引脚。
module model_camera_top #(
    parameter integer CLK_FREQ_HZ=100_000_000,
    parameter integer BAUD_RATE=921600,
    parameter integer VIDEO_WIDTH=320,
    parameter integer VIDEO_HEIGHT=180,
    parameter integer VSYNC_ACTIVE_LOW=1,
    parameter integer ENABLE_PREVIEW=0, MIC_CLK_DIV=32,
    parameter integer MIC_FRAME_LEN=1920,MIC_HOP_LEN=480,MIC_MAX_DELAY=6,MIC_ADDR_WIDTH=11,
    parameter integer VAD_INIT_HOPS=50,VAD_ATTACK_HOPS=5,VAD_RELEASE_HOPS=35,VAD_ABS_MEAN_POWER=16,
    parameter integer VAD_NOISE_MULT_SHIFT=1,VAD_STOP_MULT_SHIFT=0,CORR_CONF_SHIFT=4,
    parameter integer AUDIO_BLOCK_SAMPLES=480,SERVO_SIMULATION=0,
    parameter integer VAD_ABS_FRAME_ENERGY=6000
)(
    (* X_INTERFACE_INFO="xilinx.com:signal:clock:1.0 S_AXI_ACLK CLK",
       X_INTERFACE_PARAMETER="XIL_INTERFACENAME S_AXI_ACLK, ASSOCIATED_BUSIF S_AXI, ASSOCIATED_RESET rst_n" *)
    input wire clk,
    (* X_INTERFACE_INFO="xilinx.com:signal:reset:1.0 S_AXI_ARESETN RST",
       X_INTERFACE_PARAMETER="XIL_INTERFACENAME S_AXI_ARESETN, POLARITY ACTIVE_LOW" *)
    input wire rst_n,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI AWADDR",
       X_INTERFACE_PARAMETER="XIL_INTERFACENAME S_AXI, PROTOCOL AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 32" *)
    input wire [31:0] s_axi_awaddr,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI AWPROT" *) input wire [2:0] s_axi_awprot,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI AWVALID" *) input wire s_axi_awvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI AWREADY" *) output wire s_axi_awready,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI WDATA" *) input wire [31:0] s_axi_wdata,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI WSTRB" *) input wire [3:0] s_axi_wstrb,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI WVALID" *) input wire s_axi_wvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI WREADY" *) output wire s_axi_wready,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI BRESP" *) output wire [1:0] s_axi_bresp,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI BVALID" *) output wire s_axi_bvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI BREADY" *) input wire s_axi_bready,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI ARADDR" *) input wire [31:0] s_axi_araddr,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI ARPROT" *) input wire [2:0] s_axi_arprot,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI ARVALID" *) input wire s_axi_arvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI ARREADY" *) output wire s_axi_arready,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI RDATA" *) output wire [31:0] s_axi_rdata,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI RRESP" *) output wire [1:0] s_axi_rresp,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI RVALID" *) output wire s_axi_rvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI RREADY" *) input wire s_axi_rready,
    inout wire cam_scl,cam_sda,
    output wire cam_reset,cam_pwdn,
    input wire cam_pclk,cam_vsync,cam_href,
    input wire [7:0] cam_data,
    output wire uart_txd,
    output wire mic_sck,mic_ws,
    input wire mic_sd_lr,mic_sd_ud,
    output wire servo0,servo1,vib,
    output wire [7:0] led
);
    wire hold_view,vision_alert,audio_release,audio_ready;
    wire [9:0] audio_read_addr;
    wire [15:0] audio_read_data,mic_angle;
    wire [63:0] audio_time,audio_start_sample;
    wire [31:0] audio_sequence,audio_drops,motion_epoch;
    wire mic_active,direction_valid,servo_moving,servo_settled,direction_matches;
    wire [2:0] stable_direction,target_direction;
    wire [47:0] vad_energy,vad_noise;
    wire video_release,video_frame_ready,camera_init_done;
    wire [15:0] video_read_addr,video_read_data;
    wire [63:0] video_frame_time,system_time;
    wire [31:0] video_frame_sequence,video_dropped_frames,video_bad_frames;
    wire uart_ready,uart_busy,uart_valid;
    wire [7:0] uart_data;
    wire [63:0] camera_time;
    wire sccb_start,sccb_busy,sccb_done,cam_reset_ctrl;
    wire [15:0] reg_addr;
    wire [7:0] reg_data;
    assign cam_reset=cam_reset_ctrl ? 1'bz : 1'b0;
    model_sync u_sync(.clk(clk),.camera_clk(cam_pclk),.rst_n(rst_n),
                            .system_ticks(system_time),.camera_ticks(camera_time));
    model_initial #(.CLK_FREQ_HZ(CLK_FREQ_HZ)) u_initial (
        .clk(clk),.rst_n(rst_n),.sccb_busy(sccb_busy),.sccb_done(sccb_done),
        .sccb_start(sccb_start),.reg_addr(reg_addr),.reg_data(reg_data),
        .cam_reset(cam_reset_ctrl),.cam_pwdn(cam_pwdn),.init_done(camera_init_done)
    );
    model_sccb_write u_sccb (
        .clk(clk),.rst_n(rst_n),.start(sccb_start),.reg_addr(reg_addr),.reg_data(reg_data),
        .busy(sccb_busy),.done(sccb_done),.cam_scl(cam_scl),.cam_sda(cam_sda)
    );
    (* ASYNC_REG="TRUE" *) reg [1:0] init_sync,cam_reset_sync;
    wire camera_reset_n=cam_reset_sync[1];
    always @(posedge cam_pclk or negedge rst_n) begin
        if(!rst_n) cam_reset_sync<=0;
        else cam_reset_sync<={cam_reset_sync[0],1'b1};
    end
    always @(posedge cam_pclk or negedge camera_reset_n) begin
        if(!camera_reset_n) init_sync<=0;
        else init_sync<={init_sync[0],camera_init_done};
    end
    // 使用寄存器驱动采集复位，避免组合 LUT 同时驱动大量异步 CLR。
    reg capture_reset;
    always @(posedge cam_pclk or negedge camera_reset_n) begin
        if(!camera_reset_n) capture_reset<=0;
        else capture_reset<=init_sync[1];
    end
    wire frame_sync=VSYNC_ACTIVE_LOW ? ~cam_vsync : cam_vsync;
    reg sync_d1,sync_d2;
    always @(posedge cam_pclk or negedge camera_reset_n) begin
        if(!camera_reset_n) begin sync_d1<=1;sync_d2<=1;end
        else begin sync_d1<=frame_sync;sync_d2<=sync_d1;end
    end
    wire [15:0] pixel_data,video_data;
    wire pixel_valid,video_valid;
    wire [11:0] pixel_x,pixel_y;
    wire [8:0] video_x;
    wire [7:0] video_y;
    reg [63:0] capture_start_time;
    always @(posedge cam_pclk or negedge camera_reset_n) begin
        if(!camera_reset_n) capture_start_time<=0;
        else if(pixel_valid && pixel_x==0 && pixel_y==0) capture_start_time<=camera_time;
    end
    model_capture #(.LOW_BYTE_FIRST(1)) u_capture (
        .rst_n(capture_reset),.cam_pclk(cam_pclk),.cam_vsync(frame_sync),.cam_href(cam_href),
        .cam_data(cam_data),.pixel_data(pixel_data),.pixel_valid(pixel_valid),.pixel_x(pixel_x),.pixel_y(pixel_y)
    );
    model_video_input u_video_input (
        .camera_clk(cam_pclk),.rst_n(capture_reset),.pixel_data(pixel_data),.pixel_valid(pixel_valid),
        .pixel_x(pixel_x),.pixel_y(pixel_y),.video_data(video_data),.video_valid(video_valid),
        .video_x(video_x),.video_y(video_y)
    );
    model_frame_buffer #(.WIDTH(VIDEO_WIDTH),.HEIGHT(VIDEO_HEIGHT)) u_video_buffer (
        .rst_n(rst_n),.write_clk(cam_pclk),.read_clk(clk),.frame_sync(sync_d2),
        .pixel_data(video_data),.pixel_valid(video_valid),.pixel_x(video_x),.pixel_y(video_y),
        .capture_time(capture_start_time),.frame_release(video_release),.read_addr(video_read_addr),
        .read_data(video_read_data),.frame_ready(video_frame_ready),.frame_time(video_frame_time),
        .frame_sequence(video_frame_sequence),.dropped_frames(video_dropped_frames),.bad_frames(video_bad_frames)
    );
    model_camera_axi #(.CLK_FREQ_HZ(CLK_FREQ_HZ),.VIDEO_WIDTH(VIDEO_WIDTH),.VIDEO_HEIGHT(VIDEO_HEIGHT),.AUDIO_BLOCK_SAMPLES(AUDIO_BLOCK_SAMPLES),
        .MIC_SAMPLE_TICKS(MIC_CLK_DIV*64),.ENABLE_PREVIEW(ENABLE_PREVIEW)) u_axi (
        .s_axi_aclk(clk),
        .s_axi_aresetn(rst_n),
        .s_axi_awaddr(s_axi_awaddr),
        .s_axi_awprot(s_axi_awprot),
        .s_axi_awvalid(s_axi_awvalid),
        .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata),
        .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp),
        .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr),
        .s_axi_arprot(s_axi_arprot),
        .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata),
        .s_axi_rresp(s_axi_rresp),
        .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready),
        .video_frame_ready(video_frame_ready),
        .camera_init_done(camera_init_done),
        .video_frame_time(video_frame_time),
        .system_time(system_time),
        .video_frame_sequence(video_frame_sequence),
        .video_dropped_frames(video_dropped_frames),
        .video_bad_frames(video_bad_frames),
        .video_release(video_release),
        .video_read_addr(video_read_addr),
        .video_read_data(video_read_data),
        .uart_ready(uart_ready),
        .uart_busy(uart_busy),
        .uart_valid(uart_valid),
        .uart_data(uart_data),
        .audio_ready(audio_ready),.audio_time(audio_time),.audio_start_sample(audio_start_sample),
        .audio_sequence(audio_sequence),.audio_drops(audio_drops),.audio_release(audio_release),
        .audio_read_addr(audio_read_addr),.audio_read_data(audio_read_data),
        .mic_active(mic_active),.direction_valid(direction_valid),.servo_moving(servo_moving),
        .servo_settled(servo_settled),.direction_matches(direction_matches),
        .stable_direction(stable_direction),.target_direction(target_direction),.mic_angle(mic_angle),
        .motion_epoch(motion_epoch),.vad_energy(vad_energy),.vad_noise(vad_noise),
        .hold_view(hold_view),.vision_alert(vision_alert)
    );
    generate if(ENABLE_PREVIEW) begin: preview
    model_uart #(.CLK_FREQ_HZ(CLK_FREQ_HZ),.BAUD_RATE(BAUD_RATE)) u_uart (
        .clk(clk),.rst_n(rst_n),.data(uart_data),.valid(uart_valid),
        .ready(uart_ready),.busy(uart_busy),.uart_txd(uart_txd)
    );
    end else begin: no_preview
        assign uart_ready=1'b0;assign uart_busy=1'b0;assign uart_txd=1'b1;
    end endgenerate
    model_camera_io #(.CLK_FREQ_HZ(CLK_FREQ_HZ),.MIC_CLK_DIV(MIC_CLK_DIV),
        .FRAME_LEN(MIC_FRAME_LEN),.HOP_LEN(MIC_HOP_LEN),.MAX_DELAY(MIC_MAX_DELAY),.ADDR_WIDTH(MIC_ADDR_WIDTH),
        .VAD_INIT_HOPS(VAD_INIT_HOPS),.VAD_ATTACK_HOPS(VAD_ATTACK_HOPS),.VAD_RELEASE_HOPS(VAD_RELEASE_HOPS),
        .VAD_ABS_MEAN_POWER(VAD_ABS_MEAN_POWER),.AUDIO_BLOCK_SAMPLES(AUDIO_BLOCK_SAMPLES),
        .VAD_ABS_FRAME_ENERGY(VAD_ABS_FRAME_ENERGY),
        .VAD_NOISE_MULT_SHIFT(VAD_NOISE_MULT_SHIFT),.VAD_STOP_MULT_SHIFT(VAD_STOP_MULT_SHIFT),.CORR_CONF_SHIFT(CORR_CONF_SHIFT),
        .SIMULATION(SERVO_SIMULATION)) u_io (
        .clk(clk),.rst_n(rst_n),.system_time(system_time),.mic_sck(mic_sck),.mic_ws(mic_ws),
        .mic_sd_lr(mic_sd_lr),.mic_sd_ud(mic_sd_ud),.servo0(servo0),.servo1(servo1),.vib(vib),.led(led),
        .hold_view(hold_view),.vision_alert(vision_alert),.audio_release(audio_release),
        .audio_read_addr(audio_read_addr),.audio_read_data(audio_read_data),.audio_ready(audio_ready),
        .audio_time(audio_time),.audio_start_sample(audio_start_sample),.audio_sequence(audio_sequence),.audio_drops(audio_drops),
        .mic_active(mic_active),.direction_valid(direction_valid),.servo_moving(servo_moving),.servo_settled(servo_settled),
        .direction_matches(direction_matches),.stable_direction(stable_direction),.target_direction(target_direction),
        .mic_angle(mic_angle),.motion_epoch(motion_epoch),.vad_energy(vad_energy),.vad_noise(vad_noise)
    );
endmodule
