`timescale 1ns / 1ps
`include "defines.v"

module tb_load_rv32m_dependency;
    reg         clk = 1'b0;
    reg         rst_n = 1'b0;
    reg  [31:0] inst = `INST_NOP;
    reg  [31:0] inst_next = `INST_NOP;
    wire [31:0] pc;
    wire [31:0] irom_addr;

    localparam [31:0] MMIO_WORD = 32'd6;

    reg [31:0] rom [0:31];
    integer i;
    integer cycles = 0;
    integer dependency_holds = 0;

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
        .mem_rd_reg_o(),
        .mem_rd_addr_o(),
        .w_en(),
        .w_addr_i(),
        .w_data_i()
    );

    always #5 clk = ~clk;

    function automatic [31:0] make_addi;
        input [4:0] rd;
        input [4:0] rs1;
        input [11:0] imm;
        begin
            make_addi = {imm, rs1, `INST_ADDI, rd, `INST_TYPE_I};
        end
    endfunction

    function automatic [31:0] make_lui;
        input [19:0] imm;
        input [4:0] rd;
        begin
            make_lui = {imm, rd, `INST_LUI};
        end
    endfunction

    function automatic [31:0] make_lw;
        input [4:0] rd;
        input [4:0] rs1;
        input [11:0] imm;
        begin
            make_lw = {imm, rs1, `INST_LW, rd, `INST_TYPE_L};
        end
    endfunction

    function automatic [31:0] make_mul;
        input [4:0] rd;
        input [4:0] rs1;
        input [4:0] rs2;
        begin
            make_mul = {`INST_FUNC7_M, rs2, rs1, `INST_MUL, rd,
                        `INST_TYPE_R_M};
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

        rom[0] = make_lui(20'h80200, 5'd10);
        rom[1] = `INST_NOP;
        rom[2] = make_addi(5'd2, 5'd0, 12'd7);
        rom[3] = `INST_NOP;
        rom[4] = make_lw(5'd1, 5'd10, 12'd0);
        rom[5] = make_mul(5'd3, 5'd1, 5'd2);
        rom[6] = make_addi(5'd31, 5'd0, 12'h07b);
        rom[7] = 32'h0000_006f;

        repeat (6) @(posedge clk);
        rst_n = 1'b1;

        wait (dut.regs_inst.regs[31] === 32'h0000_007b);
        repeat (12) @(posedge clk);

        if (dut.regs_inst.regs[1] !== MMIO_WORD)
            $fatal(1, "load result mismatch x1=%08x", dut.regs_inst.regs[1]);
        if (dut.regs_inst.regs[3] !== 32'd42)
            $fatal(1, "load-to-MUL result mismatch x3=%08x",
                   dut.regs_inst.regs[3]);
        if (dependency_holds == 0)
            $fatal(1, "load-to-RV32M dependency was not stalled");

        $display("TB_PASS load-to-RV32M result=%0d holds=%0d",
                 dut.regs_inst.regs[3], dependency_holds);
        $finish;
    end

    always @(posedge clk) begin
        if (rst_n) begin
            cycles = cycles + 1;
            if (cycles > 300)
                $fatal(1, "load-to-RV32M timeout pc=%08x", pc);

            if (dut.id_dec_is_rv32m_o && dut.hdu_hold_flag_o)
                dependency_holds = dependency_holds + 1;

            if (dut.id_ex_valid_o && dut.id_ex_is_rv32m_o &&
                ((dut.id_ex_rs1_fwd_sel_o == 3'd3) ||
                 (dut.id_ex_rs2_fwd_sel_o == 3'd3)))
                $fatal(1, "RV32M reached EX with speculative late-load select");
        end
    end
endmodule
