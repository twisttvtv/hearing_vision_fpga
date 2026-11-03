`timescale 1ns/1ps
// Test exact energy boundaries, entry/exit persistence and top-level parameters.
module model_camera_vad_tb;
    reg clk=0;
    reg rst_n=0;
    wire active;
    integer i;
    always #5 clk=~clk;
    voice_band_energy_vad_v2 #(
        .INIT_HOPS(1),.ATTACK_HOPS(5),.RELEASE_HOPS(35),
        .ABS_MEAN_POWER(16),.NOISE_MULT_SHIFT(1),.STOP_MULT_SHIFT(0),
        .ABS_FRAME_ENERGY_OVERRIDE(6000)
    ) detector (
        .clk(clk),.rst_n(rst_n),.sample_valid(1'b0),
        .x1(16'sd0),.x2(16'sd0),.x3(16'sd0),.x4(16'sd0),
        .voice_active(active)
    );
    voice_band_energy_vad_v2 #(.ABS_MEAN_POWER(16)) legacy (
        .clk(clk),.rst_n(rst_n),.sample_valid(1'b0),
        .x1(16'sd0),.x2(16'sd0),.x3(16'sd0),.x4(16'sd0)
    );
    model_camera_top parameter_chain();

    task fail;
        input [511:0] message;
        begin $display("FAIL %0s",message);$finish;end
    endtask
    // Inject completed hop energies at the detector decision boundary.
    // Sampling/filter scaling is outside this threshold/persistence test.
    task hop;
        input [41:0] energy;
        input [41:0] noise;
        begin
            @(negedge clk);
            detector.pending_energy=energy;
            detector.noise_floor_i=noise;
            detector.state=3'd5;
            #1;
            if(detector.start_level!=((noise*2>6000)?noise*2:6000))
                fail("Start threshold must use twice current noise or absolute floor");
            if(detector.stop_level!=((noise>3000)?noise:3000))
                fail("Stop threshold must use current noise or absolute floor");
            @(posedge clk);#1;
            @(posedge clk);#1;
        end
    endtask

    initial begin
        repeat(3) @(posedge clk);
        @(negedge clk);rst_n=1;
        detector.init_done=1;
        if(detector.ABS_FRAME_ENERGY!=6000)fail("Exact absolute energy must be 6000");
        if(legacy.ABS_FRAME_ENERGY!=30720)fail("Zero override must preserve legacy energy");
        if(parameter_chain.u_io.u_mic.u_voice_vad.ABS_FRAME_ENERGY!=6000)
            fail("Top-level energy override did not reach detector");
        if(parameter_chain.u_io.u_mic.u_voice_vad.NOISE_MULT_SHIFT!=1 ||
           parameter_chain.u_io.u_mic.u_voice_vad.STOP_MULT_SHIFT!=0)
            fail("Top-level start/stop noise multipliers must be two/one");
        for(i=0;i<6;i=i+1)hop(6000,100);
        if(active)fail("Energy equal to 6000 must not start speech");
        if(detector.start_level!=6000 || detector.stop_level!=3000)
            fail("Low noise must not lower absolute start/stop floors");
        for(i=0;i<4;i=i+1)hop(6001,1186);
        if(active)fail("Four candidate hops must not pass five-hop entry");
        hop(6001,1186);
        if(!active)fail("Five candidate hops must start speech");
        for(i=0;i<35;i=i+1)hop(3000,1186);
        if(!active)fail("Energy equal to stop floor must not release speech");
        for(i=0;i<34;i=i+1)hop(2999,1186);
        if(!active)fail("Thirty-four quiet hops must not release speech");
        hop(2999,1186);
        if(active)fail("Thirty-five quiet hops must release speech");
        for(i=0;i<5;i=i+1)hop(8000,4000);
        if(active)fail("Energy equal to dynamic start threshold must not start speech");
        for(i=0;i<5;i=i+1)hop(8001,4000);
        if(!active)fail("Five hops above twice the noise must start speech");
        for(i=0;i<35;i=i+1)hop(4000,4000);
        if(!active)fail("Energy equal to dynamic stop threshold must not release speech");
        for(i=0;i<35;i=i+1)hop(3999,4000);
        if(active)fail("Thirty-five hops below dynamic stop threshold must release speech");
        for(i=0;i<5;i=i+1)hop(6500,7000);
        if(active)
            fail("Noise above absolute floor must raise start threshold");
        for(i=0;i<5;i=i+1)hop(14001,7000);
        if(!active)fail("Five hops above raised threshold must start speech");
        $display("PASS VAD: exact 6000 floor, 2x/1x noise, 3000 exit floor, absolute/dynamic boundaries, 5/35 persistence, full top-level parameter chain and legacy fallback");
        $finish;
    end
    initial begin #100000;fail("Timeout");end
endmodule
