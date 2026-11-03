`timescale 1ns / 1ps
`include "defines.v"

module tb_lane1_rv32m_pair;
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
    integer rv32m_pair_count = 0;
    integer rv32m_wait_cycles = 0;
    integer lane1_x3_writes = 0;
    integer lane1_x4_writes = 0;
    integer fast_mul_writes = 0;
    reg rv32m_done_seen = 1'b0;
    reg fast_mul_seen = 1'b0;

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

    function automatic [31:0] make_rv32m;
        input [2:0] func3;
        input [4:0] rd;
        input [4:0] rs1;
        input [4:0] rs2;
        begin
            make_rv32m = {`INST_FUNC7_M, rs2, rs1, func3, rd,
                          `INST_TYPE_R_M};
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

        rom[0] = make_addi(5'd1, 5'd0, 12'd100);
        rom[1] = make_addi(5'd2, 5'd0, 12'd7);
        rom[2] = make_addi(5'd3, 5'd0, 12'd0);
        rom[3] = make_addi(5'd4, 5'd0, 12'd0);

        // Compiler-generated low-half MUL uses the fast DSP path.  It and its
        // independent side instruction must both advance without MDU hold.
        rom[4] = make_rv32m(`INST_MUL, 5'd8, 5'd1, 5'd2);
        rom[5] = make_addi(5'd4, 5'd4, 12'd1);

        // A long DIV still holds Lane 0 EX for more than sixty cycles.  The
        // paired x3 increment waits there and retires exactly once with DIV.
        rom[6] = make_rv32m(`INST_DIV, 5'd5, 5'd1, 5'd2);
        rom[7] = make_addi(5'd3, 5'd3, 12'd1);

        // Both instructions consume the just-completed pair, covering main
        // and side forwarding on the RV32M release cycle.
        rom[8] = make_addi(5'd6, 5'd5, 12'd1);
        rom[9] = make_addi(5'd7, 5'd3, 12'd1);
        rom[10] = make_addi(5'd31, 5'd0, 12'h07b);
        rom[11] = 32'h0000_006f; // jal x0, self

        repeat (6) @(posedge clk);
        rst_n = 1'b1;

        wait (dut.regs_inst.regs[31] === 32'h0000_007b);
        repeat (12) @(posedge clk);

        if (dut.regs_inst.regs[5] !== 32'd14)
            $fatal(1, "DIV result mismatch x5=%08x",
                   dut.regs_inst.regs[5]);
        if (dut.regs_inst.regs[3] !== 32'd1)
            $fatal(1, "paired Lane-1 result mismatch x3=%08x",
                   dut.regs_inst.regs[3]);
        if (dut.regs_inst.regs[6] !== 32'd15)
            $fatal(1, "main release forwarding mismatch x6=%08x",
                   dut.regs_inst.regs[6]);
        if (dut.regs_inst.regs[7] !== 32'd2)
            $fatal(1, "side release forwarding mismatch x7=%08x",
                   dut.regs_inst.regs[7]);
        if (dut.regs_inst.regs[8] !== 32'd700)
            $fatal(1, "fast MUL result mismatch x8=%08x",
                   dut.regs_inst.regs[8]);
        if (dut.regs_inst.regs[4] !== 32'd1)
            $fatal(1, "fast MUL side result mismatch x4=%08x",
                   dut.regs_inst.regs[4]);
        if (rv32m_pair_count < 2)
            $fatal(1, "both fast MUL and iterative DIV pairs were not issued count=%0d",
                   rv32m_pair_count);
        if (rv32m_wait_cycles < 60)
            $fatal(1, "long-latency RV32M wait not exercised cycles=%0d",
                   rv32m_wait_cycles);
        if (lane1_x3_writes != 1)
            $fatal(1, "paired Lane-1 instruction retired %0d times",
                   lane1_x3_writes);
        if (!fast_mul_seen || (fast_mul_writes != 1) ||
            (lane1_x4_writes != 1))
            $fatal(1, "fast MUL retirement mismatch seen=%0b main=%0d side=%0d",
                   fast_mul_seen, fast_mul_writes, lane1_x4_writes);

        $display("TB_PASS RV32M fast_mul=%0d waits=%0d lane1_writes=%0d pairs=%0d",
                 fast_mul_writes, rv32m_wait_cycles,
                 lane1_x3_writes + lane1_x4_writes, rv32m_pair_count);
        $finish;
    end

    always @(posedge clk) begin
        if (rst_n) begin
            cycles = cycles + 1;
            if (cycles > 1000)
                $fatal(1, "RV32M pair timeout pc=%08x x3=%08x x5=%08x",
                       pc, dut.regs_inst.regs[3],
                       dut.regs_inst.regs[5]);

            if (dut.if_id_valid_o && dut.if_id_pair_valid_o &&
                dut.id_dec_is_rv32m_o && !dut.core_hold_flag)
                rv32m_pair_count = rv32m_pair_count + 1;

            if (dut.ex_rv32m_busy_o && !dut.ex_rv32m_done_o)
                rv32m_wait_cycles = rv32m_wait_cycles + 1;
            if (dut.ex_rv32m_done_o)
                rv32m_done_seen = 1'b1;

            if (dut.lane1_exmem_valid &&
                (dut.lane1_exmem_rd == 5'd3) &&
                dut.ex_rv32m_busy_o && !dut.ex_rv32m_done_o)
                $fatal(1, "Lane-1 escaped EX before RV32M completion");

            if (dut.lane1_wb_valid && (dut.lane1_wb_rd == 5'd3)) begin
                if (!rv32m_done_seen)
                    $fatal(1, "Lane-1 retired before RV32M completion");
                lane1_x3_writes = lane1_x3_writes + 1;
            end
            if (dut.id_ex_valid_o && dut.id_ex_is_rv32m_o &&
                (dut.id_ex_func3_o == `INST_MUL)) begin
                fast_mul_seen = 1'b1;
                if (dut.ex_inst.rv32m_iter_busy_w)
                    $fatal(1, "fast MUL entered iterative busy path");
            end
            if (dut.wb_rd_wen_o && (dut.wb_rd_addr_o == 5'd8))
                fast_mul_writes = fast_mul_writes + 1;
            if (dut.lane1_wb_valid && (dut.lane1_wb_rd == 5'd4) &&
                (dut.lane1_wb_data == 32'd1))
                lane1_x4_writes = lane1_x4_writes + 1;
        end
    end

endmodule
