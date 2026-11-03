`timescale 1ns / 1ps
`include "defines.v"

module tb_lane1_memory_precise;
    localparam [31:0] RESET_PC = 32'h8000_0000;
    localparam [31:0] LOAD_PC  = RESET_PC + 32'h0000_0034;
    localparam [31:0] STORE_PC = RESET_PC + 32'h0000_0044;
    localparam [31:0] HANDLER_PC = RESET_PC + 32'h0000_0100;
    localparam [31:0] MMIO_WORD = 32'h89ab_cdef;

    reg         clk = 1'b0;
    reg         rst_n = 1'b0;
    reg         timer_irq = 1'b0;
    reg  [31:0] inst = `INST_NOP;
    reg  [31:0] inst_next = `INST_NOP;
    wire [31:0] pc;
    wire [31:0] irom_addr;
    wire        mem_rd;
    wire [31:0] mem_rd_addr;
    wire [3:0]  mem_wen;
    wire [31:0] mem_waddr;
    wire [31:0] mem_wdata;

    reg [31:0] rom [0:127];
    integer i;
    integer cycles = 0;
    integer intended_swap_pairs = 0;
    integer wrong_path_swap_pairs = 0;
    integer trap_count = 0;
    integer mret_count = 0;
    integer older_side_writes = 0;
    integer load_writes = 0;
    integer store_writes = 0;
    integer mepc_reads = 0;
    reg [31:0] first_mepc_read = 32'b0;
    reg [31:0] second_mepc_read = 32'b0;
    reg irq1_fired = 1'b0;
    reg irq2_fired = 1'b0;

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
        .timer_irq_i(timer_irq),
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

    function automatic [31:0] make_csr;
        input [11:0] csr_addr;
        input [4:0]  rd;
        input [4:0]  rs1;
        input [2:0]  func3;
        begin
            make_csr = {csr_addr, rs1, func3, rd, `INST_SYSTEM};
        end
    endfunction

    function automatic [31:0] make_branch;
        input [2:0]  func3;
        input [4:0]  rs1;
        input [4:0]  rs2;
        input [12:0] imm;
        begin
            make_branch = {imm[12], imm[10:5], rs2, rs1, func3,
                           imm[4:1], imm[11], `INST_TYPE_B};
        end
    endfunction

    always @(posedge clk) begin
        if (!rst_n) begin
            inst      <= `INST_NOP;
            inst_next <= `INST_NOP;
        end else begin
            inst      <= rom[irom_addr[8:2]];
            inst_next <= rom[irom_addr[8:2] + 7'd1];
        end
    end

    // Pulse the interrupt for exactly the active edge at which each swapped
    // memory instruction is in EX.  The older ALU companion must retire, while
    // the younger memory operation is canceled and replayed from mepc.
    always @(negedge clk) begin
        if (!rst_n) begin
            timer_irq <= 1'b0;
            irq1_fired <= 1'b0;
            irq2_fired <= 1'b0;
        end else if (timer_irq) begin
            timer_irq <= 1'b0;
        end else if (!irq1_fired && dut.id_ex_valid_o &&
                     dut.id_ex_is_load_o &&
                     (dut.id_ex_inst_addr_o == LOAD_PC) &&
                     dut.lane1_idex_valid && dut.lane1_idex_older) begin
            timer_irq <= 1'b1;
            irq1_fired <= 1'b1;
        end else if (irq1_fired && !irq2_fired &&
                     (trap_count == 1) && (mret_count == 1) &&
                     dut.id_ex_valid_o && dut.id_ex_is_store_o &&
                     (dut.id_ex_inst_addr_o == STORE_PC) &&
                     dut.lane1_idex_valid && dut.lane1_idex_older) begin
            timer_irq <= 1'b1;
            irq2_fired <= 1'b1;
        end
    end

    initial begin
        for (i = 0; i < 128; i = i + 1)
            rom[i] = `INST_NOP;

        // Configure a direct-mode machine timer handler at 0x8000_0100.
        rom[0] = make_u(20'h80000, 5'd5, `INST_LUI);
        rom[1] = make_addi(5'd5, 5'd5, 12'h100);
        rom[2] = make_csr(`CSR_MTVEC, 5'd0, 5'd5, `INST_CSRRW);
        rom[3] = make_addi(5'd6, 5'd0, 12'd128);
        rom[4] = make_csr(`CSR_MIE, 5'd0, 5'd6, `INST_CSRRW);
        rom[5] = make_addi(5'd7, 5'd0, 12'd8);
        rom[6] = make_csr(`CSR_MSTATUS, 5'd0, 5'd7, `INST_CSRRW);
        rom[7] = `INST_NOP;

        rom[8] = make_u(20'h80200, 5'd10, `INST_LUI);
        rom[9] = make_addi(5'd12, 5'd0, 12'h345);
        rom[10] = `INST_NOP;
        // A read-only CSR instruction is an intentional non-pairing boundary.
        // It keeps the following ALU+Load age relationship deterministic even
        // when pairs are allowed to begin at PC[2:0] == 3'b100.
        rom[11] = make_csr(`CSR_MSTATUS, 5'd0, 5'd0, `INST_CSRRS);

        // Interrupt 1: x1 is older and must commit. LW is younger, must be
        // canceled, and then must retire once after mret replays LOAD_PC.
        rom[12] = make_addi(5'd1, 5'd0, 12'h011);
        rom[13] = make_load(`INST_LW, 5'd2, 5'd10, 12'd0);
        // Keep the packet after the replayed load independent.  A deliberate
        // load-use hold would conservatively serialize the following IROM
        // response and would no longer exercise a swapped Store in EX.
        rom[14] = make_addi(5'd9, 5'd0, 12'd9);
        rom[15] = make_csr(`CSR_MSTATUS, 5'd0, 5'd0, `INST_CSRRS);

        // Interrupt 2 applies the same age rule to a store.  There must be no
        // write strobe before mret; the replayed STORE_PC writes exactly once.
        rom[16] = make_addi(5'd4, 5'd0, 12'h022);
        rom[17] = make_store(`INST_SW, 5'd10, 5'd12, 12'd4);
        rom[18] = make_addi(5'd3, 5'd2, 12'd1);
        rom[19] = `INST_NOP;

        // A taken branch first kills its paired PC+4 ALU instruction, then
        // flushes a sequential wrong-path swapped Store packet.
        rom[20] = make_branch(`INST_BEQ, 5'd0, 5'd0, 13'd16);
        rom[21] = make_addi(5'd13, 5'd0, 12'h123);
        rom[22] = make_addi(5'd14, 5'd0, 12'h055);
        rom[23] = make_store(`INST_SW, 5'd10, 5'd12, 12'd8);
        rom[24] = make_addi(5'd15, 5'd0, 12'h066);
        rom[25] = `INST_NOP;

        // Repeat for a wrong-path swapped Load packet.
        rom[26] = make_branch(`INST_BEQ, 5'd0, 5'd0, 13'd16);
        rom[27] = make_addi(5'd16, 5'd0, 12'h124);
        rom[28] = make_addi(5'd17, 5'd0, 12'h077);
        rom[29] = make_load(`INST_LW, 5'd18, 5'd10, 12'd0);
        rom[30] = make_addi(5'd31, 5'd0, 12'h07b);
        rom[31] = 32'h0000_006f;

        // The handler exposes mepc/mcause to the test and counts entries.
        rom[64] = make_csr(`CSR_MEPC, 5'd20, 5'd0, `INST_CSRRS);
        rom[65] = make_csr(`CSR_MCAUSE, 5'd21, 5'd0, `INST_CSRRS);
        rom[66] = make_addi(5'd28, 5'd28, 12'd1);
        rom[67] = `INST_MRET;

        repeat (6) @(posedge clk);
        rst_n = 1'b1;

        wait (dut.regs_inst.regs[31] === 32'h0000_007b);
        repeat (16) @(posedge clk);

        if (!irq1_fired || !irq2_fired || (trap_count != 2))
            $fatal(1, "timer coverage mismatch irq1=%0b irq2=%0b traps=%0d",
                   irq1_fired, irq2_fired, trap_count);
        if (mret_count != 2 || dut.regs_inst.regs[28] !== 32'd2)
            $fatal(1, "handler return mismatch mret=%0d entries=%08x",
                   mret_count, dut.regs_inst.regs[28]);
        if ((mepc_reads != 2) || (first_mepc_read != LOAD_PC) ||
            (second_mepc_read != STORE_PC))
            $fatal(1, "mepc replay mismatch reads=%0d first=%08x second=%08x",
                   mepc_reads, first_mepc_read, second_mepc_read);
        if (dut.regs_inst.regs[21] !== 32'h8000_0007)
            $fatal(1, "timer mcause mismatch %08x", dut.regs_inst.regs[21]);
        if (dut.regs_inst.regs[1] !== 32'h0000_0011 ||
            dut.regs_inst.regs[4] !== 32'h0000_0022 ||
            (older_side_writes != 2))
            $fatal(1, "older side retirement mismatch x1=%08x x4=%08x writes=%0d",
                   dut.regs_inst.regs[1], dut.regs_inst.regs[4],
                   older_side_writes);
        if ((dut.regs_inst.regs[2] !== MMIO_WORD) ||
            (dut.regs_inst.regs[3] !== (MMIO_WORD + 32'd1)) ||
            (load_writes != 1))
            $fatal(1, "replayed load mismatch x2=%08x x3=%08x writes=%0d",
                   dut.regs_inst.regs[2], dut.regs_inst.regs[3], load_writes);
        if (store_writes != 1)
            $fatal(1, "replayed store count mismatch %0d", store_writes);
        if (intended_swap_pairs != 2)
            $fatal(1, "intended swap pair count mismatch %0d",
                   intended_swap_pairs);
        if (wrong_path_swap_pairs == 0)
            $fatal(1, "wrong-path swapped packet never reached the flush window");
        if ((dut.regs_inst.regs[13] != 32'b0) ||
            (dut.regs_inst.regs[14] != 32'b0) ||
            (dut.regs_inst.regs[16] != 32'b0) ||
            (dut.regs_inst.regs[17] != 32'b0) ||
            (dut.regs_inst.regs[18] != 32'b0))
            $fatal(1, "wrong-path state committed x13=%08x x14=%08x x16=%08x x17=%08x x18=%08x",
                   dut.regs_inst.regs[13], dut.regs_inst.regs[14],
                   dut.regs_inst.regs[16], dut.regs_inst.regs[17],
                   dut.regs_inst.regs[18]);
        if (dut.regs_inst.regs[15] !== 32'h0000_0066)
            $fatal(1, "first branch target missing x15=%08x",
                   dut.regs_inst.regs[15]);

        $display("TB_PASS precise swapped memory traps=%0d mepc_reads=%0d side=%0d load=%0d store=%0d wrong_swap=%0d",
                 trap_count, mepc_reads, older_side_writes,
                 load_writes, store_writes, wrong_path_swap_pairs);
        $finish;
    end

    always @(posedge clk) begin
        if (rst_n) begin
            cycles = cycles + 1;
            if (cycles > 3000)
                $fatal(1, "precise memory timeout pc=%08x traps=%0d entries=%08x",
                       pc, trap_count, dut.regs_inst.regs[28]);

            if (dut.if_id_valid_o && dut.if_id_pair_valid_o &&
                dut.if_id_pair_swap_o && !dut.core_hold_flag) begin
                if ((dut.if_id_inst_addr_o == (LOAD_PC - 32'd4)) ||
                    (dut.if_id_inst_addr_o == (STORE_PC - 32'd4)))
                    intended_swap_pairs = intended_swap_pairs + 1;
                if ((dut.if_id_inst_addr_o == (RESET_PC + 32'h58)) ||
                    (dut.if_id_inst_addr_o == (RESET_PC + 32'h70)))
                    wrong_path_swap_pairs = wrong_path_swap_pairs + 1;
            end

            if (dut.ex_timer_irq_trap_o) begin
                trap_count = trap_count + 1;
                if ((trap_count == 1) &&
                    (dut.id_ex_inst_addr_o != LOAD_PC))
                    $fatal(1, "first trap PC mismatch %08x",
                           dut.id_ex_inst_addr_o);
                if ((trap_count == 2) &&
                    (dut.id_ex_inst_addr_o != STORE_PC))
                    $fatal(1, "second trap PC mismatch %08x",
                           dut.id_ex_inst_addr_o);
                if (!dut.lane1_idex_valid || !dut.lane1_idex_older)
                    $fatal(1, "trap lost older side-lane age tag");
            end

            if (dut.id_ex_valid_o && (dut.id_ex_inst_o == `INST_MRET) &&
                dut.ex_jump_en_o)
                mret_count = mret_count + 1;

            if (dut.lane1_wb_valid &&
                ((dut.lane1_wb_rd == 5'd1) ||
                 (dut.lane1_wb_rd == 5'd4)))
                older_side_writes = older_side_writes + 1;

            if (dut.wb_rd_wen_o && (dut.wb_rd_addr_o == 5'd2))
                load_writes = load_writes + 1;

            if (dut.wb_rd_wen_o && (dut.wb_rd_addr_o == 5'd20)) begin
                mepc_reads = mepc_reads + 1;
                if (mepc_reads == 1)
                    first_mepc_read = dut.wb_rd_data_o;
                else if (mepc_reads == 2)
                    second_mepc_read = dut.wb_rd_data_o;
            end

            if (|mem_wen) begin
                if ((mem_waddr == 32'h8020_0004) &&
                    (mem_wen == 4'b1111) &&
                    (mem_wdata == 32'h0000_0345)) begin
                    if (mret_count < 2)
                        $fatal(1, "swapped store committed before mret count=%0d traps=%0d irq2=%0b pc=%08x idex_pc=%08x timer=%0b",
                               mret_count, trap_count, irq2_fired, pc,
                               dut.id_ex_inst_addr_o, timer_irq);
                    store_writes = store_writes + 1;
                end else begin
                    $fatal(1, "wrong-path/unexpected store addr=%08x wen=%x data=%08x",
                           mem_waddr, mem_wen, mem_wdata);
                end
            end
        end
    end

endmodule
