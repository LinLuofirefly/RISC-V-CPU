`timescale 1ns / 1ps
`include "defines.v"

module tb_lane1_store_pair;
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
    integer swap_pair_count = 0;
    integer side_result_writes = 0;
    integer store_count = 0;
    reg saw_sw = 1'b0;
    reg saw_sh = 1'b0;
    reg saw_sb = 1'b0;

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

    function automatic [31:0] make_store;
        input [2:0]  func3;
        input [4:0]  rs1;
        input [4:0]  rs2;
        input [11:0] imm;
        begin
            make_store = {imm[11:5], rs2, rs1, func3,
                          imm[4:0], `INST_TYPE_S};
        end
    endfunction

    function automatic [31:0] make_u;
        input [19:0] imm;
        input [4:0]  rd;
        input [6:0]  opcode;
        begin
            make_u = {imm, rd, opcode};
        end
    endfunction

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

        // x10 is the DRAM base. x12 is deliberately produced in Lane 1 so
        // the first swapped store also covers cross-lane store-data bypass.
        rom[0] = make_u(20'h80100, 5'd10, `INST_LUI);
        rom[1] = make_addi(5'd12, 5'd0, 12'h344);

        rom[2] = make_addi(5'd1, 5'd0, 12'd5);
        rom[3] = make_store(`INST_SW, 5'd10, 5'd12, 12'd0);

        rom[4] = make_addi(5'd2, 5'd1, 12'd1);
        rom[5] = make_store(`INST_SH, 5'd10, 5'd12, 12'd2);

        rom[6] = make_u(20'h00000, 5'd3, `INST_AUIPC);
        rom[7] = make_store(`INST_SB, 5'd10, 5'd12, 12'd1);

        rom[8] = make_addi(5'd31, 5'd0, 12'h07b);
        rom[9] = 32'h0000_006f; // jal x0, self

        repeat (6) @(posedge clk);
        rst_n = 1'b1;

        wait (dut.regs_inst.regs[31] === 32'h0000_007b);
        repeat (12) @(posedge clk);

        if (dut.regs_inst.regs[1] !== 32'd5)
            $fatal(1, "older ADDI result mismatch x1=%08x",
                   dut.regs_inst.regs[1]);
        if (dut.regs_inst.regs[2] !== 32'd6)
            $fatal(1, "side dependency result mismatch x2=%08x",
                   dut.regs_inst.regs[2]);
        if (dut.regs_inst.regs[3] !== 32'h8000_0018)
            $fatal(1, "swapped AUIPC PC mismatch x3=%08x",
                   dut.regs_inst.regs[3]);
        if (swap_pair_count != 3)
            $fatal(1, "store swap pair count mismatch %0d",
                   swap_pair_count);
        if (side_result_writes != 3)
            $fatal(1, "older side instructions retired %0d times",
                   side_result_writes);
        if (store_count != 3 || !saw_sw || !saw_sh || !saw_sb)
            $fatal(1, "store coverage mismatch count=%0d sw=%0b sh=%0b sb=%0b",
                   store_count, saw_sw, saw_sh, saw_sb);

        $display("TB_PASS swapped stores pairs=%0d side_writes=%0d stores=%0d",
                 swap_pair_count, side_result_writes, store_count);
        $finish;
    end

    always @(posedge clk) begin
        if (rst_n) begin
            cycles = cycles + 1;
            if (cycles > 1000)
                $fatal(1, "swapped store timeout pc=%08x", pc);

            if (dut.if_id_valid_o && dut.if_id_pair_valid_o &&
                dut.if_id_pair_swap_o && !dut.core_hold_flag)
                swap_pair_count = swap_pair_count + 1;

            if (dut.lane1_wb_valid &&
                ((dut.lane1_wb_rd == 5'd1) ||
                 (dut.lane1_wb_rd == 5'd2) ||
                 (dut.lane1_wb_rd == 5'd3)))
                side_result_writes = side_result_writes + 1;

            if (dut.lane1_idex_valid &&
                ((dut.lane1_idex_rd == 5'd1) ||
                 (dut.lane1_idex_rd == 5'd2) ||
                 (dut.lane1_idex_rd == 5'd3)) &&
                !dut.lane1_idex_older)
                $fatal(1, "swapped older store companion lost age tag");

            if (|mem_wen) begin
                store_count = store_count + 1;
                if ((mem_waddr == 32'h8010_0000) &&
                    (mem_wen == 4'b1111) &&
                    (mem_wdata == 32'h0000_0344))
                    saw_sw = 1'b1;
                else if ((mem_waddr == 32'h8010_0002) &&
                         (mem_wen == 4'b1100) &&
                         (mem_wdata == 32'h0344_0000))
                    saw_sh = 1'b1;
                else if ((mem_waddr == 32'h8010_0001) &&
                         (mem_wen == 4'b0010) &&
                         (mem_wdata == 32'h0000_4400))
                    saw_sb = 1'b1;
                else
                    $fatal(1, "unexpected store addr=%08x wen=%x data=%08x",
                           mem_waddr, mem_wen, mem_wdata);
            end
        end
    end

endmodule
