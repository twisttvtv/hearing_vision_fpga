`timescale 1ns/1ps
module model_camera_alert_policy_tb;
    reg clk=0,rst_n=0;always #5 clk=~clk;
    reg [31:0] awaddr=0,wdata=0,araddr=0;reg [3:0] wstrb=0;
    reg awvalid=0,wvalid=0,bready=0,arvalid=0,rready=0;
    wire awready,wready,bvalid,arready,rvalid;wire [1:0] bresp,rresp;wire [31:0] rdata;
    reg a_ready=1,v_ready=1,mic=1,matched=1,settled=1,dir_valid=1,moving=0;
    reg [31:0] epoch=7;
    reg [63:0] now=64'h300000000;
    wire a_release,v_release,hold_view,alert,vib;
    integer vib_edges=0;reg vib_d=0;
    wire [9:0] a_addr;wire [15:0] v_addr;
    reg [15:0] a_data=0,v_data=0;
    integer alerts=0;
    reg [31:0] value;
    task fail;input [1023:0] message;begin $display("FAIL: %0s",message);$finish;end endtask
    model_camera_axi #(.VIDEO_WIDTH(3),.VIDEO_HEIGHT(1),.AUDIO_BLOCK_SAMPLES(3)) dut (
        .s_axi_aclk(clk),.s_axi_aresetn(rst_n),
        .s_axi_awaddr(awaddr),.s_axi_awprot(3'd0),.s_axi_awvalid(awvalid),.s_axi_awready(awready),
        .s_axi_wdata(wdata),.s_axi_wstrb(wstrb),.s_axi_wvalid(wvalid),.s_axi_wready(wready),
        .s_axi_bresp(bresp),.s_axi_bvalid(bvalid),.s_axi_bready(bready),
        .s_axi_araddr(araddr),.s_axi_arprot(3'd0),.s_axi_arvalid(arvalid),.s_axi_arready(arready),
        .s_axi_rdata(rdata),.s_axi_rresp(rresp),.s_axi_rvalid(rvalid),.s_axi_rready(rready),
        .video_frame_ready(v_ready),.camera_init_done(1'b1),.video_frame_time(64'd99),.system_time(now),
        .video_frame_sequence(32'd10),.video_dropped_frames(32'd0),.video_bad_frames(32'd0),
        .video_release(v_release),.video_read_addr(v_addr),.video_read_data(v_data),
        .uart_ready(1'b0),.uart_busy(1'b0),
        .audio_ready(a_ready),.audio_time(64'h123456789ABCDEF0),.audio_start_sample(64'd960),
        .audio_sequence(32'd2),.audio_drops(32'd3),.audio_release(a_release),.audio_read_addr(a_addr),.audio_read_data(a_data),
        .mic_active(mic),.direction_valid(dir_valid),.servo_moving(moving),.servo_settled(settled),.direction_matches(matched),
        .stable_direction(3'd2),.target_direction(3'd2),.mic_angle(16'h4000),.motion_epoch(epoch),
        .vad_energy(48'd123),.vad_noise(48'd4),.hold_view(hold_view),.vision_alert(alert)
    );
    // Check AXI decision -> alert pulse -> actual vibration output.
    model_camera_control #(.SIMULATION(1),.VIB_CYCLES(20)) control (
        .clk(clk),.rst_n(rst_n),.voice_active(mic),.direction_update(1'b0),.direction(3'd2),
        .hold_view(hold_view),.vision_alert(alert),.vib(vib)
    );
    always @(posedge clk) begin
        vib_d<=vib;
        if(vib && !vib_d)vib_edges<=vib_edges+1;
    end
    always @(posedge clk) begin
        case(a_addr) 0:a_data<=16'h8001;1:a_data<=16'h7FFF;2:a_data<=16'hFFFF;default:a_data<=0;endcase
        case(v_addr) 0:v_data<=16'hF800;1:v_data<=16'h07E0;2:v_data<=16'h001F;default:v_data<=0;endcase
        if(a_release)a_ready<=0;
        if(v_release)v_ready<=0;
        if(alert)alerts<=alerts+1;
    end
    task read_word;input [31:0] a,expected;input [1:0] response;integer i;begin
        @(negedge clk);araddr=a;arvalid=1;
        @(posedge clk);while(!arready)@(posedge clk);
        @(negedge clk);arvalid=0;wait(rvalid);@(negedge clk);
        for(i=0;i<3;i=i+1)begin
            if(rdata!==expected || rresp!==response || !rvalid)fail("AXI read/hold failed");
            @(negedge clk);
        end
        rready=1;@(negedge clk);rready=0;
    end endtask
    task write_word;input [31:0] a,d;input [3:0] strobe;input [1:0] response;integer i;begin
        @(negedge clk);awaddr=a;awvalid=1;
        @(posedge clk);while(!awready)@(posedge clk);
        @(negedge clk);awvalid=0;wdata=d;wstrb=strobe;wvalid=1;
        @(posedge clk);while(!wready)@(posedge clk);
        @(negedge clk);wvalid=0;wait(bvalid);@(negedge clk);
        for(i=0;i<3;i=i+1)begin if(bresp!==response || !bvalid)fail("AXI write/hold failed");@(negedge clk);end
        bready=1;@(negedge clk);bready=0;
    end endtask
    task result;input [31:0] score,ep,seq;input [63:0] stamp;input evidence;begin
        write_word('h80,score,15,0);write_word('h84,ep,15,0);
        write_word('h88,stamp[31:0],15,0);write_word('h8C,stamp[63:32],15,0);
        write_word('hB0,seq,15,0);write_word('h7C,evidence ? 7 : 3,1,score>1000 ? 2 : 0);
    end endtask

    initial begin
        #73;rst_n=1;
        read_word(0,32'h4D434156,0);read_word(4,32'h30000,0);
        read_word('hB4,32'hCB417800,0);read_word('hBC,2,0);
        write_word('h7C,1,1,0);
        result(499,7,1,now-1000,1);if(alerts!=0)fail("score below threshold accepted");
        // All three relaxed conditions: 110 seconds old, quiet, no current direction.
        mic=0;matched=0;dir_valid=0;
        result(500,7,2,now-64'd11000000000,1);
        if(alerts!=1 || vib_edges!=1)fail("delayed quiet result did not trigger vibration");
        read_word('hB8,32'h1BF,0);
        read_word('hC0,32'h8FA6AE00,0);read_word('hC4,2,0);
        result(900,7,2,now-1000,1);if(alerts!=1)fail("duplicate accepted");
        result(900,6,3,now-1000,1);if(alerts!=1)fail("wrong epoch accepted");
        result(900,7,4,now-64'd12000000001,1);if(alerts!=1)fail("older than 120 seconds accepted");
        result(900,7,5,now+1,1);if(alerts!=1)fail("future timestamp accepted");
        mic=1;dir_valid=1;matched=0;
        result(900,7,6,now-1000,1);if(alerts!=1)fail("valid conflicting direction accepted");
        mic=0;matched=1;
        result(900,7,7,now-1000,1);if(alerts!=2)fail("quiet matching direction rejected");
        mic=1;dir_valid=0;matched=0;
        result(900,7,8,now-1000,1);if(alerts!=3)fail("unknown direction fallback rejected");
        moving=1;result(900,7,9,now-1000,1);moving=0;
        if(alerts!=3)fail("moving servo accepted");
        settled=0;result(900,7,10,now-1000,1);settled=1;
        if(alerts!=3)fail("unsettled servo accepted");
        result(900,7,11,now-1000,0);if(alerts!=3)fail("missing capture evidence accepted");
        result(1001,7,12,now-1000,1);if(alerts!=3)fail("out of range score accepted");
        write_word('h7C,0,1,0);result(900,7,13,now-1000,1);
        if(alerts!=3)fail("unlocked result accepted");
        write_word('h7C,1,1,0);
        result(900,7,14,now-64'd12000000000,1);
        if(alerts!=4 || vib_edges!=4)fail("inclusive 120 second boundary/vibration failed");
        repeat(30)@(negedge clk);if(vib)fail("vibration pulse did not finish");
        $display("PASS: relaxed 120-second alert -> vibration, quiet/unknown-direction fallback, 64-bit age diagnostics; score/evidence/epoch/motion/duplicate/lock protections retained");
        $finish;
    end
    initial begin #1000000;fail("AXI timeout");end
endmodule
