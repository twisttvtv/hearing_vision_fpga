`timescale 1ns/1ps
// AXI4-Lite: 摄像头完整帧读取 + UART TX FIFO；纯视觉模型由片内 ARM 执行。
// 地址编辑器需分配至少 512 KiB；以下地址使用外设基址内的低 19 位偏移。
module model_camera_axi #(
    parameter integer CLK_FREQ_HZ=100_000_000,
    parameter integer VIDEO_WIDTH=320,
    parameter integer VIDEO_HEIGHT=180,
    parameter integer AUDIO_BLOCK_SAMPLES=480,
    parameter integer MIC_SAMPLE_TICKS=2048,
    parameter integer ENABLE_PREVIEW=0,
    // Delayed-result mode: captured speech evidence remains mandatory.
    parameter [63:0] RESULT_MAX_AGE_TICKS=64'd120*CLK_FREQ_HZ,
    parameter integer REQUIRE_LIVE_SOUND=0,
    parameter integer ALLOW_UNKNOWN_DIRECTION=1
)(
    (* X_INTERFACE_INFO="xilinx.com:signal:clock:1.0 S_AXI_ACLK CLK",
       X_INTERFACE_PARAMETER="XIL_INTERFACENAME S_AXI_ACLK, ASSOCIATED_BUSIF S_AXI, ASSOCIATED_RESET s_axi_aresetn" *)
    input wire s_axi_aclk,
    (* X_INTERFACE_INFO="xilinx.com:signal:reset:1.0 S_AXI_ARESETN RST",
       X_INTERFACE_PARAMETER="XIL_INTERFACENAME S_AXI_ARESETN, POLARITY ACTIVE_LOW" *)
    input wire s_axi_aresetn,
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
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI BRESP" *) output reg [1:0] s_axi_bresp,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI BVALID" *) output reg s_axi_bvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI BREADY" *) input wire s_axi_bready,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI ARADDR" *) input wire [31:0] s_axi_araddr,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI ARPROT" *) input wire [2:0] s_axi_arprot,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI ARVALID" *) input wire s_axi_arvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI ARREADY" *) output wire s_axi_arready,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI RDATA" *) output reg [31:0] s_axi_rdata,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI RRESP" *) output reg [1:0] s_axi_rresp,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI RVALID" *) output reg s_axi_rvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI RREADY" *) input wire s_axi_rready,
    input wire video_frame_ready,camera_init_done,
    input wire [63:0] video_frame_time,system_time,
    input wire [31:0] video_frame_sequence,video_dropped_frames,video_bad_frames,
    output reg video_release,
    input wire uart_ready,uart_busy,
    output reg uart_valid,
    output reg [7:0] uart_data,
    output reg [15:0] video_read_addr,
    input wire [15:0] video_read_data,
    input wire audio_ready,
    input wire [63:0] audio_time,audio_start_sample,
    input wire [31:0] audio_sequence,audio_drops,
    output reg audio_release,
    output reg [9:0] audio_read_addr,
    input wire [15:0] audio_read_data,
    input wire mic_active,direction_valid,servo_moving,servo_settled,direction_matches,
    input wire [2:0] stable_direction,target_direction,
    input wire [15:0] mic_angle,
    input wire [31:0] motion_epoch,
    input wire [47:0] vad_energy,vad_noise,
    output reg hold_view,vision_alert
);
    localparam integer VIDEO_PIXELS=VIDEO_WIDTH*VIDEO_HEIGHT;
    localparam [18:0] VIDEO_BASE=19'h20000,AUDIO_BASE=19'h40000;
    localparam [2:0] IDLE=0,WAIT_LOW=1,LATCH_LOW=2,WAIT_HIGH=3,LATCH_HIGH=4,RESPONSE=5;
    reg [2:0] read_state;
    reg [15:0] low_half;
    reg memory_is_audio;
    reg high_half_valid;
    reg aw_held,w_held;
    reg [18:0] write_address;
    reg [31:0] write_value;
    reg [3:0] write_strobe;
    reg [31:0] result_score,result_epoch,result_sequence,result_flags,alert_count;
    reg [63:0] result_time,result_age_snapshot;
    reg have_result;
    reg [31:0] last_result_sequence,last_result_epoch;
    wire [63:0] result_age=system_time-result_time;
    wire age_ok=system_time>=result_time && result_age<=RESULT_MAX_AGE_TICKS;
    wire epoch_ok=result_epoch==motion_epoch;
    wire direction_ok=direction_matches || (ALLOW_UNKNOWN_DIRECTION && !direction_valid);
    wire view_ok=servo_settled && !servo_moving && direction_ok;
    wire sound_ok=!REQUIRE_LIVE_SOUND || mic_active;
    wire result_new=!have_result || result_sequence!=last_result_sequence || result_epoch!=last_result_epoch;
    wire result_eligible=hold_view && age_ok && epoch_ok && view_ok && sound_ok && write_value[2] && result_new;
    wire [18:0] read_address=s_axi_araddr[18:0];
    wire execute_write=aw_held && w_held && !s_axi_bvalid && read_state==IDLE;
    assign s_axi_awready=!aw_held && !s_axi_bvalid;
    assign s_axi_wready=!w_held && !s_axi_bvalid;
    // release 在下一拍被缓存消费；这一拍不能用旧指针接受新的 RAM 读取。
    assign s_axi_arready=read_state==IDLE && !execute_write && !video_release && !audio_release && !uart_valid;
    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if(!s_axi_aresetn) begin
            aw_held<=0;w_held<=0;write_address<=0;write_value<=0;write_strobe<=0;
            s_axi_bvalid<=0;s_axi_bresp<=0;video_release<=0;audio_release<=0;uart_valid<=0;uart_data<=0;
            hold_view<=0;vision_alert<=0;result_score<=0;result_epoch<=0;result_sequence<=0;
            result_time<=0;result_age_snapshot<=0;result_flags<=0;alert_count<=0;have_result<=0;
            last_result_sequence<=0;last_result_epoch<=0;
        end else begin
            video_release<=0;audio_release<=0;uart_valid<=0;vision_alert<=0;
            if(s_axi_bvalid && s_axi_bready) s_axi_bvalid<=0;
            if(s_axi_awvalid && s_axi_awready) begin aw_held<=1;write_address<=s_axi_awaddr[18:0];end
            if(s_axi_wvalid && s_axi_wready) begin w_held<=1;write_value<=s_axi_wdata;write_strobe<=s_axi_wstrb;end
            if(execute_write) begin
                aw_held<=0;w_held<=0;s_axi_bvalid<=1;s_axi_bresp<=2'b10;
                if(write_address==19'h0000C) begin
                    s_axi_bresp<=0;
                    if(write_strobe[0]) begin
                        video_release<=write_value[0] && video_frame_ready;
                        audio_release<=write_value[1] && audio_ready;
                    end
                end else if(write_address==19'h64) begin
                    s_axi_bresp<=0;
                    if(write_strobe[0]) begin
                        if(ENABLE_PREVIEW && uart_ready) begin uart_valid<=1;uart_data<=write_value[7:0];end
                        else s_axi_bresp<=2'b10;
                    end
                end else if(write_address==19'h7C && write_strobe[0]) begin
                    s_axi_bresp<=0;hold_view<=write_value[0];
                    if(write_value[1]) begin
                        if(result_score>1000) s_axi_bresp<=2'b10;
                        else begin
                            // bit6 reports live VAD even when it is not required.
                            result_flags<={23'd0,hold_view,result_new,mic_active,write_value[2],view_ok,epoch_ok,age_ok,(result_score>=500),result_eligible};
                            result_age_snapshot<=system_time>=result_time ? result_age : 64'hFFFFFFFFFFFFFFFF;
                            have_result<=1;last_result_sequence<=result_sequence;last_result_epoch<=result_epoch;
                            if(result_eligible && result_score>=500) begin vision_alert<=1;alert_count<=alert_count+1'b1;end
                        end
                    end
                end else if(write_strobe==4'hF) begin
                    case(write_address)
                        19'h80:begin result_score<=write_value;s_axi_bresp<=0;end
                        19'h84:begin result_epoch<=write_value;s_axi_bresp<=0;end
                        19'h88:begin result_time[31:0]<=write_value;s_axi_bresp<=0;end
                        19'h8C:begin result_time[63:32]<=write_value;s_axi_bresp<=0;end
                        19'hB0:begin result_sequence<=write_value;s_axi_bresp<=0;end
                        default:s_axi_bresp<=2'b10;
                    endcase
                end
            end
        end
    end
    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if(!s_axi_aresetn) begin
            read_state<=IDLE;s_axi_rvalid<=0;s_axi_rdata<=0;s_axi_rresp<=0;
            low_half<=0;high_half_valid<=0;memory_is_audio<=0;
            video_read_addr<=0;audio_read_addr<=0;
        end else begin
            case(read_state)
                IDLE: if(s_axi_arvalid && s_axi_arready) begin
                    s_axi_rdata<=0;s_axi_rresp<=0;
                    if(read_address[1:0]!=0) begin
                        s_axi_rresp<=2'b10;s_axi_rvalid<=1;read_state<=RESPONSE;
                    end else if(read_address>=VIDEO_BASE && read_address<VIDEO_BASE+VIDEO_PIXELS*2) begin
                        if(!video_frame_ready) begin s_axi_rresp<=2'b10;s_axi_rvalid<=1;read_state<=RESPONSE;end
                        else begin
                            memory_is_audio<=0;video_read_addr<=(read_address-VIDEO_BASE)>>1;
                            high_half_valid<=((read_address-VIDEO_BASE)>>1)+1<VIDEO_PIXELS;
                            read_state<=WAIT_LOW;
                        end
                    end else if(read_address>=AUDIO_BASE && read_address<AUDIO_BASE+AUDIO_BLOCK_SAMPLES*2) begin
                        if(!audio_ready) begin s_axi_rresp<=2'b10;s_axi_rvalid<=1;read_state<=RESPONSE;end
                        else begin
                            memory_is_audio<=1;audio_read_addr<=(read_address-AUDIO_BASE)>>1;
                            high_half_valid<=((read_address-AUDIO_BASE)>>1)+1<AUDIO_BLOCK_SAMPLES;
                            read_state<=WAIT_LOW;
                        end
                    end else begin
                        s_axi_rvalid<=1;read_state<=RESPONSE;
                        case(read_address)
                            19'h00:s_axi_rdata<=32'h4D434156;
                            19'h04:s_axi_rdata<=32'h00030000;
                            19'h08:s_axi_rdata<={29'd0,camera_init_done,audio_ready,video_frame_ready};
                            19'h0C:s_axi_rdata<=0;
                            19'h10:s_axi_rdata<=CLK_FREQ_HZ;
                            19'h14:s_axi_rdata<=CLK_FREQ_HZ/MIC_SAMPLE_TICKS;
                            19'h18:s_axi_rdata<=(VIDEO_HEIGHT<<16)|VIDEO_WIDTH;
                            19'h1C:s_axi_rdata<=AUDIO_BLOCK_SAMPLES;
                            19'h20:s_axi_rdata<=video_frame_sequence;
                            19'h24:s_axi_rdata<=video_frame_time[31:0];
                            19'h28:s_axi_rdata<=video_frame_time[63:32];
                            19'h2C:s_axi_rdata<=video_dropped_frames;
                            19'h30:s_axi_rdata<=video_bad_frames;
                            19'h34:s_axi_rdata<=audio_sequence;
                            19'h38:s_axi_rdata<=audio_time[31:0];
                            19'h3C:s_axi_rdata<=audio_time[63:32];
                            19'h40:s_axi_rdata<=audio_start_sample[31:0];
                            19'h44:s_axi_rdata<=audio_start_sample[63:32];
                            19'h48:s_axi_rdata<=audio_drops;
                            19'h60:s_axi_rdata<={29'd0,(ENABLE_PREVIEW!=0),uart_busy,uart_ready};
                            19'h64:s_axi_rdata<=0;
                            19'h70:s_axi_rdata<={26'd0,direction_matches,hold_view,servo_settled,servo_moving,direction_valid,mic_active};
                            19'h74:s_axi_rdata<={mic_angle,5'd0,target_direction,5'd0,stable_direction};
                            19'h78:s_axi_rdata<=motion_epoch;
                            19'h7C:s_axi_rdata<={31'd0,hold_view};
                            19'h80:s_axi_rdata<=result_score;
                            19'h84:s_axi_rdata<=result_epoch;
                            19'h88:s_axi_rdata<=result_time[31:0];
                            19'h8C:s_axi_rdata<=result_time[63:32];
                            19'h90:s_axi_rdata<=vad_energy[31:0];
                            19'h94:s_axi_rdata<={16'd0,vad_energy[47:32]};
                            19'h98:s_axi_rdata<=vad_noise[31:0];
                            19'h9C:s_axi_rdata<={16'd0,vad_noise[47:32]};
                            19'hA8:s_axi_rdata<=MIC_SAMPLE_TICKS;
                            19'hAC:s_axi_rdata<=alert_count;
                            19'hB0:s_axi_rdata<=result_sequence;
                            19'hB4:s_axi_rdata<=RESULT_MAX_AGE_TICKS[31:0];
                            19'hB8:s_axi_rdata<=result_flags;
                            19'hBC:s_axi_rdata<=RESULT_MAX_AGE_TICKS[63:32];
                            19'hC0:s_axi_rdata<=result_age_snapshot[31:0];
                            19'hC4:s_axi_rdata<=result_age_snapshot[63:32];
                            19'h4C:s_axi_rdata<=system_time[31:0];
                            19'h50:s_axi_rdata<=system_time[63:32];
                            default:begin s_axi_rdata<=0;s_axi_rresp<=2'b11;end
                        endcase
                    end
                end
                WAIT_LOW:read_state<=LATCH_LOW;
                LATCH_LOW:begin
                    low_half<=memory_is_audio ? audio_read_data : video_read_data;
                    if(memory_is_audio)audio_read_addr<=audio_read_addr+1'b1;
                    else video_read_addr<=video_read_addr+1'b1;
                    read_state<=WAIT_HIGH;
                end
                WAIT_HIGH:read_state<=LATCH_HIGH;
                LATCH_HIGH:begin
                    if(!high_half_valid) s_axi_rdata<={16'd0,low_half};
                    else s_axi_rdata<=memory_is_audio ? {audio_read_data,low_half} : {video_read_data,low_half};
                    s_axi_rvalid<=1;read_state<=RESPONSE;
                end
                RESPONSE:if(s_axi_rvalid && s_axi_rready) begin s_axi_rvalid<=0;read_state<=IDLE;end
                default:begin s_axi_rvalid<=0;read_state<=IDLE;end
            endcase
        end
    end
endmodule
