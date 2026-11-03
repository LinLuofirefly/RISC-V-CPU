`timescale 1ns / 1ps
`include "defines.v"

module tb_dual_issue_version_forward;
    reg         clk = 1'b0;
    reg         rst_n = 1'b0;
    reg  [31:0] inst = `INST_NOP;
    reg  [31:0] inst_next = `INST_NOP;
    wire [31:0] pc;
    wire [31:0] irom_addr;
    wire        mem_rd;
    wire [31:0] mem_rd_addr;
    wire [3:0]  mem_wen;
    wire [31:0] mem_waddr;
    wire [31:0] mem_wdata;

    reg [31:0] rom [0:31];
    integer i;
    integer cycles = 0;
    integer version_overlap_cycles = 0;
    reg saw_side_newer = 1'b0;
    reg saw_main_newer = 1'b0;

    open_risc_v #(
        .ENABLE_REQUEST_STAGE_BP(1'b0),
        .ENABLE_DUAL_ISSUE(1'b1)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .inst_i(inst),
        .inst_next_i(inst_next),
        .ram_data_i(32'b0),
        .mmio_data_i(32'b0),
        .timer_irq_i(1'b0),
        .pc_reg_pc_o(pc),
        .irom_addr_o(irom_addr),
        .mem_rd_reg_o(mem_rd),
        .mem_rd_addr_o(mem_rd_addr),
        .w_en(mem_wen),
        .w_addr_i(mem_waddr),
        .w_data_i(mem_wdata)
    );

    always #5 clk = ~clk;

    function automatic [31:0] make_addi;
        input [4:0]  rd;
        input [4:0]  rs1;
        input [11:0] imm;
        begin
            make_addi = {imm, rs1, `INST_ADDI, rd, `INST_TYPE_I};
        end
    endfunction

    always @(posedge clk) begin
        if (!rst_n) begin
            inst      <= `INST_NOP;
            inst_next <= `INST_NOP;
        end else begin
            inst      <= rom[irom_addr[6:2]];
            inst_next <= rom[irom_addr[6:2] + 5'd1];
        end
    end

    initial begin
        for (i = 0; i < 32; i = i + 1)
            rom[i] = `INST_NOP;

        // x5 first comes from the main lane, then from a younger side lane.
        // The consumer must take side value 2 while main value 1 is still in
        // flight, without waiting for either version to leave the pipeline.
        rom[0] = make_addi(5'd5, 5'd0, 12'd1);
        rom[1] = make_addi(5'd1, 5'd0, 12'd11);
        rom[2] = make_addi(5'd2, 5'd0, 12'd22);
        rom[3] = make_addi(5'd5, 5'd0, 12'd2);
        rom[4] = make_addi(5'd6, 5'd5, 12'd1);
        rom[5] = make_addi(5'd3, 5'd0, 12'd33);

        // Reverse the producer lanes for x7.  The younger main value 5 must
        // override the older side value 4 through normal EX forwarding.
        rom[6] = make_addi(5'd4, 5'd0, 12'd44);
        rom[7] = make_addi(5'd7, 5'd0, 12'd4);
        rom[8] = make_addi(5'd7, 5'd0, 12'd5);
        rom[9] = make_addi(5'd9, 5'd0, 12'd99);
        rom[10] = make_addi(5'd8, 5'd7, 12'd1);
        rom[11] = make_addi(5'd10, 5'd0, 12'd10);

        rom[12] = make_addi(5'd31, 5'd0, 12'h07b);
        rom[13] = 32'h0000_006f;

        repeat (6) @(posedge clk);
        rst_n = 1'b1;

        wait (dut.regs_inst.regs[31] === 32'h0000_007b);
        repeat (10) @(posedge clk);

        if (dut.regs_inst.regs[6] !== 32'd3)
            $fatal(1, "newer side version mismatch x6=%08x",
                   dut.regs_inst.regs[6]);
        if (dut.regs_inst.regs[8] !== 32'd6)
            $fatal(1, "newer main version mismatch x8=%08x",
                   dut.regs_inst.regs[8]);
        if (!saw_side_newer || !saw_main_newer ||
            (version_overlap_cycles != 2))
            $fatal(1, "version ordering coverage mismatch side=%0b main=%0b overlaps=%0d",
                   saw_side_newer, saw_main_newer,
                   version_overlap_cycles);

        $display("TB_PASS dual version forwarding overlaps=%0d side_newer=%0b main_newer=%0b",
                 version_overlap_cycles, saw_side_newer, saw_main_newer);
        $finish;
    end

    always @(posedge clk) begin
        if (rst_n) begin
            cycles = cycles + 1;
            if (cycles > 500)
                $fatal(1, "version forwarding timeout pc=%08x", pc);

            if (dut.if_id_valid_o &&
                ((dut.if_id_inst_addr_o == 32'h8000_0010) ||
                 (dut.if_id_inst_addr_o == 32'h8000_0028))) begin
                if (!dut.dual_issue_forwarding_inst.lane1_pipe_writes_id_rs1)
                    $fatal(1, "expected simultaneous versions missing pc=%08x",
                           dut.if_id_inst_addr_o);
                if (dut.dual_dependency_wait)
                    $fatal(1, "resolved register versions still stalled pc=%08x",
                           dut.if_id_inst_addr_o);
                version_overlap_cycles = version_overlap_cycles + 1;

                if (dut.if_id_inst_addr_o == 32'h8000_0010) begin
                    if (!dut.lane0_rs1_side_newer ||
                        (dut.id_rs1_fwd_sel_o != 3'd0))
                        $fatal(1, "side-newer selection mismatch side=%0b sel=%0d",
                               dut.lane0_rs1_side_newer,
                               dut.id_rs1_fwd_sel_o);
                    saw_side_newer = 1'b1;
                end else begin
                    if (dut.lane0_rs1_side_newer ||
                        (dut.id_rs1_fwd_sel_o != 3'd1))
                        $fatal(1, "main-newer selection mismatch side=%0b sel=%0d",
                               dut.lane0_rs1_side_newer,
                               dut.id_rs1_fwd_sel_o);
                    saw_main_newer = 1'b1;
                end
            end
        end
    end

endmodule
