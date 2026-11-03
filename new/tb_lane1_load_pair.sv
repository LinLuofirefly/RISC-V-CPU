`timescale 1ns / 1ps
`include "defines.v"

module tb_lane1_load_pair;
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

    localparam [31:0] MMIO_WORD = 32'h80ff_7f01;

    reg [31:0] rom [0:63];
    integer i;
    integer cycles = 0;
    integer swap_pair_count = 0;
    integer side_result_writes = 0;
    integer main_load_writes = 0;
    integer main_fallback_writes = 0;
    integer load_hold_cycles = 0;

    open_risc_v #(
        .ENABLE_REQUEST_STAGE_BP(1'b0),
        .ENABLE_DUAL_ISSUE(1'b1)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .inst_i(inst),
        .inst_next_i(inst_next),
        .ram_data_i(32'b0),
        .mmio_data_i(MMIO_WORD),
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

    function automatic [31:0] make_load;
        input [2:0]  func3;
        input [4:0]  rd;
        input [4:0]  rs1;
        input [11:0] imm;
        begin
            make_load = {imm, rs1, func3, rd, `INST_TYPE_L};
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

        rom[0]  = make_u(20'h80200, 5'd10, `INST_LUI);
        rom[1]  = `INST_NOP;

        rom[2]  = make_addi(5'd1, 5'd0, 12'd5);
        rom[3]  = make_load(`INST_LW, 5'd2, 5'd10, 12'd0);

        rom[4]  = make_addi(5'd3, 5'd1, 12'd1);
        rom[5]  = make_load(`INST_LB, 5'd4, 5'd10, 12'd1);

        rom[6]  = make_u(20'h00000, 5'd5, `INST_AUIPC);
        rom[7]  = make_load(`INST_LBU, 5'd6, 5'd10, 12'd2);

        // These older ALU instructions consume the previous pair's load,
        // forcing the swap bit and both instruction PCs through a replay.
        rom[8]  = make_addi(5'd7, 5'd6, 12'd1);
        rom[9]  = make_load(`INST_LH, 5'd8, 5'd10, 12'd2);

        rom[10] = make_addi(5'd9, 5'd8, 12'd1);
        rom[11] = make_load(`INST_LHU, 5'd11, 5'd10, 12'd0);

        rom[12] = make_addi(5'd31, 5'd0, 12'h07b);
        rom[13] = 32'h0000_006f; // jal x0, self

        repeat (6) @(posedge clk);
        rst_n = 1'b1;

        wait (dut.regs_inst.regs[31] === 32'h0000_007b);
        repeat (12) @(posedge clk);

        if (dut.regs_inst.regs[1] !== 32'd5)
            $fatal(1, "older ADDI result mismatch x1=%08x",
                   dut.regs_inst.regs[1]);
        if (dut.regs_inst.regs[2] !== MMIO_WORD)
            $fatal(1, "LW result mismatch x2=%08x",
                   dut.regs_inst.regs[2]);
        if (dut.regs_inst.regs[3] !== 32'd6)
            $fatal(1, "cross-pair side forwarding mismatch x3=%08x",
                   dut.regs_inst.regs[3]);
        if (dut.regs_inst.regs[4] !== 32'h0000_007f)
            $fatal(1, "LB result mismatch x4=%08x",
                   dut.regs_inst.regs[4]);
        if (dut.regs_inst.regs[5] !== 32'h8000_0018)
            $fatal(1, "swapped AUIPC PC mismatch x5=%08x",
                   dut.regs_inst.regs[5]);
        if (dut.regs_inst.regs[6] !== 32'h0000_00ff)
            $fatal(1, "LBU result mismatch x6=%08x",
                   dut.regs_inst.regs[6]);
        if (dut.regs_inst.regs[7] !== 32'h0000_0100)
            $fatal(1, "load-use side result mismatch x7=%08x",
                   dut.regs_inst.regs[7]);
        if (dut.regs_inst.regs[8] !== 32'hffff_80ff)
            $fatal(1, "LH result mismatch x8=%08x",
                   dut.regs_inst.regs[8]);
        if (dut.regs_inst.regs[9] !== 32'hffff_8100)
            $fatal(1, "second load-use result mismatch x9=%08x",
                   dut.regs_inst.regs[9]);
        if (dut.regs_inst.regs[11] !== 32'h0000_7f01)
            $fatal(1, "LHU result mismatch x11=%08x",
                   dut.regs_inst.regs[11]);
        if (swap_pair_count != 4)
            $fatal(1, "swapped load pair count mismatch count=%0d",
                   swap_pair_count);
        if (side_result_writes != 4)
            $fatal(1, "older side instructions retired %0d times",
                   side_result_writes);
        if (main_load_writes != 5)
            $fatal(1, "main-lane loads retired %0d times",
                   main_load_writes);
        if (main_fallback_writes != 1)
            $fatal(1, "held-response fallback retired %0d times",
                   main_fallback_writes);
        if (load_hold_cycles == 0)
            $fatal(1, "load-use replay path was not exercised");

        $display("TB_PASS swapped loads pairs=%0d side_writes=%0d load_writes=%0d fallback=%0d holds=%0d",
                 swap_pair_count, side_result_writes,
                 main_load_writes, main_fallback_writes,
                 load_hold_cycles);
        $finish;
    end

    always @(posedge clk) begin
        if (rst_n) begin
            cycles = cycles + 1;
            if (cycles > 1000)
                $fatal(1, "swapped load timeout pc=%08x", pc);

            if (dut.if_id_valid_o && dut.if_id_pair_valid_o &&
                dut.if_id_pair_swap_o && !dut.core_hold_flag) begin
                swap_pair_count = swap_pair_count + 1;
            end

            if (dut.if_id_pair_swap_o && dut.core_hold_flag)
                load_hold_cycles = load_hold_cycles + 1;

            if (dut.id_ex_valid_o && dut.id_ex_is_load_o &&
                (dut.id_ex_inst_addr_o[2:0] != 3'b100))
                $fatal(1, "swapped load carried wrong PC %08x",
                       dut.id_ex_inst_addr_o);

            if (dut.lane1_wb_valid &&
                ((dut.lane1_wb_rd == 5'd1) ||
                 (dut.lane1_wb_rd == 5'd3) ||
                 (dut.lane1_wb_rd == 5'd5) ||
                 (dut.lane1_wb_rd == 5'd7) ||
                 (dut.lane1_wb_rd == 5'd9)))
                side_result_writes = side_result_writes + 1;

            if (dut.lane1_idex_valid &&
                ((dut.lane1_idex_rd == 5'd1) ||
                 (dut.lane1_idex_rd == 5'd3) ||
                 (dut.lane1_idex_rd == 5'd5) ||
                 (dut.lane1_idex_rd == 5'd7)) &&
                !dut.lane1_idex_older)
                $fatal(1, "swapped older instruction lost age tag rd=%0d",
                       dut.lane1_idex_rd);

            if (dut.wb_rd_wen_o &&
                (dut.mem_wb_inst_o[6:0] == `INST_TYPE_L))
                main_load_writes = main_load_writes + 1;
            if (dut.wb_rd_wen_o && (dut.wb_rd_addr_o == 5'd9))
                main_fallback_writes = main_fallback_writes + 1;
        end
    end

endmodule
