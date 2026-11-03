`timescale 1ns / 1ps
`include "defines.v"

// Exercise resident cache lines whose compact tags alias MMIO and both DRAM
// boundaries. The CPU must use the uncached operand for each outside load.
module tb_compact_cache_region;
    reg clk = 0;
    reg rst_n = 0;
    reg [31:0] inst = `INST_NOP, inst_next = `INST_NOP;
    wire [31:0] irom_addr;
    reg [31:0] rom [0:63];
    integer cycles = 0;
    integer clean_branch_bypass = 0;
    integer i;
    open_risc_v #(.ENABLE_DUAL_ISSUE(1'b0)) dut (
        .clk(clk), .rst_n(rst_n), .inst_i(inst), .inst_next_i(inst_next),
        .ram_data_i(32'd37), .mmio_data_i(32'd0), .timer_irq_i(1'b0),
        .irom_addr_o(irom_addr)
    );
    always #5 clk = ~clk;
    always @(posedge clk) begin
        inst <= rst_n ? rom[irom_addr[7:2]] : `INST_NOP;
        inst_next <= rst_n ? rom[irom_addr[7:2] + 6'd1] : `INST_NOP;
        if (rst_n) begin
            cycles <= cycles + 1;
            if (cycles > 1000) $fatal(1, "region test timeout");
            if (dut.id_dec_is_branch_o && dut.ex_load_late_bypass_allowed)
                clean_branch_bypass <= clean_branch_bypass + 1;
        end
    end
    function automatic [31:0] addi(input [4:0] rd, rs1, input [11:0] imm);
        addi = {imm, rs1, 3'b000, rd, 7'b0010011};
    endfunction
    function automatic [31:0] lw(input [4:0] rd, rs1, input [11:0] imm);
        lw = {imm, rs1, 3'b010, rd, 7'b0000011};
    endfunction
    function automatic [31:0] branch(input [4:0] rs1, rs2,
                                    input [2:0] funct3, input [12:0] imm);
        branch = {imm[12], imm[10:5], rs2, rs1, funct3,
                  imm[4:1], imm[11], 7'b1100011};
    endfunction
    initial begin
        for (i = 0; i < 64; i = i + 1) rom[i] = `INST_NOP;
        rom[0] = {20'h80100, 5'd10, 7'b0110111};
        rom[1] = {20'h80200, 5'd11, 7'b0110111};
        rom[2] = addi(3, 0, 37);
        rom[6] = lw(4, 10, 0); // Warm the first line, which aliases MMIO.
        rom[11] = lw(5, 10, 0);
        rom[16] = lw(7, 11, 0);
        rom[17] = branch(7, 0, 3'b001, (60-17)*4);
        rom[18] = {20'h80140, 5'd12, 7'b0110111};
        rom[19] = addi(12, 12, 12'hffc);
        rom[23] = lw(8, 12, 0); // Warm the last line, aliasing base-4.
        rom[28] = lw(9, 10, 12'hffc);
        rom[29] = branch(9, 0, 3'b001, (60-29)*4);
        rom[30] = lw(13, 12, 4);
        rom[31] = branch(13, 0, 3'b001, (60-31)*4);
        rom[32] = lw(14, 10, 0);
        rom[33] = branch(14, 3, 3'b001, (60-33)*4);
        rom[34] = lw(15, 12, 0);
        rom[35] = branch(15, 3, 3'b001, (60-35)*4);
        rom[36] = {20'h80101, 5'd16, 7'b0110111};
        rom[40] = lw(17, 16, 0);
        rom[45] = lw(18, 16, 0);
        rom[46] = branch(18, 3, 3'b001, (60-46)*4);
        rom[47] = addi(31, 0, 123);
        rom[48] = 32'h0000006f;
        rom[60] = addi(30, 0, 1);
        rom[61] = addi(31, 0, 123);
        rom[62] = 32'h0000006f;
        repeat (6) @(negedge clk);
        rst_n = 1;
        wait (dut.regs_inst.regs[31] === 32'd123);
        repeat (10) @(negedge clk);
        if (dut.regs_inst.regs[30] !== 0 ||
            dut.regs_inst.regs[7] !== 0 || dut.regs_inst.regs[9] !== 0 ||
            dut.regs_inst.regs[13] !== 0 || dut.regs_inst.regs[14] !== 37 ||
            dut.regs_inst.regs[15] !== 37 || dut.regs_inst.regs[18] !== 37)
            $fatal(1, "cache/MMIO region alias corrupted a load or branch");
        if (clean_branch_bypass == 0) $fatal(1, "clean branch bypass not exercised");
        $display("TB_PASS compact cache MMIO and DRAM boundary aliases; bypass=%0d", clean_branch_bypass);
        $finish;
    end
endmodule
