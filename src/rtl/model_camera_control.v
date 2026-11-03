`timescale 1ns/1ps
// Microphone direction -> voted target -> J3 servo only. J5 is held low.
// A CPU view lock keeps a captured visual window on one target; the current
// microphone direction still updates, so an off-target result can be rejected.
module model_camera_control #(
    parameter integer CLK_HZ=100_000_000,
    parameter integer SIMULATION=0,
    parameter integer FRESH_CYCLES=25_000_000,
    parameter integer SETTLE_CYCLES=15_000_000,
    parameter integer VIB_CYCLES=30_000_000,
    // 100 MHz 下 240 秒 = 4 分钟。没有新的有效方向就回中位。
    parameter [63:0] IDLE_CYCLES=64'd24_000_000_000
)(
    input wire clk,rst_n,voice_active,direction_update,
    input wire [2:0] direction,
    input wire hold_view,vision_alert,
    output wire servo0,servo1,vib,
    output wire [7:0] led,
    output reg [2:0] stable_direction,target_direction,
    output wire direction_valid,moving,settled,direction_matches,
    output reg [31:0] motion_epoch
);
    reg [2:0] history[0:3];
    reg [2:0] history_count;
    reg [2:0] same_direction,same_count;
    reg have_direction,target_active;
    reg [31:0] fresh_count,settle_count,vib_count;
    wire pan_moving;
    wire tilt_moving = 1'b0;
    wire [31:0] pan_pulse;
    reg [31:0] previous_pan;
    reg [2:0] previous_target;
    reg previous_active;
    integer matches,i;
    always @(*) begin
        matches=1;
        for(i=0;i<4;i=i+1) if(history_count>i && history[i]==direction) matches=matches+1;
    end
    assign direction_valid=voice_active && have_direction && fresh_count!=0;
    assign moving=pan_moving || tilt_moving;
    assign settled=!moving && settle_count==0;
    assign direction_matches=direction_valid && target_active && target_direction==stable_direction;
    assign led=direction_valid ? (8'h80 >> stable_direction) : 8'h00;
    assign vib=vib_count!=0;
    assign servo1=1'b0;
    reg force_center;
    reg [63:0] idle_count;
    // The observed J3 mounting turns opposite to the direction LED. Reverse
    // only its pulse offset; microphone coordinates and the 1500-us home stay.
    servo_pwm #(.CLK_HZ(CLK_HZ),.SIMULATION(SIMULATION),
        .REVERSE_DIRECTION(1),.REAR_NEAREST_ENDPOINT(1)) u_pan (
        .clk(clk),.rst(rst_n),.dir(target_direction),.conf(target_active ? 8'd200 : 8'd0),
        .force_center(force_center),.pwm(servo0),.moving(pan_moving),.pulse_ticks(pan_pulse)
    );
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            history_count<=0;have_direction<=0;stable_direction<=0;
            same_direction<=0;same_count<=0;
            target_active<=0;target_direction<=0;fresh_count<=0;
            settle_count<=SETTLE_CYCLES;vib_count<=0;motion_epoch<=0;
            previous_pan<=0;previous_target<=0;previous_active<=0;
            force_center<=0;idle_count<=0;
            history[0]<=0;history[1]<=0;history[2]<=0;history[3]<=0;
        end else begin
            if(fresh_count!=0)fresh_count<=fresh_count-1'b1;
            if(!voice_active || fresh_count==0) begin
                history_count<=0;have_direction<=0;same_count<=0;
            end
            if(voice_active && direction_update) begin
                fresh_count<=FRESH_CYCLES;
                if(fresh_count==0) begin
                    history[0]<=direction;history_count<=1;have_direction<=0;
                    same_direction<=direction;same_count<=1;
                end else begin
                    if(same_count!=0 && same_direction==direction) begin
                        if(same_count<3)same_count<=same_count+1'b1;
                    end else begin same_direction<=direction;same_count<=1;end
                    history[3]<=history[2];history[2]<=history[1];history[1]<=history[0];history[0]<=direction;
                    if(history_count<4)history_count<=history_count+1'b1;
                    if((history_count>=4 && matches>=3) ||
                       (same_count>=2 && same_direction==direction)) begin
                        stable_direction<=direction;have_direction<=1;
                    end
                end
            end
            if(!hold_view) begin
                target_active<=direction_valid;
                if(direction_valid)target_direction<=stable_direction;
            end
            if(direction_valid) begin
                idle_count<=0;
                force_center<=0;
            end else if(!force_center) begin
                if(idle_count>=IDLE_CYCLES) force_center<=1;
                else idle_count<=idle_count+1'b1;
            end
            previous_pan<=pan_pulse;
            previous_target<=target_direction;previous_active<=target_active;
            if(pan_pulse!=previous_pan ||
               target_direction!=previous_target || target_active!=previous_active) begin
                motion_epoch<=motion_epoch+1'b1;settle_count<=SETTLE_CYCLES;
            end else if(moving)settle_count<=SETTLE_CYCLES;
            else if(settle_count!=0)settle_count<=settle_count-1'b1;
            if(vib_count!=0)vib_count<=vib_count-1'b1;
            if(vision_alert)vib_count<=VIB_CYCLES;
        end
    end
endmodule
