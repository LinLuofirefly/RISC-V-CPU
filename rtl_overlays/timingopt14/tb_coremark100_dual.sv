`timescale 1ns / 1ps
`include "defines.v"
`ifndef TB_ENABLE_DUAL_ISSUE
`define TB_ENABLE_DUAL_ISSUE 1
`endif
`ifndef TB_DUAL_OP_IMM_MASK
`define TB_DUAL_OP_IMM_MASK 255
`endif
`ifndef TB_DUAL_OP_REG_MASK
`define TB_DUAL_OP_REG_MASK 255
`endif
`ifndef TB_TIMEOUT_CYCLES
`define TB_TIMEOUT_CYCLES 100000000
`endif
`ifndef TB_CPU_CLK_HZ
`define TB_CPU_CLK_HZ 200000000
`endif

module tb_coremark100_dual;
    localparam integer CPU_CLK_HZ = `TB_CPU_CLK_HZ;
    localparam integer UART_DIV = CPU_CLK_HZ / 115200;
    localparam longint TIMEOUT_CYCLES = `TB_TIMEOUT_CYCLES;
    localparam [31:0] COUNTER_ADDR = 32'h8020_0050;
    localparam [31:0] COUNTER_START_CMD = 32'h8000_0000;
    localparam [31:0] COUNTER_STOP_CMD = 32'hffff_ffff;

    reg cpu_clk = 1'b0;
    reg clk50 = 1'b0;
    reg rst = 1'b1;
    reg uart_rx = 1'b1;
    wire [31:0] led;
    wire [39:0] seg;
    wire uart_tx;
    wire trig;

    longint cycles = 0;
    longint start_cycle = 0;
    longint stop_cycle = 0;
    longint pair_count = 0;
    longint rv32m_pair_count = 0;
    longint load_swap_pair_count = 0;
    longint store_swap_pair_count = 0;
    longint lane1_wb_count = 0;
    longint lane1_addi_count = 0;
    longint lane1_other_opimm_count = 0;
    longint lane1_op_count = 0;
    longint fast_mul_count = 0;
    longint high_mul_count = 0;
    longint div_rem_count = 0;
    longint mdu_wait_cycles = 0;
    longint non_mdu_hdu_hold_cycles = 0;
    longint dual_dependency_wait_cycles = 0;
    longint dual_load_wait_cycles = 0;
    longint dual_lane0_version_wait_cycles = 0;
    longint dual_lane1_version_wait_cycles = 0;
    longint frontend_empty_cycles = 0;
    longint hdu_dep_shift_cycles = 0;
    longint hdu_mem1_load_cycles = 0;
    longint hdu_mem2_slow_cycles = 0;
    longint hdu_late_miss_cycles = 0;
    longint hdu_dep_late_cycles = 0;
    longint hdu_dep_late_load_cycles = 0;
    longint hdu_dep_late_branch_cycles = 0;
    longint hdu_dep_late_jalr_cycles = 0;
    longint hdu_dep_late_store_cycles = 0;
    longint hdu_dep_late_alu_cycles = 0;
    longint hdu_dep_late_other_cycles = 0;
    longint hdu_dep_late_dram_cycles = 0;
    longint hdu_branch_base_reg_cycles = 0;
    longint hdu_branch_base_exmem_cycles = 0;
    longint hdu_branch_base_mem1_cycles = 0;
    longint hdu_branch_base_late_cycles = 0;
    longint hdu_branch_base_memwb_cycles = 0;
    longint hdu_branch_base_mem2load_cycles = 0;
    longint hdu_branch_fast_probe_hit_cycles = 0;
    longint hdu_branch_store_fwd_cycles = 0;
    longint frontend_ctrl_flush_cycles = 0;
    longint frontend_bp_flush_cycles = 0;
    longint frontend_replay_flush_cycles = 0;
    longint frontend_load_hold_flush_cycles = 0;
    longint frontend_req_gap_cycles = 0;
    longint frontend_epoch_drop_cycles = 0;
    longint frontend_hold_empty_cycles = 0;
    longint frontend_redirect_cycles = 0;
    longint main_retired_total = 0;
    longint side_retired_total = 0;
    longint cpi_start_cycle = 0;
    longint cpi_stop_cycle = 0;
    longint cpi_main_start = 0;
    longint cpi_main_stop = 0;
    longint cpi_side_start = 0;
    longint cpi_side_stop = 0;
    reg main_exmem_valid_r = 1'b0;
    reg main_mem2_valid_r = 1'b0;
    reg main_wb_valid_r = 1'b0;
    reg saw_counter_start = 1'b0;
    reg saw_counter_stop = 1'b0;
    reg cpi_window_active = 1'b0;
    real coremark_cpi;
    real coremark_ipc;
    real lane0_cpi;
    longint cpi_cycles;
    longint cpi_main_retired;
    longint cpi_side_retired;
    longint cpi_total_retired;
    integer prompt_count = 0;
    reg running = 1'b0;
    reg [47:0] uart_tail = 48'b0;
    reg [223:0] uart_validation_tail = 224'b0;
    reg saw_e714 = 1'b0;
    reg saw_1fd7 = 1'b0;
    reg saw_8e3a = 1'b0;
    reg saw_988c = 1'b0;
    reg saw_coremark_validation = 1'b0;
`ifdef TB_TRACE_LOAD_BRANCH
    integer load_branch_trace_count = 0;
`endif

    student_top #(
        .P_CPU_CLK_HZ(CPU_CLK_HZ),
        .P_UART_BAUD_RATE(115200),
        .P_ENABLE_DUAL_ISSUE(`TB_ENABLE_DUAL_ISSUE),
        .P_DUAL_OP_IMM_MASK(`TB_DUAL_OP_IMM_MASK),
        .P_DUAL_OP_REG_MASK(`TB_DUAL_OP_REG_MASK)
    ) dut (
        .w_cpu_clk(cpu_clk), .w_clk_50Mhz(clk50), .w_clk_rst(rst),
        .virtual_key(8'b0), .virtual_sw(64'b0),
        .cpu_uart_rx(uart_rx), .hcsr04_echo(1'b0),
        .virtual_led(led), .virtual_seg(seg),
        .cpu_uart_tx(uart_tx), .hcsr04_trig(trig)
    );

    always #(500000000.0 / CPU_CLK_HZ) cpu_clk = ~cpu_clk;
    always #10 clk50 = ~clk50;

    task automatic uart_send_byte(input [7:0] value);
        integer bit_index;
        begin
            @(negedge cpu_clk);
            uart_rx = 1'b0;
            repeat (UART_DIV) @(posedge cpu_clk);
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                uart_rx = value[bit_index];
                repeat (UART_DIV) @(posedge cpu_clk);
            end
            uart_rx = 1'b1;
            repeat (UART_DIV) @(posedge cpu_clk);
        end
    endtask

    task automatic send_coremark;
        begin
            uart_send_byte("c"); uart_send_byte("o");
            uart_send_byte("r"); uart_send_byte("e");
            uart_send_byte("m"); uart_send_byte("a");
            uart_send_byte("r"); uart_send_byte("k");
            uart_send_byte(8'h0d);
        end
    endtask

    initial begin
        repeat (32) @(posedge cpu_clk);
        rst = 1'b0;
        wait (prompt_count >= 1);
        running = 1'b1;
        start_cycle = cycles;
        send_coremark();
        wait (prompt_count >= 2);
        stop_cycle = cycles;
        running = 1'b0;

        if (!(saw_counter_start && saw_counter_stop))
            $fatal(1, "CoreMark counter START/STOP window missing");
        cpi_cycles = cpi_stop_cycle - cpi_start_cycle;
        cpi_main_retired = cpi_main_stop - cpi_main_start;
        cpi_side_retired = cpi_side_stop - cpi_side_start;
        cpi_total_retired = cpi_main_retired + cpi_side_retired;
        coremark_cpi = (1.0 * cpi_cycles) / cpi_total_retired;
        coremark_ipc = (1.0 * cpi_total_retired) / cpi_cycles;
        lane0_cpi = (1.0 * cpi_cycles) / cpi_main_retired;

        $display("COREMARK100_STATS cycles=%0d pairs=%0d rv32m_pairs=%0d load_swap_pairs=%0d store_swap_pairs=%0d lane1_wb=%0d addi=%0d other_opimm=%0d op=%0d",
                 stop_cycle - start_cycle, pair_count,
                 rv32m_pair_count, load_swap_pair_count,
                 store_swap_pair_count,
                 lane1_wb_count, lane1_addi_count,
                 lane1_other_opimm_count, lane1_op_count);
        $display("COREMARK_CPI cycles=%0d main_retired=%0d side_retired=%0d total_retired=%0d cpi=%0.6f ipc=%0.6f lane0_cpi=%0.6f",
                 cpi_cycles, cpi_main_retired, cpi_side_retired,
                 cpi_total_retired, coremark_cpi, coremark_ipc,
                 lane0_cpi);
        $display("COREMARK_EXEC fast_mul=%0d high_mul=%0d div_rem=%0d mdu_wait=%0d non_mdu_hdu_hold=%0d dual_wait=%0d dual_load=%0d dual_lane0_version=%0d dual_lane1_version=%0d frontend_empty=%0d",
                 fast_mul_count, high_mul_count, div_rem_count,
                 mdu_wait_cycles, non_mdu_hdu_hold_cycles,
                 dual_dependency_wait_cycles, dual_load_wait_cycles,
                 dual_lane0_version_wait_cycles,
                 dual_lane1_version_wait_cycles, frontend_empty_cycles);
        $display("COREMARK_HDU dep_shift=%0d mem1_load=%0d mem2_slow=%0d late_miss=%0d dep_late=%0d",
                 hdu_dep_shift_cycles, hdu_mem1_load_cycles,
                 hdu_mem2_slow_cycles, hdu_late_miss_cycles,
                 hdu_dep_late_cycles);
        $display("COREMARK_HDU_LATE load=%0d branch=%0d jalr=%0d store=%0d alu=%0d other=%0d dram=%0d",
                 hdu_dep_late_load_cycles,
                 hdu_dep_late_branch_cycles,
                 hdu_dep_late_jalr_cycles,
                 hdu_dep_late_store_cycles,
                 hdu_dep_late_alu_cycles,
                  hdu_dep_late_other_cycles,
                  hdu_dep_late_dram_cycles);
        $display("COREMARK_HDU_BRANCH_BASE reg=%0d exmem=%0d mem1=%0d late=%0d memwb=%0d mem2load=%0d probe_hit=%0d store_fwd=%0d",
                 hdu_branch_base_reg_cycles,
                 hdu_branch_base_exmem_cycles,
                 hdu_branch_base_mem1_cycles,
                 hdu_branch_base_late_cycles,
                 hdu_branch_base_memwb_cycles,
                 hdu_branch_base_mem2load_cycles,
                 hdu_branch_fast_probe_hit_cycles,
                 hdu_branch_store_fwd_cycles);
        $display("COREMARK_FRONTEND ctrl_flush=%0d bp_flush=%0d replay_flush=%0d load_hold_flush=%0d req_gap=%0d epoch_drop=%0d hold_empty=%0d redirect=%0d",
                 frontend_ctrl_flush_cycles, frontend_bp_flush_cycles,
                 frontend_replay_flush_cycles,
                 frontend_load_hold_flush_cycles,
                 frontend_req_gap_cycles, frontend_epoch_drop_cycles,
                 frontend_hold_empty_cycles, frontend_redirect_cycles);
        if (!(saw_e714 && saw_1fd7 && saw_8e3a && saw_988c))
            $fatal(1, "missing standard CRCs e714/1fd7/8e3a/988c");
        if (!saw_coremark_validation)
            $fatal(1, "CoreMark validation message missing");
        if (`TB_ENABLE_DUAL_ISSUE &&
            (pair_count == 0 || lane1_wb_count == 0))
            $fatal(1, "dual-issue lane was not exercised");
        if (`TB_ENABLE_DUAL_ISSUE && (rv32m_pair_count == 0))
            $fatal(1, "RV32M Lane-0 pairing was not exercised");
        if (`TB_ENABLE_DUAL_ISSUE && (load_swap_pair_count == 0))
            $fatal(1, "swapped Lane-1 load pairing was not exercised");
        if (`TB_ENABLE_DUAL_ISSUE && (store_swap_pair_count == 0))
            $fatal(1, "swapped Lane-1 store pairing was not exercised");
        if (`TB_ENABLE_DUAL_ISSUE &&
            (`TB_DUAL_OP_IMM_MASK != 1) &&
            (lane1_other_opimm_count == 0))
            $fatal(1, "expanded Lane-1 OP-IMM classes were not exercised");
        if (`TB_ENABLE_DUAL_ISSUE &&
            (`TB_DUAL_OP_REG_MASK != 0) && (lane1_op_count == 0))
            $fatal(1, "expanded Lane-1 OP class was not exercised");
        $display("TB_PASS CoreMark 100 dual-issue CRC validation completed");
        $finish;
    end

    // The main pipeline carries an explicit valid bit through ID/EX only.
    // Mirror the remaining fixed-latency stages so architectural NOPs are
    // counted while bubbles are excluded. RV32M emits one valid slot only on
    // its done cycle; killed, trapped and replaying EX slots do not retire.
    always @(posedge cpu_clk) begin
        if (rst) begin
            main_exmem_valid_r <= 1'b0;
            main_mem2_valid_r  <= 1'b0;
            main_wb_valid_r    <= 1'b0;
        end else begin
            main_wb_valid_r   <= main_mem2_valid_r;
            main_mem2_valid_r <= main_exmem_valid_r;
            main_exmem_valid_r <=
                dut.Core_cpu.cpu_core.id_ex_valid_o &&
                !dut.Core_cpu.cpu_core.ctrl_kill_ex_o &&
                !dut.Core_cpu.cpu_core.ex_redirect_kill &&
                !dut.Core_cpu.cpu_core.late_load_miss_o &&
                !dut.Core_cpu.cpu_core.ex_timer_irq_trap_o &&
                !dut.Core_cpu.cpu_core.ex_rv32m_busy_o;
        end
    end

    always @(posedge cpu_clk) begin
        if (!rst) begin
            cycles = cycles + 1;
`ifdef TB_TRACE_LOAD_BRANCH
            if ((load_branch_trace_count < 80) &&
                ((dut.Core_cpu.cpu_core.id_ex_inst_addr_o == 32'h8000_4d78) ||
                 (dut.Core_cpu.cpu_core.id_ex_inst_addr_o == 32'h8000_4d7c))) begin
                $display("LBTRACE cyc=%0d pc=%08x ifpc=%08x ifinst=%08x expc=%08x exinst=%08x hold=%b dep=%b sel1=%0d sel2=%0d exaddr=%08x mem1inst=%08x mem1addr=%08x hit=%b bfvalid=%b bfdata=%08x lbop1=%08x lbop2=%08x miss=%b bj=%b jt=%08x",
                         cycles, dut.pc,
                         dut.Core_cpu.cpu_core.if_id_inst_addr_o,
                         dut.Core_cpu.cpu_core.if_id_inst_o,
                         dut.Core_cpu.cpu_core.id_ex_inst_addr_o,
                         dut.Core_cpu.cpu_core.id_ex_inst_o,
                         dut.Core_cpu.cpu_core.core_hold_flag,
                         dut.Core_cpu.cpu_core.hdu_inst.dep_late_stall,
                         dut.Core_cpu.cpu_core.id_ex_rs1_fwd_sel_o,
                         dut.Core_cpu.cpu_core.id_ex_rs2_fwd_sel_o,
                         dut.Core_cpu.cpu_core.ex_rd_mem_addr_o,
                         dut.Core_cpu.cpu_core.ex_mem_inst_o,
                         dut.Core_cpu.cpu_core.ex_mem_mem_rd_addr_o,
                         dut.Core_cpu.cpu_core.mem1_load_cache_hit,
                         dut.Core_cpu.cpu_core.branch_fast_load_valid,
                         dut.Core_cpu.cpu_core.branch_fast_load_data,
                         dut.Core_cpu.cpu_core.ex_inst.load_branch_op1,
                         dut.Core_cpu.cpu_core.ex_inst.load_branch_op2,
                         dut.Core_cpu.cpu_core.late_load_miss_o,
                         dut.Core_cpu.cpu_core.ex_load_branch_jump_en_o,
                         dut.Core_cpu.cpu_core.ex_load_branch_jump_addr_o);
                load_branch_trace_count = load_branch_trace_count + 1;
            end
`endif
            if (cycles >= TIMEOUT_CYCLES)
                $fatal(1, "CoreMark 100 timeout pc=%08x", dut.pc);

            if (running && dut.Core_cpu.cpu_core.fetch_pair_accept)
                pair_count = pair_count + 1;
            if (running && dut.Core_cpu.cpu_core.fetch_pair_accept &&
                (dut.Core_cpu.cpu_core.inst_i[6:0] ==
                 `INST_TYPE_R_M) &&
                (dut.Core_cpu.cpu_core.inst_i[31:25] ==
                 `INST_FUNC7_M))
                rv32m_pair_count = rv32m_pair_count + 1;
            if (running &&
                dut.Core_cpu.cpu_core.fetch_pair_swap_accept &&
                (dut.Core_cpu.cpu_core.inst_next_i[6:0] ==
                 `INST_TYPE_L))
                load_swap_pair_count = load_swap_pair_count + 1;
            if (running &&
                dut.Core_cpu.cpu_core.fetch_pair_swap_accept &&
                (dut.Core_cpu.cpu_core.inst_next_i[6:0] ==
                 `INST_TYPE_S))
                store_swap_pair_count = store_swap_pair_count + 1;

            if (main_wb_valid_r)
                main_retired_total = main_retired_total + 1;
            if (dut.Core_cpu.cpu_core.lane1_wb_valid)
                side_retired_total = side_retired_total + 1;

            if (cpi_window_active) begin
                if (dut.Core_cpu.cpu_core.id_ex_valid_o &&
                    dut.Core_cpu.cpu_core.id_ex_is_rv32m_o &&
                    (dut.Core_cpu.cpu_core.id_ex_func3_o == `INST_MUL) &&
                    !dut.Core_cpu.cpu_core.ctrl_kill_ex_o &&
                    !dut.Core_cpu.cpu_core.ex_timer_irq_trap_o)
                    fast_mul_count = fast_mul_count + 1;
                if (dut.Core_cpu.cpu_core.ex_inst.rv32m_start) begin
                    if (dut.Core_cpu.cpu_core.id_ex_func3_o <=
                        `INST_MULHU)
                        high_mul_count = high_mul_count + 1;
                    else
                        div_rem_count = div_rem_count + 1;
                end
                if (dut.Core_cpu.cpu_core.ex_rv32m_busy_o &&
                    !dut.Core_cpu.cpu_core.ex_rv32m_done_o)
                    mdu_wait_cycles = mdu_wait_cycles + 1;
                if (dut.Core_cpu.cpu_core.hdu_hold_flag_o &&
                    !(dut.Core_cpu.cpu_core.ex_rv32m_busy_o &&
                      !dut.Core_cpu.cpu_core.ex_rv32m_done_o))
                    non_mdu_hdu_hold_cycles =
                        non_mdu_hdu_hold_cycles + 1;
                if (dut.Core_cpu.cpu_core.dual_dependency_wait)
                    dual_dependency_wait_cycles =
                        dual_dependency_wait_cycles + 1;
                if (dut.Core_cpu.cpu_core.dual_issue_forwarding_inst.lane1_src1_wait_main ||
                    dut.Core_cpu.cpu_core.dual_issue_forwarding_inst.lane1_src2_wait_main)
                    dual_load_wait_cycles = dual_load_wait_cycles + 1;
                if (dut.Core_cpu.cpu_core.dual_issue_forwarding_inst.lane1_pipe_writes_id_rs1 ||
                    dut.Core_cpu.cpu_core.dual_issue_forwarding_inst.lane1_pipe_writes_id_rs2)
                    dual_lane0_version_wait_cycles =
                        dual_lane0_version_wait_cycles + 1;
                if (dut.Core_cpu.cpu_core.dual_issue_forwarding_inst.lane1_pipe_writes_lane1_rs1 ||
                    dut.Core_cpu.cpu_core.dual_issue_forwarding_inst.lane1_pipe_writes_lane1_rs2)
                    dual_lane1_version_wait_cycles =
                        dual_lane1_version_wait_cycles + 1;
                if (!dut.Core_cpu.cpu_core.if_id_valid_o)
                    frontend_empty_cycles = frontend_empty_cycles + 1;
                if (dut.Core_cpu.cpu_core.hdu_inst.dep_shift)
                    hdu_dep_shift_cycles = hdu_dep_shift_cycles + 1;
                if (dut.Core_cpu.cpu_core.hdu_inst.mem1_load_dep)
                    hdu_mem1_load_cycles = hdu_mem1_load_cycles + 1;
                if (dut.Core_cpu.cpu_core.hdu_inst.mem2_slow_load_dep)
                    hdu_mem2_slow_cycles = hdu_mem2_slow_cycles + 1;
                if (dut.Core_cpu.cpu_core.hdu_inst.late_load_miss_o)
                    hdu_late_miss_cycles = hdu_late_miss_cycles + 1;
                if (dut.Core_cpu.cpu_core.hdu_inst.dep_late_stall) begin
                    hdu_dep_late_cycles = hdu_dep_late_cycles + 1;
                    if (dut.Core_cpu.cpu_core.id_inst_o[6:0] ==
                        `INST_TYPE_L)
                        hdu_dep_late_load_cycles =
                            hdu_dep_late_load_cycles + 1;
                    else if (dut.Core_cpu.cpu_core.id_inst_o[6:0] ==
                             `INST_TYPE_B) begin
                        hdu_dep_late_branch_cycles =
                            hdu_dep_late_branch_cycles + 1;
                        case (dut.Core_cpu.cpu_core.id_ex_rs1_fwd_sel_o)
                            3'd0: hdu_branch_base_reg_cycles =
                                      hdu_branch_base_reg_cycles + 1;
                            3'd1: hdu_branch_base_exmem_cycles =
                                      hdu_branch_base_exmem_cycles + 1;
                            3'd2: hdu_branch_base_mem1_cycles =
                                      hdu_branch_base_mem1_cycles + 1;
                            3'd3: hdu_branch_base_late_cycles =
                                      hdu_branch_base_late_cycles + 1;
                            3'd4: hdu_branch_base_memwb_cycles =
                                      hdu_branch_base_memwb_cycles + 1;
                            3'd5: hdu_branch_base_mem2load_cycles =
                                      hdu_branch_base_mem2load_cycles + 1;
                            default: ;
                        endcase
                        if (dut.Core_cpu.cpu_core.ex_fast_load_cache_hit)
                            hdu_branch_fast_probe_hit_cycles =
                                hdu_branch_fast_probe_hit_cycles + 1;
                        if (dut.Core_cpu.cpu_core.fast_store_load_fwd_valid_ex)
                            hdu_branch_store_fwd_cycles =
                                hdu_branch_store_fwd_cycles + 1;
                    end
                    else if (dut.Core_cpu.cpu_core.id_inst_o[6:0] ==
                             `INST_JALR)
                        hdu_dep_late_jalr_cycles =
                            hdu_dep_late_jalr_cycles + 1;
                    else if (dut.Core_cpu.cpu_core.id_inst_o[6:0] ==
                             `INST_TYPE_S)
                        hdu_dep_late_store_cycles =
                            hdu_dep_late_store_cycles + 1;
                    else if ((dut.Core_cpu.cpu_core.id_inst_o[6:0] ==
                              `INST_TYPE_I) ||
                             (dut.Core_cpu.cpu_core.id_inst_o[6:0] ==
                              `INST_TYPE_R_M))
                        hdu_dep_late_alu_cycles =
                            hdu_dep_late_alu_cycles + 1;
                    else
                        hdu_dep_late_other_cycles =
                            hdu_dep_late_other_cycles + 1;
                    if (dut.Core_cpu.cpu_core.ex_load_hits_dram_o)
                        hdu_dep_late_dram_cycles =
                            hdu_dep_late_dram_cycles + 1;
                end
                if (dut.Core_cpu.cpu_core.ctrl_flush_ifid_o)
                    frontend_ctrl_flush_cycles =
                        frontend_ctrl_flush_cycles + 1;
                if (dut.Core_cpu.cpu_core.bp_pred_flush_d1_r)
                    frontend_bp_flush_cycles =
                        frontend_bp_flush_cycles + 1;
                if (dut.Core_cpu.cpu_core.bp_replay_flush_d1_r)
                    frontend_replay_flush_cycles =
                        frontend_replay_flush_cycles + 1;
                if (dut.Core_cpu.cpu_core.bp_load_hold_flush_d1_r)
                    frontend_load_hold_flush_cycles =
                        frontend_load_hold_flush_cycles + 1;
                if (!dut.Core_cpu.cpu_core.bp_fetch_valid_r)
                    frontend_req_gap_cycles =
                        frontend_req_gap_cycles + 1;
                if (dut.Core_cpu.cpu_core.bp_fetch_valid_r &&
                    !dut.Core_cpu.cpu_core.bp_fetch_epoch_match)
                    frontend_epoch_drop_cycles =
                        frontend_epoch_drop_cycles + 1;
                if (!dut.Core_cpu.cpu_core.if_id_valid_o &&
                    dut.Core_cpu.cpu_core.core_hold_flag)
                    frontend_hold_empty_cycles =
                        frontend_hold_empty_cycles + 1;
                if (dut.Core_cpu.cpu_core.ctrl_jump_en_o ||
                    dut.Core_cpu.cpu_core.bp_pc_redirect_valid ||
                    dut.Core_cpu.cpu_core.bp_load_hold_redirect_commit)
                    frontend_redirect_cycles =
                        frontend_redirect_cycles + 1;
            end

            if ((|dut.perip_wstrb) &&
                (dut.perip_addr == COUNTER_ADDR)) begin
                if (dut.perip_wdata == COUNTER_START_CMD) begin
                    saw_counter_start = 1'b1;
                    cpi_start_cycle = cycles;
                    cpi_main_start = main_retired_total;
                    cpi_side_start = side_retired_total;
                    cpi_window_active = 1'b1;
                end else if (dut.perip_wdata == COUNTER_STOP_CMD) begin
                    saw_counter_stop = 1'b1;
                    cpi_stop_cycle = cycles;
                    cpi_main_stop = main_retired_total;
                    cpi_side_stop = side_retired_total;
                    cpi_window_active = 1'b0;
                end
            end

            if (running && dut.Core_cpu.cpu_core.lane1_wb_valid) begin
                lane1_wb_count = lane1_wb_count + 1;
                if (dut.Core_cpu.cpu_core.lane1_wb_inst[6:0] ==
                    `INST_TYPE_I) begin
                    if (dut.Core_cpu.cpu_core.lane1_wb_inst[14:12] ==
                        `INST_ADDI)
                        lane1_addi_count = lane1_addi_count + 1;
                    else
                        lane1_other_opimm_count =
                            lane1_other_opimm_count + 1;
                end else if (dut.Core_cpu.cpu_core.lane1_wb_inst[6:0] ==
                             `INST_TYPE_R_M) begin
                    lane1_op_count = lane1_op_count + 1;
                end
            end

            if (dut.bridge_inst.uart_data_write) begin
                $write("%c", dut.perip_wdata[7:0]);
                $fflush();
                uart_tail = {uart_tail[39:0], dut.perip_wdata[7:0]};
                uart_validation_tail =
                    {uart_validation_tail[215:0], dut.perip_wdata[7:0]};
                if (uart_tail[39:0] == 40'h6d7368203e)
                    prompt_count = prompt_count + 1;
                if (uart_tail == 48'h307865373134) saw_e714 = 1'b1;
                if (uart_tail == 48'h307831666437) saw_1fd7 = 1'b1;
                if (uart_tail == 48'h307838653361) saw_8e3a = 1'b1;
                if (uart_tail == 48'h307839383863) saw_988c = 1'b1;
                if (uart_validation_tail ==
                    "Correct operation validated.")
                    saw_coremark_validation = 1'b1;
            end
        end
    end
endmodule
