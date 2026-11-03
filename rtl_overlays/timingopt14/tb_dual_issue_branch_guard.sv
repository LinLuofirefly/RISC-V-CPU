`timescale 1ns / 1ps
`include "defines.v"

module tb_dual_issue_branch_guard;
    reg  [2:0]  fetch_pc = 3'b000;
    reg  [31:0] inst0 = `INST_NOP;
    reg  [31:0] inst1 = `INST_NOP;
    wire        pair_default;
    wire        swap_default;
    wire        pair_branch_enabled;
    wire        swap_branch_enabled;

    dual_issue_pairing dut_default (
        .fetch_pc_i(fetch_pc),
        .inst0_i(inst0),
        .inst1_i(inst1),
        .pair_eligible_o(pair_default),
        .pair_swap_o(swap_default)
    );

    // Keep one explicit opt-in instance so this test also proves that the
    // branch class is controlled only by LANE0_CLASS_MASK[4].
    dual_issue_pairing #(
        .LANE0_CLASS_MASK(5'b1_1111)
    ) dut_branch_enabled (
        .fetch_pc_i(fetch_pc),
        .inst0_i(inst0),
        .inst1_i(inst1),
        .pair_eligible_o(pair_branch_enabled),
        .pair_swap_o(swap_branch_enabled)
    );

    function automatic [31:0] make_addi;
        input [4:0] rd;
        input [4:0] rs1;
        input [11:0] imm;
        begin
            make_addi = {imm, rs1, `INST_ADDI, rd, `INST_TYPE_I};
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

    function automatic [31:0] make_lw;
        input [4:0] rd;
        input [4:0] rs1;
        input [11:0] imm;
        begin
            make_lw = {imm, rs1, `INST_LW, rd, `INST_TYPE_L};
        end
    endfunction

    function automatic [31:0] make_beq;
        input [4:0] rs1;
        input [4:0] rs2;
        input [12:0] offset;
        begin
            make_beq = {offset[12], offset[10:5], rs2, rs1,
                        `INST_BEQ, offset[4:1], offset[11],
                        `INST_TYPE_B};
        end
    endfunction

    initial begin
        // Production default: an older branch must not carry a younger side
        // instruction. The opt-in instance confirms the pair is otherwise
        // legal and that the test is exercising the intended class guard.
        inst0 = make_beq(5'd1, 5'd2, 13'd8);
        inst1 = make_addi(5'd3, 5'd4, 12'd1);
        #1;
        if (pair_default || swap_default)
            $fatal(1, "branch paired with side lane under safe default");
        if (!pair_branch_enabled || swap_branch_enabled)
            $fatal(1, "branch class opt-in did not produce a normal pair");

        // Ordinary integer pairing remains enabled.
        inst0 = make_add(5'd6, 5'd1, 5'd2);
        inst1 = make_addi(5'd7, 5'd4, 12'd1);
        #1;
        if (!pair_default || swap_default)
            $fatal(1, "ordinary integer pair was disabled");

        // Older ALU + younger memory still uses the swapped memory path.
        inst0 = make_addi(5'd6, 5'd1, 12'd1);
        inst1 = make_lw(5'd7, 5'd4, 12'd0);
        #1;
        if (!pair_default || !swap_default)
            $fatal(1, "swapped load pair was disabled");

        // RAW protection and fetch alignment must remain intact.
        inst0 = make_addi(5'd6, 5'd1, 12'd1);
        inst1 = make_addi(5'd7, 5'd6, 12'd1);
        #1;
        if (pair_default)
            $fatal(1, "RAW-dependent pair was accepted");
        inst1 = make_addi(5'd7, 5'd4, 12'd1);
        fetch_pc = 3'b100;
        #1;
        if (pair_default)
            $fatal(1, "unaligned fetch pair was accepted");

        $display("TB_PASS branch guard and unaffected pair classes");
        $finish;
    end
endmodule
