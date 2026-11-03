`timescale 1ns / 1ps
`include "defines.v"

module tb_lane1_alu;
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

    integer checks = 0;

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

    function automatic [31:0] make_i;
        input [11:0] imm;
        input [2:0]  f3;
        begin
            make_i = {imm, 5'd1, f3, 5'd5, `INST_TYPE_I};
        end
    endfunction

    function automatic [31:0] make_addi_regs;
        input [4:0]  rd;
        input [4:0]  rs1;
        input [11:0] imm;
        begin
            make_addi_regs = {imm, rs1, `INST_ADDI, rd,
                              `INST_TYPE_I};
        end
    endfunction

    function automatic [31:0] make_r;
        input [6:0] f7;
        input [2:0] f3;
        begin
            make_r = {f7, 5'd2, 5'd1, f3, 5'd5,
                      `INST_TYPE_R_M};
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

    function automatic [31:0] make_load;
        input [2:0] func3;
        input [4:0] rd;
        begin
            make_load = {12'h004, 5'd1, func3, rd, `INST_TYPE_L};
        end
    endfunction

    function automatic [31:0] make_load_regs;
        input [2:0]  func3;
        input [4:0]  rd;
        input [4:0]  rs1;
        input [11:0] imm;
        begin
            make_load_regs = {imm, rs1, func3, rd, `INST_TYPE_L};
        end
    endfunction

    function automatic [31:0] make_store;
        input [2:0] func3;
        begin
            make_store = {7'b0, 5'd2, 5'd1, func3,
                          5'd5, `INST_TYPE_S};
        end
    endfunction

    function automatic [31:0] make_store_regs;
        input [2:0]  func3;
        input [4:0]  rs1;
        input [4:0]  rs2;
        input [11:0] imm;
        begin
            make_store_regs = {imm[11:5], rs2, rs1, func3,
                               imm[4:0], `INST_TYPE_S};
        end
    endfunction

    function automatic [31:0] make_branch;
        input [2:0] func3;
        input [4:0] rs1;
        input [4:0] rs2;
        input [12:0] offset;
        begin
            make_branch = {offset[12], offset[10:5], rs2, rs1,
                           func3, offset[4:1], offset[11],
                           `INST_TYPE_B};
        end
    endfunction

    task automatic check_supported;
        input [31:0] candidate;
        input        expected;
        begin
            // A lane-0 NOP has rd=x0, so it cannot create an artificial
            // intra-pair dependency with the candidate in lane 1.
            inst = `INST_NOP;
            inst_next = candidate;
            force dut.bp_fetch_pc_r = 32'h8000_0000;
            #1;
            checks = checks + 1;
            if (dut.fetch_pair_raw !== expected)
                $fatal(1,
                    "support mismatch inst=%08x got=%0b expected=%0b",
                    candidate, dut.fetch_pair_raw, expected);
            release dut.bp_fetch_pc_r;
        end
    endtask

    task automatic check_pair;
        input [31:0] lane0_inst;
        input [31:0] lane1_inst;
        input        expected;
        begin
            inst = lane0_inst;
            inst_next = lane1_inst;
            force dut.bp_fetch_pc_r = 32'h8000_0000;
            #1;
            checks = checks + 1;
            if (dut.fetch_pair_raw !== expected)
                $fatal(1,
                    "pair mismatch lane0=%08x lane1=%08x got=%0b expected=%0b",
                    lane0_inst, lane1_inst, dut.fetch_pair_raw, expected);
            release dut.bp_fetch_pc_r;
        end
    endtask

    task automatic check_pair_swap;
        input [31:0] lane0_inst;
        input [31:0] lane1_inst;
        input        expected_pair;
        input        expected_swap;
        begin
            inst = lane0_inst;
            inst_next = lane1_inst;
            force dut.bp_fetch_pc_r = 32'h8000_0000;
            #1;
            checks = checks + 1;
            if ((dut.fetch_pair_raw !== expected_pair) ||
                (dut.fetch_pair_swap_raw !== expected_swap))
                $fatal(1,
                    "swap mismatch inst0=%08x inst1=%08x pair=%0b/%0b swap=%0b/%0b",
                    lane0_inst, lane1_inst, dut.fetch_pair_raw,
                    expected_pair, dut.fetch_pair_swap_raw,
                    expected_swap);
            release dut.bp_fetch_pc_r;
        end
    endtask

    task automatic check_alu;
        input [2:0]  f3;
        input [6:0]  f7;
        input        is_imm;
        input [31:0] op1;
        input [31:0] op2;
        input [31:0] expected;
        begin
            force dut.dual_issue_lane_inst.lane1_idex_opcode =
                is_imm ? `INST_TYPE_I : `INST_TYPE_R_M;
            force dut.dual_issue_lane_inst.lane1_idex_func3 = f3;
            force dut.dual_issue_lane_inst.lane1_idex_func7 = f7;
            force dut.dual_issue_lane_inst.lane1_idex_is_imm = is_imm;
            force dut.dual_issue_lane_inst.lane1_idex_op1 = op1;
            force dut.dual_issue_lane_inst.lane1_idex_op2 = op2;
            #1;
            checks = checks + 1;
            if (dut.lane1_alu_result !== expected)
                $fatal(1,
                    "ALU mismatch f3=%0x f7=%0x imm=%0b a=%08x b=%08x got=%08x expected=%08x",
                    f3, f7, is_imm, op1, op2,
                    dut.lane1_alu_result, expected);
            release dut.dual_issue_lane_inst.lane1_idex_func3;
            release dut.dual_issue_lane_inst.lane1_idex_func7;
            release dut.dual_issue_lane_inst.lane1_idex_is_imm;
            release dut.dual_issue_lane_inst.lane1_idex_op1;
            release dut.dual_issue_lane_inst.lane1_idex_op2;
            release dut.dual_issue_lane_inst.lane1_idex_opcode;
        end
    endtask

    task automatic check_upper;
        input [6:0]  opcode;
        input [31:0] pc_value;
        input [31:0] upper_imm;
        input [31:0] expected;
        begin
            force dut.dual_issue_lane_inst.lane1_idex_opcode = opcode;
            force dut.dual_issue_lane_inst.lane1_idex_pc = pc_value;
            force dut.dual_issue_lane_inst.lane1_idex_u_imm = upper_imm;
            #1;
            checks = checks + 1;
            if (dut.lane1_alu_result !== expected)
                $fatal(1,
                    "upper mismatch opcode=%02x pc=%08x imm=%08x got=%08x expected=%08x",
                    opcode, pc_value, upper_imm,
                    dut.lane1_alu_result, expected);
            release dut.dual_issue_lane_inst.lane1_idex_opcode;
            release dut.dual_issue_lane_inst.lane1_idex_pc;
            release dut.dual_issue_lane_inst.lane1_idex_u_imm;
        end
    endtask

    initial begin
        // Complete legal RV32I OP-IMM set.
        check_supported(make_i(12'hfff, `INST_ADDI),  1'b1);
        check_supported(make_i(12'hfff, `INST_SLTI),  1'b1);
        check_supported(make_i(12'hfff, `INST_SLTIU), 1'b1);
        check_supported(make_i(12'hfff, `INST_XORI),  1'b1);
        check_supported(make_i(12'hfff, `INST_ORI),   1'b1);
        check_supported(make_i(12'hfff, `INST_ANDI),  1'b1);
        check_supported(make_i({`INST_FUNC7_R, 5'd31},
                               `INST_SLLI), 1'b1);
        check_supported(make_i({`INST_FUNC7_R, 5'd31},
                               `INST_SRI), 1'b1);
        check_supported(make_i({`INST_FUNC7_SUB, 5'd31},
                               `INST_SRI), 1'b1);

        // Complete legal RV32I OP set.
        check_supported(make_r(`INST_FUNC7_R,   `INST_ADD_SUB), 1'b1);
        check_supported(make_r(`INST_FUNC7_SUB, `INST_ADD_SUB), 1'b1);
        check_supported(make_r(`INST_FUNC7_R,   `INST_SLL),  1'b1);
        check_supported(make_r(`INST_FUNC7_R,   `INST_SLT),  1'b1);
        check_supported(make_r(`INST_FUNC7_R,   `INST_SLTU), 1'b1);
        check_supported(make_r(`INST_FUNC7_R,   `INST_XOR),  1'b1);
        check_supported(make_r(`INST_FUNC7_R,   `INST_SR),   1'b1);
        check_supported(make_r(`INST_FUNC7_SUB, `INST_SR),   1'b1);
        check_supported(make_r(`INST_FUNC7_R,   `INST_OR),   1'b1);
        check_supported(make_r(`INST_FUNC7_R,   `INST_AND),  1'b1);
        check_supported(make_u(20'h12345, 5'd5, `INST_LUI),   1'b1);
        check_supported(make_u(20'h12345, 5'd5, `INST_AUIPC), 1'b1);

        // RV32M is not implemented in Lane 1; reserved shift/register
        // encodings are rejected entirely.
        check_supported(make_r(`INST_FUNC7_M, `INST_ADD_SUB), 1'b0);
        check_supported(make_r(7'b0100000, `INST_SLL), 1'b0);
        check_supported(make_i({7'b0100000, 5'd1}, `INST_SLLI), 1'b0);
        check_supported(make_i({7'b0000001, 5'd1}, `INST_SRI), 1'b0);

        // Lane 0 may use the full non-control, non-system pipeline while the
        // younger instruction remains side-effect-free and independent.
        check_pair(make_load(`INST_LW, 5'd6),
                   make_i(12'd1, `INST_ADDI), 1'b1);
        check_pair(make_load(`INST_LW, 5'd1),
                   make_i(12'd1, `INST_ADDI), 1'b0); // RAW
        check_pair(make_load(`INST_LW, 5'd5),
                   make_i(12'd1, `INST_ADDI), 1'b0); // WAW
        check_pair(make_load(3'b011, 5'd6),
                   make_i(12'd1, `INST_ADDI), 1'b0); // reserved load
        check_pair(make_store(`INST_SW),
                   make_i(12'd1, `INST_ADDI), 1'b1);
        check_pair(make_store(3'b011),
                   make_i(12'd1, `INST_ADDI), 1'b0); // reserved store
        check_pair(make_u(20'h12345, 5'd6, `INST_LUI),
                   make_i(12'd1, `INST_ADDI), 1'b1);
        check_pair(make_u(20'h12345, 5'd6, `INST_AUIPC),
                   make_i(12'd1, `INST_ADDI), 1'b1);
        // U-type immediate bits are not source-register addresses.
        check_pair(make_load(`INST_LW, 5'd6),
                   make_u(20'h00030, 5'd5, `INST_LUI), 1'b1);
        check_pair(make_branch(`INST_BEQ, 5'd1, 5'd2, 13'd8),
                   make_i(12'd1, `INST_ADDI), 1'b1);
        check_pair(make_branch(`INST_BNE, 5'd1, 5'd2, 13'd8),
                   make_i(12'd1, `INST_ADDI), 1'b1);
        check_pair(make_branch(`INST_BLT, 5'd1, 5'd2, 13'd8),
                   make_i(12'd1, `INST_ADDI), 1'b1);
        check_pair(make_branch(`INST_BGE, 5'd1, 5'd2, 13'd8),
                   make_i(12'd1, `INST_ADDI), 1'b1);
        check_pair(make_branch(`INST_BLTU, 5'd1, 5'd2, 13'd8),
                   make_i(12'd1, `INST_ADDI), 1'b1);
        check_pair(make_branch(`INST_BGEU, 5'd1, 5'd2, 13'd8),
                   make_i(12'd1, `INST_ADDI), 1'b1);
        check_pair(make_branch(3'b010, 5'd1, 5'd2, 13'd8),
                   make_i(12'd1, `INST_ADDI), 1'b0);
        check_pair(make_branch(3'b011, 5'd1, 5'd2, 13'd8),
                   make_i(12'd1, `INST_ADDI), 1'b0);

        // A younger load is steered into the full main lane while its older
        // independent ALU instruction moves to the side lane.
        check_pair_swap(make_addi_regs(5'd6, 5'd7, 12'd1),
                        make_load_regs(`INST_LW, 5'd8, 5'd9, 12'd0),
                        1'b1, 1'b1);
        check_pair_swap(make_addi_regs(5'd9, 5'd7, 12'd1),
                        make_load_regs(`INST_LW, 5'd8, 5'd9, 12'd0),
                        1'b0, 1'b0); // RAW
        check_pair_swap(make_addi_regs(5'd8, 5'd7, 12'd1),
                        make_load_regs(`INST_LW, 5'd8, 5'd9, 12'd0),
                        1'b0, 1'b0); // WAW
        check_pair_swap(make_addi_regs(5'd6, 5'd7, 12'd1),
                        make_load_regs(3'b011, 5'd8, 5'd9, 12'd0),
                        1'b0, 1'b0); // reserved load
        check_pair_swap(make_load_regs(`INST_LW, 5'd6, 5'd7, 12'd0),
                        make_load_regs(`INST_LW, 5'd8, 5'd9, 12'd0),
                        1'b0, 1'b0); // two memory operations

        // Store uses both rs1 (address) and rs2 (data), and has no rd despite
        // the S-immediate bits occupying the instruction's [11:7] field.
        check_pair_swap(make_addi_regs(5'd6, 5'd7, 12'd1),
                        make_store_regs(`INST_SW, 5'd9, 5'd8, 12'd0),
                        1'b1, 1'b1);
        check_pair_swap(make_addi_regs(5'd9, 5'd7, 12'd1),
                        make_store_regs(`INST_SW, 5'd9, 5'd8, 12'd0),
                        1'b0, 1'b0); // RAW address
        check_pair_swap(make_addi_regs(5'd8, 5'd7, 12'd1),
                        make_store_regs(`INST_SW, 5'd9, 5'd8, 12'd0),
                        1'b0, 1'b0); // RAW data
        check_pair_swap(make_addi_regs(5'd6, 5'd7, 12'd1),
                        make_store_regs(3'b011, 5'd9, 5'd8, 12'd0),
                        1'b0, 1'b0); // reserved store
        check_pair_swap(make_load_regs(`INST_LW, 5'd6, 5'd7, 12'd0),
                        make_store_regs(`INST_SW, 5'd9, 5'd8, 12'd0),
                        1'b0, 1'b0); // two memory operations

        // The complete RV32M set may occupy Lane 0 beside one independent
        // RV32I integer instruction.  RAW and WAW pairs remain forbidden.
        check_pair(make_r(`INST_FUNC7_M, `INST_MUL),
                   make_addi_regs(5'd6, 5'd7, 12'd1), 1'b1);
        check_pair(make_r(`INST_FUNC7_M, `INST_MULH),
                   make_addi_regs(5'd6, 5'd7, 12'd1), 1'b1);
        check_pair(make_r(`INST_FUNC7_M, `INST_MULHSU),
                   make_addi_regs(5'd6, 5'd7, 12'd1), 1'b1);
        check_pair(make_r(`INST_FUNC7_M, `INST_MULHU),
                   make_addi_regs(5'd6, 5'd7, 12'd1), 1'b1);
        check_pair(make_r(`INST_FUNC7_M, `INST_DIV),
                   make_addi_regs(5'd6, 5'd7, 12'd1), 1'b1);
        check_pair(make_r(`INST_FUNC7_M, `INST_DIVU),
                   make_addi_regs(5'd6, 5'd7, 12'd1), 1'b1);
        check_pair(make_r(`INST_FUNC7_M, `INST_REM),
                   make_addi_regs(5'd6, 5'd7, 12'd1), 1'b1);
        check_pair(make_r(`INST_FUNC7_M, `INST_REMU),
                   make_addi_regs(5'd6, 5'd7, 12'd1), 1'b1);
        check_pair(make_r(`INST_FUNC7_M, `INST_DIV),
                   make_addi_regs(5'd6, 5'd5, 12'd1), 1'b0); // RAW
        check_pair(make_r(`INST_FUNC7_M, `INST_DIV),
                   make_addi_regs(5'd5, 5'd7, 12'd1), 1'b0); // WAW

        // Arithmetic/logic result edge cases shared by OP-IMM and OP.
        check_alu(`INST_ADD_SUB, `INST_FUNC7_R, 1'b1,
                  32'h7fff_ffff, 32'd1, 32'h8000_0000);
        check_alu(`INST_ADD_SUB, `INST_FUNC7_R, 1'b0,
                  32'hffff_ffff, 32'd1, 32'h0000_0000);
        check_alu(`INST_ADD_SUB, `INST_FUNC7_SUB, 1'b0,
                  32'h0000_0000, 32'd1, 32'hffff_ffff);
        check_alu(`INST_SLT, `INST_FUNC7_R, 1'b0,
                  32'h8000_0000, 32'h7fff_ffff, 32'd1);
        check_alu(`INST_SLTU, `INST_FUNC7_R, 1'b0,
                  32'h8000_0000, 32'h7fff_ffff, 32'd0);
        check_alu(`INST_XOR, `INST_FUNC7_R, 1'b0,
                  32'ha5a5_5a5a, 32'hffff_0000, 32'h5a5a_5a5a);
        check_alu(`INST_OR, `INST_FUNC7_R, 1'b0,
                  32'ha5a5_0000, 32'h0000_5a5a, 32'ha5a5_5a5a);
        check_alu(`INST_AND, `INST_FUNC7_R, 1'b0,
                  32'ha5a5_5a5a, 32'hffff_0000, 32'ha5a5_0000);
        check_alu(`INST_SLL, `INST_FUNC7_R, 1'b0,
                  32'h0000_0001, 32'd31, 32'h8000_0000);
        check_alu(`INST_SR, `INST_FUNC7_R, 1'b0,
                  32'h8000_0000, 32'd31, 32'h0000_0001);
        check_alu(`INST_SR, `INST_FUNC7_SUB, 1'b0,
                  32'h8000_0000, 32'd31, 32'hffff_ffff);
        check_upper(`INST_LUI, 32'h8000_0104,
                    32'h1234_5000, 32'h1234_5000);
        check_upper(`INST_AUIPC, 32'h8000_0104,
                    32'h1234_5000, 32'h9234_5104);

        $display("TB_PASS lane1 RV32I ALU checks=%0d", checks);
        $finish;
    end
endmodule
