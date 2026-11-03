`timescale 1ns/1ps
// Physical mounting correction: up is home, J3 is reversed, rear uses nearest end.
module model_camera_servo_direction_tb;
    reg clk=0,rst_n=0,voice=0,update=0,hold_view=0,alert=0;
    reg [2:0] direction=0;
    wire pan,tilt,vib,valid,moving,settled,matches;
    wire [7:0] led;
    wire [2:0] stable,target;
    always #5 clk=~clk;
    model_camera_control #(.SIMULATION(1),.FRESH_CYCLES(1000000),
        .SETTLE_CYCLES(10),.VIB_CYCLES(100),.IDLE_CYCLES(12000)) dut (
        .clk(clk),.rst_n(rst_n),.voice_active(voice),.direction_update(update),
        .direction(direction),.hold_view(hold_view),.vision_alert(alert),
        .servo0(pan),.servo1(tilt),.vib(vib),.led(led),
        .stable_direction(stable),.target_direction(target),.direction_valid(valid),
        .moving(moving),.settled(settled),.direction_matches(matches)
    );
    task fail;
        input [511:0] message;
        begin $display("FAIL %0s",message);$finish;end
    endtask
    task cycles;
        input integer count;
        integer i;
        begin for(i=0;i<count;i=i+1)begin @(posedge clk);#1;end end
    endtask
    task vote;
        input [2:0] d;
        integer j;
        begin
            @(negedge clk);voice=0;update=0;cycles(2);
            @(negedge clk);voice=1;direction=d;
            for(j=0;j<3;j=j+1)begin
                update=1;cycles(1);
                @(negedge clk);update=0;cycles(2);@(negedge clk);
            end
            cycles(10);
            if(!valid || stable!=d || led!=(8'h80 >> d))
                fail("Microphone direction and LED must retain their coordinates");
        end
    endtask
    task waveform;
        input integer expected;
        time t0,t1;
        begin
            @(posedge pan);t0=$time;@(negedge pan);t1=$time;
            if(t1-t0!=expected*10)fail("Wrong PWM high time");
            @(posedge pan);
            if($time-t0!=20000)fail("Wrong PWM period");
        end
    endtask
    task point;
        input [2:0] d;
        input integer expected;
        begin
            vote(d);cycles(6100);
            if(target!=d || dut.pan_pulse!=expected || !settled || !matches)
                fail("Direction target, reversed endpoint or settling mismatch");
            waveform(expected);
        end
    endtask
    always @(posedge clk)begin
        if(tilt!==1'b0)fail("J5 must remain low");
        if(dut.pan_pulse<62 || dut.pan_pulse>238)
            fail("Pulse exceeded existing endpoint range");
    end
    initial begin
        cycles(300);@(negedge clk);rst_n=1;cycles(4100);
        if(dut.pan_pulse!=150)fail("Power-up home must remain centered");
        point(0,84);point(1,117);point(2,150);point(3,183);
        point(4,216);point(5,238);point(7,62);
        point(6,62); // Rear after right endpoint stays on the right.
        point(3,183);point(6,238); // Rear from left half selects left end.
        point(1,117);point(6,62);  // Rear from right half selects right end.
        point(2,150);point(6,238); // Equidistant at home: logical left.
        @(negedge clk);hold_view=1;
        vote(0);cycles(6100);
        if(target!=6 || dut.pan_pulse!=238 || matches)
            fail("View lock must hold servo while LED follows new direction");
        @(negedge clk);hold_view=0;cycles(6100);
        if(target!=0 || dut.pan_pulse!=84 || !matches)
            fail("View release must follow new direction");
        @(negedge clk);voice=0;cycles(6100);
        if(led!=0 || dut.pan_pulse!=84 || dut.force_center)
            fail("Silence must hold the last angle before idle timeout");
        cycles(13000);
        if(!dut.force_center || dut.pan_pulse!=150)
            fail("Idle timeout must return to up/home");
        @(negedge clk);alert=1;cycles(1);
        if(!vib)fail("Vibration trigger was lost");
        @(negedge clk);alert=0;cycles(101);
        if(vib)fail("Vibration must finish");
        @(negedge clk);rst_n=0;cycles(2);
        if(pan!==0 || tilt!==0 || vib!==0 || dut.pan_pulse!=150)
            fail("Reset must retain home and clear outputs");
        $display("PASS servo direction: mirrored eight directions, unchanged LEDs, up/home, nearest rear endpoints, tie-left, pulse limits, view lock/release, idle center and vibration");
        $finish;
    end
    initial begin #10000000;fail("Timeout");end
endmodule
