`timescale 1ns / 1ps
`include "defines.v"

module tb_lane1_branch_pair;
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

    reg [31:0] rom [0:63];
    integer i;
    integer cycles = 0;
    integer paired_branches = 0;
    integer branch_squashes = 0;
    integer predicted_taken_squashes = 0;

    open_risc_v dut (
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

    function automatic [31:0] make_branch;
        input [2:0]  func3;
        input [4:0]  rs1;
        input [4:0]  rs2;
        input [12:0] offset;
        begin
            make_branch = {offset[12], offset[10:5], rs2, rs1,
                           func3, offset[4:1], offset[11],
                           `INST_TYPE_B};
        end
    endfunction

    function automatic [31:0] make_add;
        input [4:0] rd;
        input [4:0] rs1;
        input [4:0] rs2;
        begin
            make_add = {`INST_FUNC7_R, rs2, rs1, `INST_ADD_SUB,
                        rd, `INST_TYPE_R_M};
        end
    endfunction

    // Match the two synchronous IROM copies used by student_top.
    always @(posedge clk) begin
        if (!rst_n) begin
            inst      <= `INST_NOP;
            inst_next <= `INST_NOP;
        end else begin
            inst      <= rom[irom_addr[7:2]];
            inst_next <= rom[irom_addr[7:2] + 6'd1];
        end
    end

    initial begin
        for (i = 0; i < 64; i = i + 1)
            rom[i] = `INST_NOP;

        // Initialize every observed register because the FPGA register file
        // intentionally has no array reset.
        rom[0] = make_addi(5'd2,  5'd0, 12'd0);
        rom[1] = make_addi(5'd3,  5'd0, 12'd6);
        rom[2] = make_addi(5'd4,  5'd0, 12'd0);
        rom[3] = make_addi(5'd10, 5'd0, 12'd0);
        rom[4] = make_addi(5'd11, 5'd0, 12'd0);
        rom[5] = make_addi(5'd12, 5'd0, 12'd0);
        rom[6] = make_addi(5'd13, 5'd0, 12'd1);

        // Taken branch: the paired PC+4 instruction must be squashed.
        rom[8]  = make_branch(`INST_BEQ, 5'd0, 5'd0, 13'd8);
        rom[9]  = make_addi(5'd10, 5'd0, 12'h011);

        // Correctly not-taken branch: the paired instruction may retire.
        rom[10] = make_branch(`INST_BNE, 5'd0, 5'd0, 13'd8);
        rom[11] = make_addi(5'd11, 5'd0, 12'h022);

        // Repeated taken branch trains the predictor. Its paired increment is
        // wrong-path while taken and must execute exactly once on loop exit.
        // The target deliberately reads x13.  A squashed Lane-1 result from
        // the preceding taken branch must never bypass into this ADD.
        rom[12] = make_add(5'd2, 5'd2, 5'd13);
        rom[13] = make_addi(5'd4, 5'd4, 12'd1);
        rom[14] = make_branch(`INST_BLT, 5'd2, 5'd3, -13'sd8);
        rom[15] = make_addi(5'd13, 5'd0, 12'd100);

        rom[16] = make_addi(5'd31, 5'd0, 12'h07b);
        rom[17] = 32'h0000_006f; // jal x0, self

        repeat (6) @(posedge clk);
        rst_n = 1'b1;

        wait (dut.regs_inst.regs[31] === 32'h0000_007b);
        repeat (12) @(posedge clk);

        if (dut.regs_inst.regs[10] !== 32'h0000_0000)
            $fatal(1, "taken branch leaked Lane-1 write x10=%08x",
                   dut.regs_inst.regs[10]);
        if (dut.regs_inst.regs[11] !== 32'h0000_0022)
            $fatal(1, "not-taken branch lost Lane-1 write x11=%08x",
                   dut.regs_inst.regs[11]);
        if (dut.regs_inst.regs[4] !== 32'h0000_0006)
            $fatal(1, "loop body count mismatch x4=%08x",
                   dut.regs_inst.regs[4]);
        if (dut.regs_inst.regs[13] !== 32'h0000_0064)
            $fatal(1, "branch fallthrough result mismatch x13=%08x",
                   dut.regs_inst.regs[13]);
        if (paired_branches < 3 || branch_squashes < 2)
            $fatal(1, "branch pairing/squash was not exercised pairs=%0d squash=%0d",
                   paired_branches, branch_squashes);
        if (predicted_taken_squashes == 0)
            $fatal(1, "correctly predicted taken branch squash not exercised");

        $display("TB_PASS branch pairing pairs=%0d squashes=%0d predicted_taken_squashes=%0d",
                 paired_branches, branch_squashes,
                 predicted_taken_squashes);
        $finish;
    end

    always @(posedge clk) begin
        if (rst_n) begin
            cycles = cycles + 1;
            if (cycles > 1000)
                $fatal(1, "branch pair timeout pc=%08x x2=%08x x3=%08x x4=%08x x10=%08x x11=%08x x12=%08x pairs=%0d squash=%0d",
                       pc, dut.regs_inst.regs[2], dut.regs_inst.regs[3],
                       dut.regs_inst.regs[4], dut.regs_inst.regs[10],
                       dut.regs_inst.regs[11], dut.regs_inst.regs[12],
                       paired_branches, branch_squashes);

            if (dut.if_id_valid_o && dut.if_id_pair_valid_o &&
                (dut.if_id_inst_o[6:0] == `INST_TYPE_B) &&
                !dut.core_hold_flag)
                paired_branches = paired_branches + 1;
            if (dut.lane1_branch_squash) begin
                branch_squashes = branch_squashes + 1;
                if (dut.id_ex_pred_taken_o && dut.bp_actual_taken_o)
                    predicted_taken_squashes =
                        predicted_taken_squashes + 1;
            end
        end
    end

endmodule
