`timescale 1ns / 1ps
`include "defines.v"
`include "dram_cache.v"
`include "dual_issue_pairing.v"
`include "dual_issue_forwarding.v"
`include "dual_issue_lane.v"
`ifndef DCACHE_INDEX_BITS
`define DCACHE_INDEX_BITS 8
`endif

module open_risc_v #(
    // The request and its prediction metadata are registered as one packet
    // beside the synchronous IROM.  The default therefore keeps the fast
    // request-stage redirect enabled; set this to zero for A/B diagnostics.
    parameter ENABLE_REQUEST_STAGE_BP = 1'b1,
    // Keep the fast request-stage conditional-branch lookup, but let indirect
    // JALR prediction complete at the response stage by default.  The request
    // ITC tag compare otherwise sits on the frontend hold-to-PC critical path.
    parameter ENABLE_REQUEST_INDIRECT_BP = 1'b0,
    parameter ENABLE_DUAL_ISSUE = 1'b1,
    parameter [7:0] DUAL_OP_IMM_MASK = 8'hff,
    parameter [7:0] DUAL_OP_REG_MASK = 8'hff
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [31:0] inst_i,
    input  wire [31:0] inst_next_i,
    input  wire [31:0] ram_data_i,
    input  wire [31:0] mmio_data_i,
    input  wire        timer_irq_i,
    output wire [31:0] pc_reg_pc_o,
    output wire [31:0] irom_addr_o,
    output wire [12:0] irom_word_addr_o,
    output wire [12:0] irom_word_addr_next_o,
    output wire        mem_rd_reg_o,
    output wire [31:0] mem_rd_addr_o,
    output wire [3:0]  w_en,
    output wire [31:0] w_addr_i,
    output wire [31:0] w_data_i
);

    localparam [31:0] DRAM_ADDR_START = 32'h8010_0000;
    localparam [31:0] DRAM_ADDR_END   = 32'h8014_0000;

    wire rst = rst_n;

    // ------------------------------------------------------------------
    // CTRL / branch redirect
    // ------------------------------------------------------------------
    wire [31:0] ctrl_jump_addr_o;
    wire        ctrl_jump_en_o;
    wire        ctrl_kill_ex_o;
    wire        ctrl_flush_ifid_o;
    wire        ctrl_flush_idex_o;

    // ------------------------------------------------------------------
    // Branch predictor / fetch side
    // ------------------------------------------------------------------
    wire        bp_pred_taken_o;
    wire [31:0] bp_pred_target_o;
    wire [`BP_GHR_WIDTH-1:0] bp_pred_ghr_o;
    wire [1:0]  bp_pred_type_o;

    wire        bp_req_btb_hit_o;
    wire        bp_req_pred_valid_o;
    wire        bp_req_pred_taken_o;
    wire [31:0] bp_req_pred_target_o;
    wire [`BP_GHR_WIDTH-1:0] bp_req_pred_ghr_o;
    wire [1:0]  bp_req_pred_type_o;
    reg         bp_fetch_valid_r;
    reg         bp_fetch_pred_valid_r;
    reg         bp_early_pred_taken_r;
    reg  [31:0] bp_early_pred_target_r;
    reg  [`BP_GHR_WIDTH-1:0] bp_early_pred_ghr_r;
    reg  [1:0]  bp_early_pred_type_r;
    reg         fetch_epoch_r;
    reg         bp_fetch_epoch_r;

    reg         bp_pred_flush_d1_r;
    reg         bp_replay_flush_d1_r;
    reg         bp_load_hold_flush_d1_r;

    wire [31:0] pc_jump_addr_o;
    wire        pc_jump_en_o;
    reg         pc_redirect_valid;
    reg  [31:0] pc_redirect_target;
    wire        bp_pc_redirect_valid;
    wire [31:0] bp_pc_redirect_target;
    reg         load_branch_redirect_valid_r;
    reg  [31:0] load_branch_redirect_target_r;

    reg  [31:0] bp_fetch_pc_r;

    // ------------------------------------------------------------------
    // HDU
    // ------------------------------------------------------------------
    wire        hdu_hold_flag_o;
    wire        hdu_flush_flag_o;
    wire        late_load_miss_o;
    wire        load_branch_hold_o;

    // ------------------------------------------------------------------
    // IF/ID
    // ------------------------------------------------------------------
    wire [31:0] if_id_inst_addr_o;
    wire [31:0] if_id_inst_o;
    wire [31:0] if_id_inst2_o;
    wire        if_id_pair_valid_o;
    wire        if_id_pair_swap_o;
    wire        if_id_valid_o;
    wire        if_id_pred_taken_o;
    wire [31:0] if_id_pred_target_o;
    wire [`BP_GHR_WIDTH-1:0] if_id_pred_ghr_o;
    wire [1:0]  if_id_pred_type_o;
    wire        if_id_redirect_already_issued_o;

    wire        if_id_load_valid_o;
    wire        if_id_load_pred_taken_o;
    wire [31:0] if_id_load_pred_target_o;
    wire        if_id_replaying_o;
    wire        if_id_replay_pending_o;
    wire        if_id_load_branch_redirect_pending_o;
    wire [31:0] if_id_load_branch_redirect_target_o;

    // ------------------------------------------------------------------
    // ID
    // ------------------------------------------------------------------
    wire [4:0]  id_rs1_addr_o;
    wire [4:0]  id_rs2_addr_o;
    wire [2:0]  id_rs1_fwd_sel_o;
    wire [2:0]  id_rs2_fwd_sel_o;
    wire [31:0] id_inst_o;
    wire [31:0] id_inst_addr_o;
    wire [31:0] id_op1_o;
    wire [31:0] id_op2_o;
    wire [31:0] id_cmp_op2_o;
    wire [31:0] id_store_data_o;
    wire [4:0]  id_rd_addr_o;
    wire        id_reg_wen;
    wire [31:0] id_base_addr_o;
    wire [31:0] id_branch_offset_o;
    wire [31:0] id_mem_offset_o;
    wire [31:0] id_jump_offset_o;
    wire [2:0]  id_branch_cond_o;
    wire        id_use_rs1_o;
    wire        id_use_rs2_o;
    wire        id_is_branch_o;
    wire        id_use_base_addr_o;
    wire [2:0]  id_dec_func3_o;
    wire        id_dec_func7_bit5_o;
    wire        id_dec_func7_is_r_o;
    wire        id_dec_func7_is_sub_o;
    wire        id_dec_is_op_imm_o;
    wire        id_dec_is_op_reg_o;
    wire        id_dec_is_branch_o;
    wire        id_dec_is_load_o;
    wire        id_dec_is_store_o;
    wire        id_dec_is_jal_o;
    wire        id_dec_is_jalr_o;
    wire        id_dec_is_auipc_o;
    wire        id_dec_is_lui_o;
    wire        id_dec_is_system_o;
    wire        id_dec_is_rv32m_o;
    wire        id_dec_is_csr_op_o;
    wire        id_dec_is_call_jal_o;
    wire        id_dec_ras_should_push_jalr_o;
    wire        id_dec_ras_should_pop_jalr_o;
    wire        id_dec_ras_predicted_jalr_o;
    wire        data_read_en;

    // ------------------------------------------------------------------
    // Regfile / WB
    // ------------------------------------------------------------------
    wire [31:0] regs_reg1_rdata_o;
    wire [31:0] regs_reg2_rdata_o;
    wire [31:0] regs_reg3_rdata_o;
    wire [31:0] regs_reg4_rdata_o;
    wire [4:0]  wb_rd_addr_o;
    wire [31:0] wb_rd_data_o;
    wire        wb_rd_wen_o;

    // ------------------------------------------------------------------
    // Dual-issue lane interfaces. Implementation lives in dedicated files.
    // ------------------------------------------------------------------
    wire [4:0]  lane1_id_rs1;
    wire [4:0]  lane1_id_rs2;
    wire        lane1_id_use_rs1;
    wire        lane1_id_use_rs2;
    wire        lane1_idex_valid;
    wire        lane1_idex_older;
    wire [4:0]  lane1_idex_rd;
    wire [31:0] lane1_alu_result;
    wire        lane1_exmem_valid;
    wire [4:0]  lane1_exmem_rd;
    wire [31:0] lane1_exmem_data;
    wire        lane1_mem2_valid;
    wire [4:0]  lane1_mem2_rd;
    wire [31:0] lane1_mem2_data;
    wire        lane1_wb_valid;
    wire [31:0] lane1_wb_inst;
    wire [4:0]  lane1_wb_rd;
    wire [31:0] lane1_wb_data;
    wire        lane1_branch_squash;
    wire        lane1_kill_ex;
    wire        lane1_idex_forward_valid;
    wire        ex_redirect_kill;

    // ------------------------------------------------------------------
    // ID/EX
    // ------------------------------------------------------------------
    wire [31:0] id_ex_inst_o;
    wire        id_ex_valid_o;
    wire [31:0] id_ex_inst_addr_o;
    wire [31:0] id_ex_op1_o;
    wire [31:0] id_ex_op2_o;
    wire [31:0] id_ex_cmp_op2_o;
    wire [31:0] id_ex_store_data_o;
    wire        id_ex_pred_taken_o;
    wire [31:0] id_ex_pred_target_o;
    wire [`BP_GHR_WIDTH-1:0] id_ex_pred_ghr_o;
    wire [1:0]  id_ex_pred_type_o;
    wire [4:0]  id_ex_rs1_addr_o;
    wire [4:0]  id_ex_rs2_addr_o;
    wire [2:0]  id_ex_rs1_fwd_sel_o;
    wire [2:0]  id_ex_rs2_fwd_sel_o;
    wire        id_ex_use_rs1_o;
    wire        id_ex_use_rs2_o;
    wire        id_ex_use_base_addr_o;
    wire [4:0]  id_ex_rd_addr_o;
    wire        id_ex_reg_wen;
    wire [31:0] id_ex_base_addr_o;
    wire [31:0] id_ex_branch_offset_o;
    wire [31:0] id_ex_mem_offset_o;
    wire [31:0] id_ex_jump_offset_o;
    wire [2:0]  id_ex_branch_cond_o;
    wire [2:0]  id_ex_func3_o;
    wire        id_ex_func7_bit5_o;
    wire        id_ex_func7_is_r_o;
    wire        id_ex_func7_is_sub_o;
    wire        id_ex_is_op_imm_o;
    wire        id_ex_is_op_reg_o;
    wire        id_ex_is_branch_o;
    wire        id_ex_is_load_o;
    wire        id_ex_is_store_o;
    wire        id_ex_is_jal_o;
    wire        id_ex_is_jalr_o;
    wire        id_ex_is_auipc_o;
    wire        id_ex_is_lui_o;
    wire        id_ex_is_system_o;
    wire        id_ex_is_rv32m_o;
    wire        id_ex_is_csr_op_o;
    wire        id_ex_is_call_jal_o;
    wire        id_ex_ras_should_push_jalr_o;
    wire        id_ex_ras_should_pop_jalr_o;
    wire        id_ex_ras_predicted_jalr_o;

    // ------------------------------------------------------------------
    // EX
    // ------------------------------------------------------------------
    wire [4:0]  ex_rd_addr_o;
    wire [31:0] ex_rd_data_o;
    wire        ex_rd_wen_o;
    wire [3:0]  ex_wd_reg_o;
    wire [31:0] ex_wd_addr_o;
    wire [31:0] ex_wd_data_o;
    wire        ex_is_load_o;
    wire [31:0] ex_inst_o;
    wire [31:0] ex_jump_addr_o;
    wire        ex_jump_en_o;
    wire [31:0] ex_load_branch_jump_addr_o;
    wire        ex_load_branch_jump_en_o;
    wire        ex_timer_irq_trap_o;
    wire [31:0] ex_rd_mem_addr_o;
    wire        ex_load_hits_dram_o;

    wire        bp_update_en_o;
    wire [31:0] bp_update_pc_o;
    wire [31:0] bp_update_target_o;
    wire [`BP_GHR_WIDTH-1:0] bp_update_ghr_o;
    wire        bp_ras_push_en_o;
    wire        bp_ras_pop_en_o;
    wire [31:0] bp_ras_push_addr_o;
    wire        bp_jalr_update_en_o;
    wire [31:0] bp_jalr_update_pc_o;
    wire [31:0] bp_jalr_update_target_o;
    wire [`BP_GHR_WIDTH-1:0] bp_jalr_update_ghr_o;
    wire        bp_jalr_update_is_call_o;
    wire        bp_actual_taken_o;

    wire        ex_rv32m_busy_o;
    wire        ex_rv32m_done_o;

    // ------------------------------------------------------------------
    // Pipeline branch predictor update buses
    // ------------------------------------------------------------------
    wire        ex_mem_bp_update_en_o;
    wire [31:0] ex_mem_bp_update_pc_o;
    wire [31:0] ex_mem_bp_update_target_o;
    wire [`BP_GHR_WIDTH-1:0] ex_mem_bp_update_ghr_o;
    wire        ex_mem_bp_actual_taken_o;

    wire        mem1_mem2_bp_update_en_o;
    wire [31:0] mem1_mem2_bp_update_pc_o;
    wire [31:0] mem1_mem2_bp_update_target_o;
    wire [`BP_GHR_WIDTH-1:0] mem1_mem2_bp_update_ghr_o;
    wire        mem1_mem2_bp_actual_taken_o;

    wire        mem_wb_bp_update_en_o;
    wire [31:0] mem_wb_bp_update_pc_o;
    wire [31:0] mem_wb_bp_update_target_o;
    wire [`BP_GHR_WIDTH-1:0] mem_wb_bp_update_ghr_o;
    wire        mem_wb_bp_actual_taken_o;

    wire fetch_pair_raw;
    wire fetch_pair_swap_raw;

    dual_issue_pairing #(
        .ENABLE_DUAL_ISSUE (ENABLE_DUAL_ISSUE),
        .OP_IMM_MASK      (DUAL_OP_IMM_MASK),
        .OP_REG_MASK      (DUAL_OP_REG_MASK)
    ) dual_issue_pairing_inst (
        .fetch_pc_i       (bp_fetch_pc_r[2:0]),
        .inst0_i          (inst_i),
        .inst1_i          (inst_next_i),
        .pair_eligible_o  (fetch_pair_raw),
        .pair_swap_o      (fetch_pair_swap_raw)
    );

    // ------------------------------------------------------------------
    // Forwarding
    // ------------------------------------------------------------------
    wire [31:0] fwd_op1_o;
    wire [31:0] fwd_op2_o;
    wire [31:0] fwd_rv32m_op1_o;
    wire [31:0] fwd_rv32m_op2_o;
    wire [31:0] fwd_cmp_op2_o;
    wire [31:0] fwd_br_op1_o;
    wire [31:0] fwd_br_op2_o;
    wire        branch_fast_load_valid;
    wire [31:0] branch_fast_load_data;
    localparam [2:0] FWD_REG       = 3'd0;
    localparam [2:0] FWD_LATE_LOAD = 3'd3;
    localparam [2:0] FWD_MEM2_LOAD = 3'd5;
    wire [31:0] fwd_store_data_o;
    wire [31:0] fwd_load_base_addr_o;
    wire [31:0] fwd_store_base_addr_o;
    wire [31:0] fwd_jalr_base_addr_o;

    // ------------------------------------------------------------------
    // EX/MEM1
    // ------------------------------------------------------------------
    wire [4:0]  ex_mem_pipe_rd_addr_o;
    wire [31:0] ex_mem_rd_data_o;
    wire        ex_mem_rd_wen_o;
    wire [3:0]  ex_mem_wd_reg_o;
    wire [31:0] ex_mem_wd_addr_o;
    wire [31:0] ex_mem_wd_data_o;
    wire        ex_mem_is_load_o;
    wire        ex_mem_load_hits_dram_o;
    wire        ex_mem_load_fast_eligible_o;
    wire [31:0] ex_mem_inst_o;
    wire [31:0] ex_mem_mem_rd_addr_o;
    wire        ex_mem_store_load_fwd_valid_o;
    wire        ex_mem_store_load_fwd_valid_cache_o;
    wire        ex_mem_store_load_fwd_valid_pipe_o;
    wire [3:0]  ex_mem_store_load_fwd_wstrb_o;
    wire [31:0] ex_mem_store_load_fwd_data_o;

    // ------------------------------------------------------------------
    // MEM1
    // ------------------------------------------------------------------
    wire [4:0]  mem_out_rd_addr_o;
    wire [31:0] mem_out_rd_data_o;
    wire        mem_out_rd_wen_o;
    wire [31:0] mem_inst_o;
    wire [31:0] mem_out_mem_rd_addr_o;
    wire        mem_out_is_load_o;

    // ------------------------------------------------------------------
    // MEM1/MEM2
    // ------------------------------------------------------------------
    wire [4:0]  mem1_mem2_rd_addr_o;
    wire [31:0] mem1_mem2_rd_data_o;
    wire        mem1_mem2_rd_wen_o;
    wire [31:0] mem1_mem2_inst_o;
    wire [31:0] mem1_mem2_mem_rd_addr_o;
    wire        mem1_mem2_is_load_o;
    wire        mem1_mem2_load_hits_dram_o;
    wire        mem1_mem2_load_cache_hit_o;
    wire        mem1_mem2_store_load_fwd_valid_o;
    wire        mem1_mem2_store_load_fwd_valid_cache_o;
    wire        mem1_mem2_store_load_fwd_valid_mem2_o;
    wire [3:0]  mem1_mem2_store_load_fwd_wstrb_o;
    wire [31:0] mem1_mem2_store_load_fwd_data_o;

    // ------------------------------------------------------------------
    // MEM2
    // ------------------------------------------------------------------
    wire [31:0] mem2_inst_o;
    wire [4:0]  mem2_rd_addr_o;
    wire [31:0] mem2_rd_data_o;
    wire        mem2_rd_wen_o;
    wire        mem2_is_slow_load_o;

    // ------------------------------------------------------------------
    // MEM/WB
    // ------------------------------------------------------------------
    wire [4:0]  mem_wb_rd_addr_o;
    wire [31:0] mem_wb_rd_data_o;
    wire        mem_wb_rd_wen_o;
    wire [31:0] mem_wb_mem_rd_addr_o;
    wire        mem_wb_is_slow_load_o;
    wire [31:0] mem_wb_inst_o;
    wire [31:0] mem_wb_rd_data_fwd_o;

    wire id_dec_is_shift_imm =
        id_dec_is_op_imm_o &&
        (((id_dec_func3_o == `INST_SLLI) && id_dec_func7_is_r_o) ||
         ((id_dec_func3_o == `INST_SRI) &&
          (id_dec_func7_is_r_o || id_dec_func7_is_sub_o)));

    wire id_dec_is_shift_reg =
        id_dec_is_op_reg_o &&
        (((id_dec_func3_o == `INST_SLL) && id_dec_func7_is_r_o) ||
         ((id_dec_func3_o == `INST_SR) &&
          (id_dec_func7_is_r_o || id_dec_func7_is_sub_o)));

    wire id_dec_has_deep_alu = id_dec_is_shift_imm || id_dec_is_shift_reg;

    // The EX load address is now physically driven by a non-late forwarding
    // mux.  Ordinary ALU/store consumers retain the hit bypass; a dependent
    // load waits for a registered result to avoid cache-hit -> address chains.
    // 当前 ID 指令为 shift 时也禁止 late-load：否则命中数据会直接进入
    // 桶形移位器，形成 DCache 输出到 EX/MEM1 寄存器的长组合路径。
    wire id_ex_reg_wen_valid = id_ex_valid_o && id_ex_reg_wen;
    wire id_ex_is_load_valid = id_ex_valid_o && id_ex_is_load_o;
    wire ex_fast_load_cache_hit;
    wire store_load_fwd_valid_ex;
    wire fast_store_load_fwd_valid_ex;

    // Dedicated simple-address cone.  The architectural load path keeps its
    // general forwarding mux; only this early probe uses raw base + immediate.
    wire [31:0] ex_fast_load_addr =
        id_ex_base_addr_o + id_ex_mem_offset_o;
    wire ex_load_fast_eligible =
        ex_is_load_o && (id_ex_rs1_fwd_sel_o == FWD_REG);

    wire ex_load_branch_fast_hit =
        ex_load_fast_eligible &&
        ex_fast_load_cache_hit &&
        !fast_store_load_fwd_valid_ex;

    // A dependent branch advances only when the early cache probe proves a
    // clean resident hit.  Misses take the ordinary one-cycle ID interlock
    // and then use the registered MEM2 branch operand path.
    (* keep = "true" *) wire ex_load_late_bypass_pre =
        id_ex_is_load_valid &&
        !ctrl_kill_ex_o &&
        !ex_redirect_kill &&
        (!id_dec_is_branch_o || ex_load_branch_fast_hit) &&
        !id_dec_is_jalr_o &&
        !id_dec_has_deep_alu;

    // A false result here only inserts the ordinary one-cycle load-use stall.
    // A true result must guarantee that the signed 12-bit load offset stays
    // inside the 256 KiB DRAM window.  Only the boundary in the direction of
    // the offset matters: a negative offset is safe when base[17:12] != 0;
    // a non-negative offset is safe when base[17:12] != 63.  Boundary cases
    // take the ordinary stall.  This removes the address-adder carry chain
    // from frontend hold control without penalizing low-address positive
    // offsets, which are common in CoreMark structures.
    wire ex_load_bypass_base_interior =
        (fwd_load_base_addr_o[31:18] == 14'h2004) &&
        (id_ex_mem_offset_o[31] ?
            (|fwd_load_base_addr_o[17:12]) :
            !(&fwd_load_base_addr_o[17:12]));

    wire ex_load_late_bypass_allowed =
        ex_load_late_bypass_pre && ex_load_bypass_base_interior;

    assign mem_rd_reg_o  = ex_is_load_o;
    assign mem_rd_addr_o = ex_rd_mem_addr_o;

    wire ex_mem_store_hits_dram =
        (ex_mem_wd_addr_o >= DRAM_ADDR_START) &&
        (ex_mem_wd_addr_o <  DRAM_ADDR_END);

    // Qualify a same-word store without reintroducing the generic load
    // forwarding/address cone into the zero-stall branch decision.
    assign fast_store_load_fwd_valid_ex =
        ex_load_fast_eligible &&
        (|ex_mem_wd_reg_o) &&
        ex_mem_store_hits_dram &&
        (ex_fast_load_addr[31:2] == ex_mem_wd_addr_o[31:2]);

    assign store_load_fwd_valid_ex =
        ex_is_load_o &&
        ex_load_hits_dram_o &&
        (|ex_mem_wd_reg_o) &&
        ex_mem_store_hits_dram &&
        (ex_rd_mem_addr_o[31:2] == ex_mem_wd_addr_o[31:2]);

    wire [3:0]  store_load_fwd_wstrb_ex = ex_mem_wd_reg_o;
    wire [31:0] store_load_fwd_data_ex  = ex_mem_wd_data_o;

    wire        mem1_load_cache_hit;
    wire [31:0] mem1_rd_data_to_mem2;
    wire [31:0] mem1_pipe_rd_data =
        mem_out_is_load_o ? mem1_rd_data_to_mem2 : mem_out_rd_data_o;

    dram_cache #(
        .DRAM_ADDR_START(DRAM_ADDR_START),
        .DRAM_ADDR_END  (DRAM_ADDR_END),
        .INDEX_BITS     (`DCACHE_INDEX_BITS),
        // Every refill/store/architectural hit is confined to the aligned
        // 256 KiB DRAM window. Bits 31:18 are identical for all resident lines.
        .TAG_ADDR_MSB   (17),
        // ex_load_bypass_base_interior already proves that raw-base loads
        // and their signed offsets stay inside that same window.
        .FAST_PROBE_REGION_CHECK(1'b0)
    ) dram_cache_inst (
        .clk                         (clk),
        .rst                         (rst),
        .ex_load_addr_i              (ex_rd_mem_addr_o),
        .ex_fast_load_addr_i         (ex_fast_load_addr),
        .mem1_is_load_i              (ex_mem_is_load_o),
        .mem1_load_hits_dram_i       (ex_mem_load_hits_dram_o),
        .mem1_inst_i                 (ex_mem_inst_o),
        .mem1_load_addr_i            (ex_mem_mem_rd_addr_o),
        .mem1_uncached_rd_data_i     (mem_out_rd_data_o),
        .mem1_store_load_fwd_valid_i (ex_mem_store_load_fwd_valid_cache_o),
        .mem1_store_load_fwd_wstrb_i (ex_mem_store_load_fwd_wstrb_o),
        .mem1_store_load_fwd_data_i  (ex_mem_store_load_fwd_data_o),
        .mem2_is_load_i              (mem1_mem2_is_load_o),
        .mem2_load_hits_dram_i       (mem1_mem2_load_hits_dram_o),
        .mem2_load_cache_hit_i       (mem1_mem2_load_cache_hit_o),
        .mem2_load_addr_i            (mem1_mem2_mem_rd_addr_o),
        .mem2_ram_data_i             (ram_data_i),
        .mem2_store_load_fwd_valid_i (mem1_mem2_store_load_fwd_valid_cache_o),
        .mem2_store_load_fwd_wstrb_i (mem1_mem2_store_load_fwd_wstrb_o),
        .mem2_store_load_fwd_data_i  (mem1_mem2_store_load_fwd_data_o),
        .store_wstrb_i               (w_en),
        .store_addr_i                (w_addr_i),
        .store_data_i                (w_data_i),
        .mem1_load_cache_hit_o       (mem1_load_cache_hit),
        .mem1_rd_data_o              (mem1_rd_data_to_mem2),
        .ex_fast_load_cache_hit_o    (ex_fast_load_cache_hit),
        .branch_fast_load_valid_o    (branch_fast_load_valid),
        .branch_fast_load_data_o     (branch_fast_load_data)
    );
    // ==================================================================
    // Fetch / IF-ID / branch predictor accept control
    // ==================================================================

    // bp_fetch_* and bp_early_* are one indivisible synchronous-IROM packet:
    // PC, prediction validity, taken, target, type, GHR and epoch are captured
    // on the request edge and consumed only by the matching response.
    wire bp_fetch_epoch_match = (bp_fetch_epoch_r == fetch_epoch_r);
    wire use_held_prediction =
        ENABLE_REQUEST_STAGE_BP &&
        bp_fetch_valid_r &&
        bp_fetch_epoch_match &&
        bp_fetch_pred_valid_r;

    wire bp_if_valid =
        bp_fetch_valid_r &
        bp_fetch_epoch_match &
        ~bp_pred_flush_d1_r &
        ~use_held_prediction;

    // Select the live or held prediction as one complete packet.
    // Taken, target and prediction metadata must stay cycle-aligned.
    wire live_pred_valid     = bp_if_valid;
    wire held_pred_valid     = bp_fetch_valid_r & bp_fetch_epoch_match;

    wire effective_pred_valid =
        use_held_prediction ? held_pred_valid : live_pred_valid;
    wire effective_pred_taken =
        use_held_prediction ? bp_early_pred_taken_r : bp_pred_taken_o;
    wire [31:0] effective_pred_target =
        use_held_prediction ? bp_early_pred_target_r : bp_pred_target_o;
    wire [`BP_GHR_WIDTH-1:0] effective_pred_ghr =
        use_held_prediction ? bp_early_pred_ghr_r : bp_pred_ghr_o;
    wire [1:0] effective_pred_type =
        use_held_prediction ? bp_early_pred_type_r : bp_pred_type_o;

    wire [31:0] lane0_rs1_data;
    wire [31:0] lane0_rs2_data;
    wire [31:0] lane1_rs1_data;
    wire [31:0] lane1_rs2_data;
    wire        dual_dependency_wait;
    wire        lane0_rs1_side_newer;
    wire        lane0_rs2_side_newer;

    // A killed side-lane EX result is not merely prevented from retiring: it
    // must also disappear from the cross-lane bypass network immediately.
    //
    // Do not use bp_actual_taken_o here.  For a conditional branch,
    //
    //   actual_taken || prediction_mismatch
    //       == pred_taken || prediction_mismatch
    //
    // and ex_jump_en_o/load_branch_jump_en_o already identify the two kinds
    // of mismatch.  Selecting with the registered prediction is therefore
    // functionally identical, while breaking the long combinational loop
    // from the forwarding mux and branch comparator through Lane-1 forwarding,
    // fetch-pair control, the request predictor and back to PC.D.
    assign lane1_branch_squash =
        id_ex_valid_o && id_ex_is_branch_o &&
        (id_ex_pred_taken_o || ex_jump_en_o ||
         ex_load_branch_jump_en_o);
    assign lane1_kill_ex =
        ctrl_kill_ex_o || ex_redirect_kill || late_load_miss_o ||
        (ex_timer_irq_trap_o && !lane1_idex_older) ||
        lane1_branch_squash;

    // Retirement and same-cycle forwarding have different visibility rules.
    // A redirect, trap or late-load miss discards/holds the younger ID packet,
    // so that packet may harmlessly see the Lane-1 value before it is killed.
    // A correctly predicted taken branch is different: its target packet is
    // already in ID and must not observe the sequential Lane-1 instruction.
    // Keep that registered-prediction guard, but do not feed live cache-hit or
    // branch-comparison results back through dependency control into PC.D.
    wire lane1_forward_squash =
        id_ex_valid_o && id_ex_is_branch_o && id_ex_pred_taken_o;
    assign lane1_idex_forward_valid =
        lane1_idex_valid && !lane1_forward_squash;

`ifndef SYNTHESIS
    // Guard the Boolean substitution above against future changes to branch
    // redirect generation.  Sampling on the falling edge avoids delta-cycle
    // races between EX's combinational outputs and this check.
    wire lane1_branch_squash_reference =
        id_ex_valid_o && id_ex_is_branch_o &&
        (bp_actual_taken_o || ex_jump_en_o ||
         ex_load_branch_jump_en_o);
    wire lane1_kill_ex_reference =
        ctrl_kill_ex_o || ex_redirect_kill || late_load_miss_o ||
        (ex_timer_irq_trap_o && !lane1_idex_older) ||
        lane1_branch_squash_reference;
    always @(negedge clk) begin
        if (rst &&
            (lane1_kill_ex !== lane1_kill_ex_reference))
            $fatal(1,
                   "lane1 kill substitution mismatch: pred=%b actual=%b ex_redirect=%b load_redirect=%b ctrl_kill=%b",
                   id_ex_pred_taken_o, bp_actual_taken_o,
                   ex_jump_en_o, ex_load_branch_jump_en_o,
                   ctrl_kill_ex_o);
    end
`endif

    dual_issue_forwarding dual_issue_forwarding_inst (
        .id_valid_i              (if_id_valid_o),
        .pair_valid_i            (if_id_pair_valid_o),
        .lane1_id_rs1_i          (lane1_id_rs1),
        .lane1_id_rs2_i          (lane1_id_rs2),
        .lane1_id_use_rs1_i      (lane1_id_use_rs1),
        .lane1_id_use_rs2_i      (lane1_id_use_rs2),
        .lane0_id_use_rs1_i      (id_use_rs1_o),
        .lane0_id_rs1_i          (id_rs1_addr_o),
        .lane0_id_use_rs2_i      (id_use_rs2_o),
        .lane0_id_rs2_i          (id_rs2_addr_o),
        .lane0_reg_rs1_data_i    (regs_reg1_rdata_o),
        .lane0_reg_rs2_data_i    (regs_reg2_rdata_o),
        .lane1_reg_rs1_data_i    (regs_reg3_rdata_o),
        .lane1_reg_rs2_data_i    (regs_reg4_rdata_o),
        .main_idex_valid_i       (id_ex_valid_o),
        .main_idex_wen_i         (id_ex_reg_wen),
        .main_idex_rd_i          (id_ex_rd_addr_o),
        .main_idex_is_load_i     (id_ex_is_load_o),
        .main_idex_data_i        (ex_rd_data_o),
        .main_exmem_wen_i        (ex_mem_rd_wen_o),
        .main_exmem_rd_i         (ex_mem_pipe_rd_addr_o),
        .main_exmem_is_load_i    (ex_mem_is_load_o),
        .main_exmem_data_i       (ex_mem_rd_data_o),
        .main_mem2_wen_i         (mem1_mem2_rd_wen_o),
        .main_mem2_rd_i          (mem1_mem2_rd_addr_o),
        .main_mem2_is_load_i     (mem1_mem2_is_load_o),
        .main_mem2_load_ready_i  (~mem2_is_slow_load_o),
        .main_mem2_data_i        (mem2_rd_data_o),
        .side_idex_valid_i       (lane1_idex_forward_valid),
        .side_idex_rd_i          (lane1_idex_rd),
        .side_idex_data_i        (lane1_alu_result),
        .side_exmem_valid_i      (lane1_exmem_valid),
        .side_exmem_rd_i         (lane1_exmem_rd),
        .side_exmem_data_i       (lane1_exmem_data),
        .side_mem2_valid_i       (lane1_mem2_valid),
        .side_mem2_rd_i          (lane1_mem2_rd),
        .side_mem2_data_i        (lane1_mem2_data),
        .lane0_rs1_data_o        (lane0_rs1_data),
        .lane0_rs2_data_o        (lane0_rs2_data),
        .lane1_rs1_data_o        (lane1_rs1_data),
        .lane1_rs2_data_o        (lane1_rs2_data),
        .lane0_rs1_side_newer_o  (lane0_rs1_side_newer),
        .lane0_rs2_side_newer_o  (lane0_rs2_side_newer),
        .dependency_wait_o       (dual_dependency_wait)
    );

    wire core_hold_flag = hdu_hold_flag_o | dual_dependency_wait;
    // A late-load miss or an unfinished RV32M operation asks the HDU to hold
    // the current EX packet without flushing it. If a younger dual-issue
    // dependency happens in that same cycle, freeze only the frontend; do
    // not destroy the packet that must replay. Ordinary dual-dependency
    // stalls still inject one ID/EX bubble when the HDU itself is not holding.
    wire core_flush_flag = hdu_flush_flag_o |
        (dual_dependency_wait && !hdu_hold_flag_o);

    wire bp_replay_redirect =
        if_id_replaying_o &
        if_id_pred_taken_o &
        // A replay redirect invalidates the response currently returning from
        // the sequential path.  The delayed pulse still clears the following
        // pipeline slot after the replayed branch advances to ID/EX.
        ~bp_replay_flush_d1_r &
        ~core_hold_flag;

    // The redirect itself is persistent skid-packet state and feeds pc_reg's
    // run-next-PC cone without consulting live hit/hold.  This commit pulse is
    // only for epoch/flush bookkeeping after that packet is released.
    wire bp_load_hold_redirect_commit =
        if_id_load_branch_redirect_pending_o &&
        !core_hold_flag && !ctrl_jump_en_o &&
        !ex_timer_irq_trap_o;

    // A same-cycle EX redirect wins the final PC mux, while ctrl's registered
    // flush removes the stale response before it can advance.  Keep that live
    // redirect out of the response-predictor validity cone; otherwise branch
    // comparison is needlessly routed through the predictor and back to PC.D.
    wire irom_rsp_kill =
        ex_timer_irq_trap_o |
        bp_replay_redirect |
        bp_load_hold_redirect_commit;

    wire ifid_fetch_valid =
        effective_pred_valid &
        ~ctrl_flush_ifid_o &
        ~bp_pred_flush_d1_r &
        ~irom_rsp_kill;

    // IF/ID admission still rejects the stale response in the actual redirect
    // cycle.  This small local gate ends at IF/ID state and does not feed the
    // response predictor or the PC mux.
    wire ifid_admit_valid = ifid_fetch_valid & ~ctrl_jump_en_o;

    wire ifid_direct_fire =
        ifid_admit_valid &
        ~core_hold_flag &
        ~if_id_replay_pending_o;

    wire fetch_pair_accept = fetch_pair_raw & ifid_direct_fire;
    wire fetch_pair_swap_accept =
        fetch_pair_accept & fetch_pair_swap_raw;

    // Normally pc_reg_pc_o points at PC+4 of the returning IROM packet.  A
    // paired packet already contains that word, so the request must skip to
    // PC+8.  Immediately after any redirect, however, pc_reg_pc_o is the
    // redirect target itself rather than the sequential PC+4 pointer.  Do
    // not apply the pair skip to that first target request.
    // Do not map the hold condition onto FDRE.CE.  This state is replicated
    // by implementation and its CE arc otherwise becomes the endpoint of the
    // request-predictor/branch-recovery critical path.  A D-input feedback mux
    // is functionally identical and gives the data path the normal D setup arc.
    (* EXTRACT_ENABLE = "no" *) reg pc_is_redirect_target_r;

    // Address stepping only needs to know whether the valid returning packet
    // can consume both words.  Do not qualify it with the live redirect/flush
    // kill cone used by IF/ID admission.  Holds still suppress the skip so the
    // request address remains aligned with the frozen frontend packet.  On a
    // redirect cycle PC.D is overridden, the held-branch target below has
    // priority, or pc_is_redirect_target_r suppresses the first target skip.
    wire fetch_pair_step =
        fetch_pair_raw &
        effective_pred_valid &
        ~core_hold_flag &
        ~if_id_replay_pending_o &
        ~pc_is_redirect_target_r;
    // The FPGA wrapper only consumes PC[14:2] for its two 32 KiB ROM ports.
    // Form the +1/+2 word addresses in parallel from the registered PC, then
    // let the late pair decision select between already-computed values.  In
    // particular, do not put fetch_pair_step at the input of a carry chain:
    // cache-hit/replay hold logic is one of its inputs and used to traverse
    // the complete ROM address incrementer in the same cycle.
    wire [12:0] irom_word_addr_base = pc_reg_pc_o[14:2];
    (* keep = "true" *) wire [12:0] irom_word_addr_plus1 =
        irom_word_addr_base + 13'd1;
    (* keep = "true" *) wire [12:0] irom_word_addr_plus2 =
        irom_word_addr_base + 13'd2;

    assign irom_word_addr_o = fetch_pair_step ?
                              irom_word_addr_plus1 :
                              irom_word_addr_base;
    assign irom_word_addr_next_o = fetch_pair_step ?
                                   irom_word_addr_plus2 :
                                   irom_word_addr_plus1;

    // Keep the full byte address for request metadata and direct core-level
    // testbenches.  The FPGA IROM itself uses the word-address outputs above.
    assign irom_addr_o = fetch_pair_step ?
                         (pc_reg_pc_o + 32'd4) : pc_reg_pc_o;

    // Index the request predictor with the registered base PC.  If pair
    // stepping presents PC+4 to IROM, prediction is deferred to the response
    // stage.  Looking up PC+4 here would feed fetch_pair_step through the
    // BTB/BHT and back into PC.D, joining the load-replay and frontend paths.
    wire req_stage_pred_usable = ~fetch_pair_step;

    // Keep the prediction-to-PC redirect path independent from
    // predictor bookkeeping, statistics and update control.
    wire bp_fetch_redirect =
        ifid_fetch_valid &
        ~core_hold_flag &
        ~if_id_replay_pending_o &
        ~use_held_prediction &
        bp_pred_taken_o;
    assign bp_pc_redirect_valid = bp_fetch_redirect | bp_replay_redirect;
    assign bp_pc_redirect_target =
        bp_replay_redirect ? if_id_pred_target_o : bp_pred_target_o;

    // Recovery redirects start a new fetch epoch.  Correct request-stage
    // predictions do not advance it: their originating request remains valid
    // while only the following PC changes to the predicted target.
    wire fetch_epoch_advance =
        ctrl_jump_en_o |
        ex_timer_irq_trap_o |
        bp_pc_redirect_valid |
        bp_load_hold_redirect_commit;

    // A request is accepted exactly once.  During a hold, BRAM may still see
    // the held address electrically, but the corresponding response packet is
    // invalid.  Late/replay/EX redirects likewise invalidate the sequential
    // request captured on that edge.
    wire irom_req_fire =
        rst &
        ~core_hold_flag &
        ~ctrl_jump_en_o &
        ~ex_timer_irq_trap_o &
        ~bp_pc_redirect_valid &
        ~bp_load_hold_redirect_commit;

    // Request-stage redirect: the branch request itself remains valid and its
    // metadata is carried in the response packet; only the next PC changes.
    wire bp_early_redirect =
        ENABLE_REQUEST_STAGE_BP &
        irom_req_fire &
        req_stage_pred_usable &
        bp_req_pred_taken_o;

    // Select the final PC redirect valid and target in one priority block.
    // This keeps redirect control and target selection consistent and avoids
    // duplicated combinational cones feeding the PC update path.
    always @(*) begin
        pc_redirect_valid  = 1'b0;
        pc_redirect_target = 32'b0;

        if (ctrl_jump_en_o) begin
            pc_redirect_valid  = 1'b1;
            pc_redirect_target = ctrl_jump_addr_o;
        end else if (bp_pc_redirect_valid) begin
            pc_redirect_valid  = 1'b1;
            pc_redirect_target = bp_pc_redirect_target;
        end else if (bp_early_redirect) begin
            pc_redirect_valid  = 1'b1;
            pc_redirect_target = bp_req_pred_target_o;
        end
    end

    assign pc_jump_en_o   = pc_redirect_valid;
    assign pc_jump_addr_o = pc_redirect_target;

    // PC control has two orthogonal axes.  Every predictor redirect above is
    // qualified by irom_req_fire/ifid_direct_fire/bp_replay_redirect and thus
    // already implies !core_hold_flag.  Only an older EX/CTRL redirect must
    // override a younger frontend hold.  Keeping predictor lookup and target
    // selection out of this enable equation removes the long
    // branch->IF/ID->request-predictor->PC.CE timing cone without changing the
    // Boolean function:
    //   !hold | ctrl_redirect | (predictor_redirect & !hold)
    // = !hold | ctrl_redirect.
    wire pc_pipeline_enable = ~core_hold_flag | ctrl_jump_en_o;
    wire [31:0] pc_run_target =
        if_id_load_branch_redirect_pending_o ?
            if_id_load_branch_redirect_target_o :
            (pc_reg_pc_o + (fetch_pair_step ? 32'd8 : 32'd4));

    always @(posedge clk) begin
        if (rst == 1'b0) begin
            bp_fetch_valid_r         <= 1'b0;
            bp_fetch_pc_r            <= 32'h8000_0000;
            bp_pred_flush_d1_r       <= 1'b0;
            bp_replay_flush_d1_r     <= 1'b0;
            bp_load_hold_flush_d1_r  <= 1'b0;
            bp_fetch_pred_valid_r    <= 1'b0;
            bp_early_pred_taken_r    <= 1'b0;
            bp_early_pred_target_r   <= 32'b0;
            bp_early_pred_ghr_r      <= {`BP_GHR_WIDTH{1'b0}};
            bp_early_pred_type_r     <= `BP_PRED_NONE;
            fetch_epoch_r            <= 1'b0;
            bp_fetch_epoch_r         <= 1'b0;
            pc_is_redirect_target_r  <= 1'b0;
        end else begin
            // This register bank is the one-cycle IROM request/response tag.
            // inst_i observed after this edge belongs to this exact packet.
            bp_fetch_valid_r         <= irom_req_fire;
            bp_fetch_pc_r            <= irom_addr_o;
            bp_fetch_pred_valid_r    <=
                bp_req_pred_valid_o & req_stage_pred_usable;
            bp_early_pred_taken_r    <= bp_req_pred_taken_o;
            bp_early_pred_target_r   <= bp_req_pred_target_o;
            bp_early_pred_ghr_r      <= bp_req_pred_ghr_o;
            bp_early_pred_type_r     <= bp_req_pred_type_o;
            bp_fetch_epoch_r         <= fetch_epoch_r;

            if (fetch_epoch_advance) begin
                fetch_epoch_r <= ~fetch_epoch_r;
            end

            // The late predictor redirects after the sequential request has
            // reached IROM.  Suppress that one-cycle ghost response.
            bp_pred_flush_d1_r       <=
                bp_pc_redirect_valid | bp_load_hold_redirect_commit;

            // Keep the existing one-cycle replay pipeline clear pulse.
            bp_replay_flush_d1_r     <= bp_replay_redirect;
            bp_load_hold_flush_d1_r  <= bp_load_hold_redirect_commit;

            // Track the meaning of pc_reg_pc_o across holds.  When the PC
            // register does not advance, its target/sequential role is also
            // unchanged.
            pc_is_redirect_target_r <= pc_pipeline_enable ?
                                       pc_redirect_valid :
                                       pc_is_redirect_target_r;
        end
    end

    wire frontend_flush_ifid =
        ex_timer_irq_trap_o |
        ctrl_flush_ifid_o |
        bp_replay_flush_d1_r |
        bp_load_hold_flush_d1_r;

    wire frontend_flush_idex =
        ex_timer_irq_trap_o |
        ctrl_flush_idex_o |
        bp_replay_flush_d1_r;

`ifndef SYNTHESIS
    // A request-stage prediction is safe only if its metadata returns beside
    // the instruction for the same PC and epoch.  These checks catch future
    // edits that accidentally delay one packet field independently.
    always @(negedge clk) begin
        if (rst && use_held_prediction) begin
            if ((bp_early_pred_type_r == `BP_PRED_BRANCH) &&
                (inst_i[6:0] != `INST_TYPE_B)) begin
                $fatal(1, "request BP packet mismatch: branch type pc=%08x inst=%08x",
                       bp_fetch_pc_r, inst_i);
            end
            if ((bp_early_pred_type_r == `BP_PRED_JALR) &&
                (inst_i[6:0] != `INST_JALR)) begin
                $fatal(1, "request BP packet mismatch: JALR type pc=%08x inst=%08x",
                       bp_fetch_pc_r, inst_i);
            end
        end
        if (rst && bp_fetch_valid_r && !bp_fetch_epoch_match &&
            ifid_fetch_valid) begin
            $fatal(1, "stale IROM response accepted across fetch epoch");
        end
    end
`endif

    // ==================================================================
    // Branch predictor
    // ==================================================================
    branch_predictor #(
        .ENABLE_REQUEST_INDIRECT_PRED(ENABLE_REQUEST_INDIRECT_BP)
    ) branch_predictor_inst (
        .clk             (clk),
        .rst             (rst),
        .if_valid_i      (bp_if_valid),
        .if_inst_i       (inst_i),
        .if_pc_i         (bp_fetch_pc_r),
        .if_ghr_i        (bp_early_pred_ghr_r),
        .req_pc_i        (pc_reg_pc_o),
        .req_btb_hit_o   (bp_req_btb_hit_o),
        .req_pred_valid_o(bp_req_pred_valid_o),
        .req_pred_taken_o(bp_req_pred_taken_o),
        .req_pred_target_o(bp_req_pred_target_o),
        .req_pred_ghr_o  (bp_req_pred_ghr_o),
        .req_pred_type_o (bp_req_pred_type_o),
        .pred_taken_o    (bp_pred_taken_o),
        .pred_target_o   (bp_pred_target_o),
        .pred_ghr_o      (bp_pred_ghr_o),
        .pred_type_o     (bp_pred_type_o),
        .update_en_i     (mem_wb_bp_update_en_o),
        .update_pc_word_i(mem_wb_bp_update_pc_o[31:2]),
        .update_target_i (mem_wb_bp_update_target_o),
        .update_ghr_i    (mem_wb_bp_update_ghr_o),
        .ras_push_en_i   (bp_ras_push_en_o),
        .ras_pop_en_i    (bp_ras_pop_en_o),
        .ras_push_addr_i (bp_ras_push_addr_o),
        .jalr_update_en_i(bp_jalr_update_en_o),
        .jalr_update_pc_i(bp_jalr_update_pc_o),
        .jalr_update_target_i(bp_jalr_update_target_o),
        .jalr_update_ghr_i(bp_jalr_update_ghr_o),
        .jalr_update_is_call_i(bp_jalr_update_is_call_o),
        .actual_taken_i  (mem_wb_bp_actual_taken_o)
    );

    // ==================================================================
    // PC
    // ==================================================================

    pc_reg pc_reg_inst (
        .clk         (clk),
        .rst         (rst),
        .pc_enable_i (pc_pipeline_enable),
        .redirect_valid_i(pc_jump_en_o),
        .redirect_target_i(pc_jump_addr_o),
        .run_target_i(pc_run_target),
        .pc_o        (pc_reg_pc_o)
    );

    // ==================================================================
    // IF/ID
    // ==================================================================
    if_id if_id_inst (
        .clk                (clk),
        .rst                (rst),
        .load_valid_i       (ifid_admit_valid),
        .inst_i             (inst_i),
        .inst2_i            (inst_next_i),
        .pair_valid_i       (fetch_pair_accept),
        .pair_swap_i        (fetch_pair_swap_accept),
        .inst_addr_i        (bp_fetch_pc_r),
        .pred_taken_i       (effective_pred_taken),
        .pred_target_i      (effective_pred_target),
        .pred_ghr_i         (effective_pred_ghr),
        .pred_type_i        (effective_pred_type),
        .redirect_already_issued_i(
            use_held_prediction && effective_pred_taken),
        .hold_flag_i        (core_hold_flag),
        .load_branch_hold_i (load_branch_hold_o),
        .flush_flag_i       (frontend_flush_ifid),
        .inst_addr_o        (if_id_inst_addr_o),
        .pred_taken_o       (if_id_pred_taken_o),
        .pred_target_o      (if_id_pred_target_o),
        .pred_ghr_o         (if_id_pred_ghr_o),
        .pred_type_o        (if_id_pred_type_o),
        .redirect_already_issued_o(
            if_id_redirect_already_issued_o),
        .inst_o             (if_id_inst_o),
        .inst2_o            (if_id_inst2_o),
        .pair_valid_o       (if_id_pair_valid_o),
        .pair_swap_o        (if_id_pair_swap_o),
        .valid_o            (if_id_valid_o),
        .load_valid_o       (if_id_load_valid_o),
        .load_pred_taken_o  (if_id_load_pred_taken_o),
        .load_pred_target_o (if_id_load_pred_target_o),
        .replaying_o        (if_id_replaying_o),
        .replay_pending_o   (if_id_replay_pending_o),
        .load_branch_redirect_pending_o(if_id_load_branch_redirect_pending_o),
        .load_branch_redirect_target_o(if_id_load_branch_redirect_target_o)
    );

    // ==================================================================
    // Regfile
    // ==================================================================
    regs regs_inst (
        .clk          (clk),
        .reg1_raddr_i (id_rs1_addr_o),
        .reg2_raddr_i (id_rs2_addr_o),
        .reg1_rdata_o (regs_reg1_rdata_o),
        .reg2_rdata_o (regs_reg2_rdata_o),
        .reg3_raddr_i (lane1_id_rs1),
        .reg4_raddr_i (lane1_id_rs2),
        .reg3_rdata_o (regs_reg3_rdata_o),
        .reg4_rdata_o (regs_reg4_rdata_o),
        .reg_wen      (wb_rd_wen_o),
        .reg_waddr_i  (wb_rd_addr_o),
        .reg_wdata_i  (wb_rd_data_o),
        .reg2_wen     (lane1_wb_valid),
        .reg2_waddr_i (lane1_wb_rd),
        .reg2_wdata_i (lane1_wb_data)
    );

    // ==================================================================
    // ID
    // ==================================================================
    wire [31:0] lane0_issue_inst = if_id_pair_swap_o ?
        if_id_inst2_o : if_id_inst_o;
    wire [31:0] lane0_issue_pc = if_id_inst_addr_o +
        (if_id_pair_swap_o ? 32'd4 : 32'd0);
    wire [31:0] lane1_issue_inst = if_id_pair_swap_o ?
        if_id_inst_o : if_id_inst2_o;
    wire [31:0] lane1_issue_pc = if_id_inst_addr_o +
        (if_id_pair_swap_o ? 32'd0 : 32'd4);

    id id_inst (
        .inst_i          (lane0_issue_inst),
        .inst_addr_i     (lane0_issue_pc),
        .rs1_data_i      (lane0_rs1_data),
        .rs2_data_i      (lane0_rs2_data),
        .rs1_addr_o      (id_rs1_addr_o),
        .rs2_addr_o      (id_rs2_addr_o),
        .inst_o          (id_inst_o),
        .inst_addr_o     (id_inst_addr_o),
        .op1_o           (id_op1_o),
        .op2_o           (id_op2_o),
        .cmp_op2_o       (id_cmp_op2_o),
        .store_data_o    (id_store_data_o),
        .rd_addr_o       (id_rd_addr_o),
        .reg_wen         (id_reg_wen),
        .base_addr_o     (id_base_addr_o),
        .branch_offset_o (id_branch_offset_o),
        .mem_offset_o    (id_mem_offset_o),
        .jump_offset_o   (id_jump_offset_o),
        .branch_cond_o   (id_branch_cond_o),
        .mem_rd_reg_o    (data_read_en),
        .is_branch_o     (id_is_branch_o),
        .use_rs1_o       (id_use_rs1_o),
        .use_rs2_o       (id_use_rs2_o),
        .use_base_addr_o (id_use_base_addr_o),
        .ex_func3_o      (id_dec_func3_o),
        .ex_func7_bit5_o (id_dec_func7_bit5_o),
        .ex_func7_is_r_o (id_dec_func7_is_r_o),
        .ex_func7_is_sub_o(id_dec_func7_is_sub_o),
        .ex_is_op_imm_o  (id_dec_is_op_imm_o),
        .ex_is_op_reg_o  (id_dec_is_op_reg_o),
        .ex_is_branch_o  (id_dec_is_branch_o),
        .ex_is_load_o    (id_dec_is_load_o),
        .ex_is_store_o   (id_dec_is_store_o),
        .ex_is_jal_o     (id_dec_is_jal_o),
        .ex_is_jalr_o    (id_dec_is_jalr_o),
        .ex_is_auipc_o   (id_dec_is_auipc_o),
        .ex_is_lui_o     (id_dec_is_lui_o),
        .ex_is_system_o  (id_dec_is_system_o),
        .ex_is_rv32m_o   (id_dec_is_rv32m_o),
        .ex_is_csr_op_o  (id_dec_is_csr_op_o),
        .ex_is_call_jal_o(id_dec_is_call_jal_o),
        .ex_ras_should_push_jalr_o(id_dec_ras_should_push_jalr_o),
        .ex_ras_should_pop_jalr_o (id_dec_ras_should_pop_jalr_o),
        .ex_ras_predicted_jalr_o  (id_dec_ras_predicted_jalr_o)
    );

    // ==================================================================
    // Early forwarding select
    // ==================================================================
    early_forwarding_select early_forwarding_select_inst (
        .id_rs1_addr_i         (id_rs1_addr_o),
        .id_rs2_addr_i         (id_rs2_addr_o),
        .id_use_rs1_i          (id_use_rs1_o),
        .id_use_rs2_i          (id_use_rs2_o),
        .id_use_base_addr_i    (id_use_base_addr_o),
        .id_is_branch_i        (id_dec_is_branch_o),
        .rs1_side_newer_i      (lane0_rs1_side_newer),
        .rs2_side_newer_i      (lane0_rs2_side_newer),
        .ex_rd_addr_i          (id_ex_rd_addr_o),
        .ex_rd_wen_i           (id_ex_reg_wen_valid),
        .ex_is_load_i          (id_ex_is_load_valid),
        .ex_load_hits_dram_i   (ex_load_late_bypass_allowed),
        .mem1_rd_addr_i        (ex_mem_pipe_rd_addr_o),
        .mem1_rd_wen_i         (ex_mem_rd_wen_o),
        .mem1_is_load_i        (ex_mem_is_load_o),
        .mem1_load_hits_dram_i (ex_mem_load_hits_dram_o),
        .mem1_load_cache_hit_i (mem1_load_cache_hit),
        .mem1_load_fast_eligible_i(ex_mem_load_fast_eligible_o),
        .mem1_store_load_fwd_valid_i(ex_mem_store_load_fwd_valid_pipe_o),
        .mem2_rd_addr_i        (mem2_rd_addr_o),
        .mem2_rd_wen_i         (mem2_rd_wen_o),
        .mem2_is_slow_load_i   (mem2_is_slow_load_o),
        .rs1_fwd_sel_o         (id_rs1_fwd_sel_o),
        .rs2_fwd_sel_o         (id_rs2_fwd_sel_o)
    );

    // ==================================================================
    // ID/EX
    // ==================================================================
    id_ex id_ex_inst (
        .clk             (clk),
        .rst             (rst),
        .hold_flag_i     (core_hold_flag),
        // Flush invalidates one bit only.  The legacy bundle-clear input is
        // constant so no replay/flush cone reaches hundreds of register Rs.
        .flush_flag_i    (1'b0),
        .valid_i         (if_id_valid_o),
        .valid_flush_i   (core_flush_flag | frontend_flush_idex),
        .inst_i          (id_inst_o),
        .inst_addr_i     (id_inst_addr_o),
        .op1_i           (id_op1_o),
        .op2_i           (id_op2_o),
        .cmp_op2_i       (id_cmp_op2_o),
        .store_data_i    (id_store_data_o),
        .pred_taken_i    (if_id_pred_taken_o),
        .pred_target_i   (if_id_pred_target_o),
        .pred_ghr_i      (if_id_pred_ghr_o),
        .pred_type_i     (if_id_pred_type_o),
        .rs1_addr_i      (id_rs1_addr_o),
        .rs2_addr_i      (id_rs2_addr_o),
        .rs1_fwd_sel_i   (id_rs1_fwd_sel_o),
        .rs2_fwd_sel_i   (id_rs2_fwd_sel_o),
        .use_rs1_i       (id_use_rs1_o),
        .use_rs2_i       (id_use_rs2_o),
        .use_base_addr_i (id_use_base_addr_o),
        .rd_addr_i       (id_rd_addr_o),
        .reg_wen_i       (id_reg_wen),
        .base_addr_i     (id_base_addr_o),
        .branch_offset_i (id_branch_offset_o),
        .mem_offset_i    (id_mem_offset_o),
        .jump_offset_i   (id_jump_offset_o),
        .branch_cond_i   (id_branch_cond_o),
        .ex_func3_i      (id_dec_func3_o),
        .ex_func7_bit5_i (id_dec_func7_bit5_o),
        .ex_func7_is_r_i (id_dec_func7_is_r_o),
        .ex_func7_is_sub_i(id_dec_func7_is_sub_o),
        .ex_is_op_imm_i  (id_dec_is_op_imm_o),
        .ex_is_op_reg_i  (id_dec_is_op_reg_o),
        .ex_is_branch_i  (id_dec_is_branch_o),
        .ex_is_load_i    (id_dec_is_load_o),
        .ex_is_store_i   (id_dec_is_store_o),
        .ex_is_jal_i     (id_dec_is_jal_o),
        .ex_is_jalr_i    (id_dec_is_jalr_o),
        .ex_is_auipc_i   (id_dec_is_auipc_o),
        .ex_is_lui_i     (id_dec_is_lui_o),
        .ex_is_system_i  (id_dec_is_system_o),
        .ex_is_rv32m_i   (id_dec_is_rv32m_o),
        .ex_is_csr_op_i  (id_dec_is_csr_op_o),
        .ex_is_call_jal_i(id_dec_is_call_jal_o),
        .ex_ras_should_push_jalr_i(id_dec_ras_should_push_jalr_o),
        .ex_ras_should_pop_jalr_i (id_dec_ras_should_pop_jalr_o),
        .ex_ras_predicted_jalr_i  (id_dec_ras_predicted_jalr_o),
        .inst_o          (id_ex_inst_o),
        .valid_o         (id_ex_valid_o),
        .inst_addr_o     (id_ex_inst_addr_o),
        .op1_o           (id_ex_op1_o),
        .op2_o           (id_ex_op2_o),
        .cmp_op2_o       (id_ex_cmp_op2_o),
        .store_data_o    (id_ex_store_data_o),
        .pred_taken_o    (id_ex_pred_taken_o),
        .pred_target_o   (id_ex_pred_target_o),
        .pred_ghr_o      (id_ex_pred_ghr_o),
        .pred_type_o     (id_ex_pred_type_o),
        .rs1_addr_o      (id_ex_rs1_addr_o),
        .rs2_addr_o      (id_ex_rs2_addr_o),
        .rs1_fwd_sel_o   (id_ex_rs1_fwd_sel_o),
        .rs2_fwd_sel_o   (id_ex_rs2_fwd_sel_o),
        .use_rs1_o       (id_ex_use_rs1_o),
        .use_rs2_o       (id_ex_use_rs2_o),
        .use_base_addr_o (id_ex_use_base_addr_o),
        .rd_addr_o       (id_ex_rd_addr_o),
        .reg_wen_o       (id_ex_reg_wen),
        .base_addr_o     (id_ex_base_addr_o),
        .branch_offset_o (id_ex_branch_offset_o),
        .mem_offset_o    (id_ex_mem_offset_o),
        .jump_offset_o   (id_ex_jump_offset_o),
        .branch_cond_o   (id_ex_branch_cond_o),
        .ex_func3_o      (id_ex_func3_o),
        .ex_func7_bit5_o (id_ex_func7_bit5_o),
        .ex_func7_is_r_o (id_ex_func7_is_r_o),
        .ex_func7_is_sub_o(id_ex_func7_is_sub_o),
        .ex_is_op_imm_o  (id_ex_is_op_imm_o),
        .ex_is_op_reg_o  (id_ex_is_op_reg_o),
        .ex_is_branch_o  (id_ex_is_branch_o),
        .ex_is_load_o    (id_ex_is_load_o),
        .ex_is_store_o   (id_ex_is_store_o),
        .ex_is_jal_o     (id_ex_is_jal_o),
        .ex_is_jalr_o    (id_ex_is_jalr_o),
        .ex_is_auipc_o   (id_ex_is_auipc_o),
        .ex_is_lui_o     (id_ex_is_lui_o),
        .ex_is_system_o  (id_ex_is_system_o),
        .ex_is_rv32m_o   (id_ex_is_rv32m_o),
        .ex_is_csr_op_o  (id_ex_is_csr_op_o),
        .ex_is_call_jal_o(id_ex_is_call_jal_o),
        .ex_ras_should_push_jalr_o(id_ex_ras_should_push_jalr_o),
        .ex_ras_should_pop_jalr_o (id_ex_ras_should_pop_jalr_o),
        .ex_ras_predicted_jalr_o  (id_ex_ras_predicted_jalr_o)
    );

    // ==================================================================
    // Lane 1: side-effect-free integer pipeline
    // ==================================================================
    dual_issue_lane dual_issue_lane_inst (
        .clk             (clk),
        .rst_n           (rst),
        .inst_i          (lane1_issue_inst),
        .pc_i            (lane1_issue_pc),
        .issue_valid_i   (if_id_valid_o && if_id_pair_valid_o),
        .issue_older_i   (if_id_pair_swap_o),
        .hold_i          (core_hold_flag),
        .wait_ex_i       (ex_rv32m_busy_o && !ex_rv32m_done_o),
        .flush_i         (core_flush_flag || frontend_flush_idex),
        .kill_ex_i       (lane1_kill_ex),
        .rs1_data_i      (lane1_rs1_data),
        .rs2_data_i      (lane1_rs2_data),
        .id_rs1_o        (lane1_id_rs1),
        .id_rs2_o        (lane1_id_rs2),
        .id_use_rs1_o    (lane1_id_use_rs1),
        .id_use_rs2_o    (lane1_id_use_rs2),
        .idex_valid_o    (lane1_idex_valid),
        .idex_older_o    (lane1_idex_older),
        .idex_rd_o       (lane1_idex_rd),
        .ex_result_o     (lane1_alu_result),
        .exmem_valid_o   (lane1_exmem_valid),
        .exmem_rd_o      (lane1_exmem_rd),
        .exmem_data_o    (lane1_exmem_data),
        .mem2_valid_o    (lane1_mem2_valid),
        .mem2_rd_o       (lane1_mem2_rd),
        .mem2_data_o     (lane1_mem2_data),
        .wb_valid_o      (lane1_wb_valid),
        .wb_inst_o       (lane1_wb_inst),
        .wb_rd_o         (lane1_wb_rd),
        .wb_data_o       (lane1_wb_data)
    );

    // Do not force max_fanout on wide datapath buses.
    // Excessive register replication can worsen physical routing timing.
    assign mem2_is_slow_load_o = mem1_mem2_is_load_o &&
                                  ~mem1_mem2_load_hits_dram_o;

    // ==================================================================
    // Forwarding
    // ==================================================================
    forwarding forwarding_inst (
        .clk                      (clk),
        .rst                      (rst),
        .late_load_miss_i         (late_load_miss_o),
        .id_ex_op1_i              (id_ex_op1_o),
        .id_ex_op2_i              (id_ex_op2_o),
        .id_ex_cmp_op2_i          (id_ex_cmp_op2_o),
        .id_ex_store_data_i       (id_ex_store_data_o),
        .id_ex_ls_base_addr_i     (id_ex_base_addr_o),
        .id_ex_rs1_fwd_sel_i      (id_ex_rs1_fwd_sel_o),
        .id_ex_rs2_fwd_sel_i      (id_ex_rs2_fwd_sel_o),
        .ex_mem_rd_data_i         (ex_mem_rd_data_o),
        .mem1_mem2_rd_data_i      (mem1_mem2_rd_data_o),
        .mem1_load_rd_data_i      (mem1_rd_data_to_mem2),
        .mem2_rd_data_i           (mem2_rd_data_o),
        .mem_wb_rd_data_i         (mem_wb_rd_data_fwd_o),
        .fwd_op1_o                (fwd_op1_o),
        .fwd_op2_o                (fwd_op2_o),
        .fwd_rv32m_op1_o          (fwd_rv32m_op1_o),
        .fwd_rv32m_op2_o          (fwd_rv32m_op2_o),
        .fwd_cmp_op2_o            (fwd_cmp_op2_o),
        .fwd_br_op1_o             (fwd_br_op1_o),
        .fwd_br_op2_o             (fwd_br_op2_o),
        .fwd_store_data_o         (fwd_store_data_o),
        .fwd_load_base_addr_o     (fwd_load_base_addr_o),
        .fwd_store_base_addr_o    (fwd_store_base_addr_o),
        .fwd_jalr_base_addr_o     (fwd_jalr_base_addr_o)
    );

    // A clean DCache hit is tagged for a dedicated comparator inside EX.
    // The 32-bit cache data never rejoins the normal/MEM2 branch operand mux;
    // selection happens after comparison on a one-bit condition result.
    wire branch_fast_rs1_use =
        id_ex_valid_o && id_ex_is_branch_o && branch_fast_load_valid &&
        (id_ex_rs1_fwd_sel_o == FWD_LATE_LOAD);
    wire branch_fast_rs2_use =
        id_ex_valid_o && id_ex_is_branch_o && branch_fast_load_valid &&
        (id_ex_rs2_fwd_sel_o == FWD_LATE_LOAD);

    // Only a load-dependent conditional branch takes the registered recovery
    // path.  Correct predictions generate no redirect and therefore pay no
    // extra cycle; ordinary branches, JAL/JALR and traps remain combinational.
    wire branch_mem2_rs1_use =
        id_ex_valid_o && id_ex_is_branch_o &&
        (id_ex_rs1_fwd_sel_o == FWD_MEM2_LOAD);
    wire branch_mem2_rs2_use =
        id_ex_valid_o && id_ex_is_branch_o &&
        (id_ex_rs2_fwd_sel_o == FWD_MEM2_LOAD);
    // Classify the path only from registered ID/EX metadata.  In particular,
    // do not use branch_fast_load_valid here: that live cache tag result must
    // terminate at the dedicated load comparator rather than reach PC logic.
    wire load_dependent_branch_ex =
        id_ex_valid_o && id_ex_is_branch_o &&
        ((id_ex_rs1_fwd_sel_o == FWD_LATE_LOAD) ||
         (id_ex_rs2_fwd_sel_o == FWD_LATE_LOAD) ||
         (id_ex_rs1_fwd_sel_o == FWD_MEM2_LOAD) ||
         (id_ex_rs2_fwd_sel_o == FWD_MEM2_LOAD));
    wire load_branch_redirect_now =
        ex_load_branch_jump_en_o && !ex_timer_irq_trap_o;

    always @(posedge clk) begin
        if (rst == 1'b0) begin
            load_branch_redirect_valid_r  <= 1'b0;
            load_branch_redirect_target_r <= 32'b0;
        end else begin
            load_branch_redirect_valid_r <= load_branch_redirect_now;
            // The valid bit is the only architectural qualifier for this
            // target.  Updating the data register every cycle avoids an
            // inferred 32-bit clock-enable whose input was the full cache-hit
            // and branch-decision cone.  That CE path was the final 150 MHz
            // setup violation; the target remains ignored whenever valid=0.
            load_branch_redirect_target_r <= ex_load_branch_jump_addr_o;
        end
    end

    // The registered redirect is older than the instruction currently in EX.
    // Kill that younger instruction immediately while retaining ctrl's normal
    // delayed flush for the synchronous-IROM ghost response.
    assign ex_redirect_kill = load_branch_redirect_valid_r;
    wire ex_jump_en_to_ctrl =
        load_branch_redirect_valid_r || ex_jump_en_o;
    wire [31:0] ex_jump_addr_to_ctrl =
        load_branch_redirect_valid_r ? load_branch_redirect_target_r :
        ex_jump_addr_o;

    // ==================================================================
    // HDU
    // ==================================================================
    Hazard_detection_unit hdu_inst (
        .id_inst_i            (id_inst_o),
        .id_rs1_addr_i        (id_rs1_addr_o),
        .id_rs2_addr_i        (id_rs2_addr_o),
        .id_use_rs1_i         (id_use_rs1_o),
        .id_use_rs2_i         (id_use_rs2_o),
        .id_is_branch_i       (id_dec_is_branch_o),
        .id_is_rv32m_i        (id_dec_is_rv32m_o),
        .ex_inst_i            (id_ex_inst_o),
        .ex_valid_i           (id_ex_valid_o),
        .ex_load_late_bypass_pre_i(ex_load_late_bypass_pre),
        .ex_load_hits_dram_raw_i  (ex_load_bypass_base_interior),
        .id_ex_rs1_fwd_sel_i  (id_ex_rs1_fwd_sel_o),
        .id_ex_rs2_fwd_sel_i  (id_ex_rs2_fwd_sel_o),
        .mem1_inst_i          (ex_mem_inst_o),
        .mem1_load_hits_dram_i(ex_mem_load_hits_dram_o),
        .mem1_load_cache_hit_i(mem1_load_cache_hit),
        .mem2_inst_i          (mem1_mem2_inst_o),
        .mem2_is_slow_load_i  (mem2_is_slow_load_o),
        .ex_busy_i            (ex_rv32m_busy_o),
        .ex_done_i            (ex_rv32m_done_o),
        .hold_flag_o          (hdu_hold_flag_o),
        .flush_flag_o         (hdu_flush_flag_o),
        .load_branch_hold_o   (load_branch_hold_o),
        .late_load_miss_o     (late_load_miss_o)
    );

    // ==================================================================
    // EX
    // ==================================================================
    ex ex_inst (
        .clk                 (clk),
        .rst                 (rst),
        .valid_i             (id_ex_valid_o),
        .timer_irq_i         (timer_irq_i),
        .inst_i              (id_ex_inst_o),
        .inst_addr_i         (id_ex_inst_addr_o),
        .fwd_op1_i           (fwd_op1_o),
        .fwd_op2_i           (fwd_op2_o),
        .rv32m_op1_i         (fwd_rv32m_op1_o),
        .rv32m_op2_i         (fwd_rv32m_op2_o),
        .fwd_cmp_op2_i       (fwd_cmp_op2_o),
        .fwd_br_op1_i        (fwd_br_op1_o),
        .fwd_br_op2_i        (fwd_br_op2_o),
        .branch_fast_load_data_i(branch_fast_load_data),
        .branch_fast_rs1_i   (branch_fast_rs1_use),
        .branch_fast_rs2_i   (branch_fast_rs2_use),
        .branch_mem2_load_data_i(mem2_rd_data_o),
        .branch_mem2_rs1_i   (branch_mem2_rs1_use),
        .branch_mem2_rs2_i   (branch_mem2_rs2_use),
        .load_dependent_branch_i(load_dependent_branch_ex),
        .store_data_i        (fwd_store_data_o),
        .pred_taken_i        (id_ex_pred_taken_o),
        .pred_target_i       (id_ex_pred_target_o),
        .pred_ghr_i          (id_ex_pred_ghr_o),
        .pred_type_i         (id_ex_pred_type_o),
        .rd_addr_i           (id_ex_rd_addr_o),
        .rd_wen_i            (id_ex_reg_wen),
        .kill_i              (ctrl_kill_ex_o | ex_redirect_kill |
                              late_load_miss_o),
        .fwd_load_base_i     (fwd_load_base_addr_o),
        .fwd_store_base_i    (fwd_store_base_addr_o),
        .fwd_jalr_base_i     (fwd_jalr_base_addr_o),
        .branch_offset_i     (id_ex_branch_offset_o),
        .mem_offset_i        (id_ex_mem_offset_o),
        .jump_offset_i       (id_ex_jump_offset_o),
        .branch_cond_i       (id_ex_branch_cond_o),
        .dec_func3_i         (id_ex_func3_o),
        .dec_func7_bit5_i    (id_ex_func7_bit5_o),
        .dec_func7_is_r_i    (id_ex_func7_is_r_o),
        .dec_func7_is_sub_i  (id_ex_func7_is_sub_o),
        .dec_is_op_imm_i     (id_ex_is_op_imm_o),
        .dec_is_op_reg_i     (id_ex_is_op_reg_o),
        .dec_is_branch_i     (id_ex_is_branch_o),
        .dec_is_load_i       (id_ex_is_load_o),
        .dec_is_store_i      (id_ex_is_store_o),
        .dec_is_jal_i        (id_ex_is_jal_o),
        .dec_is_jalr_i       (id_ex_is_jalr_o),
        .dec_is_auipc_i      (id_ex_is_auipc_o),
        .dec_is_lui_i        (id_ex_is_lui_o),
        .dec_is_system_i     (id_ex_is_system_o),
        .dec_is_rv32m_i      (id_ex_is_rv32m_o),
        .dec_is_csr_op_i     (id_ex_is_csr_op_o),
        .dec_is_call_jal_i   (id_ex_is_call_jal_o),
        .dec_ras_should_push_jalr_i(id_ex_ras_should_push_jalr_o),
        .dec_ras_should_pop_jalr_i (id_ex_ras_should_pop_jalr_o),
        .dec_ras_predicted_jalr_i  (id_ex_ras_predicted_jalr_o),
        .rd_addr_o           (ex_rd_addr_o),
        .rd_wen_o            (ex_rd_wen_o),
        .rd_data_o           (ex_rd_data_o),
        .jump_addr_o         (ex_jump_addr_o),
        .jump_en_o           (ex_jump_en_o),
        .load_branch_jump_addr_o(ex_load_branch_jump_addr_o),
        .load_branch_jump_en_o(ex_load_branch_jump_en_o),
        .mem_wd_reg_o        (ex_wd_reg_o),
        .mem_wd_addr_o       (ex_wd_addr_o),
        .mem_wd_data_o       (ex_wd_data_o),
        .mem_rd_addr_o       (ex_rd_mem_addr_o),
        .is_load_o           (ex_is_load_o),
        .load_hits_dram_o    (ex_load_hits_dram_o),
        .inst_o              (ex_inst_o),
        .bp_update_en_o      (bp_update_en_o),
        .bp_update_pc_o      (bp_update_pc_o),
        .bp_update_target_o  (bp_update_target_o),
        .bp_update_ghr_o     (bp_update_ghr_o),
        .bp_ras_push_en_o    (bp_ras_push_en_o),
        .bp_ras_pop_en_o     (bp_ras_pop_en_o),
        .bp_ras_push_addr_o  (bp_ras_push_addr_o),
        .bp_jalr_update_en_o (bp_jalr_update_en_o),
        .bp_jalr_update_pc_o (bp_jalr_update_pc_o),
        .bp_jalr_update_target_o(bp_jalr_update_target_o),
        .bp_jalr_update_ghr_o(bp_jalr_update_ghr_o),
        .bp_jalr_update_is_call_o(bp_jalr_update_is_call_o),
        .bp_actual_taken_o   (bp_actual_taken_o),
        .rv32m_busy_o        (ex_rv32m_busy_o),
        .rv32m_done_o        (ex_rv32m_done_o),
        .timer_irq_trap_o    (ex_timer_irq_trap_o)
    );

    // ==================================================================
    // CTRL
    // ==================================================================
    ctrl ctrl_inst (
        .clk          (clk),
        .rst          (rst),
        .jump_addr_i  (ex_jump_addr_to_ctrl),
        .jump_en_i    (ex_jump_en_to_ctrl),
        .jump_en_o    (ctrl_jump_en_o),
        .jump_addr_o  (ctrl_jump_addr_o),
        .kill_ex_o    (ctrl_kill_ex_o),
        .flush_ifid_o (ctrl_flush_ifid_o),
        .flush_idex_o (ctrl_flush_idex_o)
    );

    // ==================================================================
    // EX/MEM1
    // ==================================================================
    ex_mem1 ex_mem_inst (
        .clk               (clk),
        .rst               (rst),
        .inst_i            (ex_inst_o),
        .rd_addr_i         (ex_rd_addr_o),
        .rd_data_i         (ex_rd_data_o),
        .rd_wen_i          (ex_rd_wen_o),
        .mem_wd_reg_i      (ex_wd_reg_o),
        .mem_wd_addr_i     (ex_wd_addr_o),
        .mem_wd_data_i     (ex_wd_data_o),
        .mem_rd_addr_i     (ex_rd_mem_addr_o),
        .is_load_i         (ex_is_load_o),
        .load_hits_dram_i  (ex_load_hits_dram_o),
        .load_fast_eligible_i(ex_load_fast_eligible),
        .store_load_fwd_valid_i(store_load_fwd_valid_ex),
        .store_load_fwd_wstrb_i(store_load_fwd_wstrb_ex),
        .store_load_fwd_data_i (store_load_fwd_data_ex),
        .bp_update_en_i    (bp_update_en_o),
        .bp_update_pc_i    (bp_update_pc_o),
        .bp_update_target_i(bp_update_target_o),
        .bp_update_ghr_i   (bp_update_ghr_o),
        .bp_actual_taken_i (bp_actual_taken_o),
        .rd_addr_o         (ex_mem_pipe_rd_addr_o),
        .rd_data_o         (ex_mem_rd_data_o),
        .rd_wen_o          (ex_mem_rd_wen_o),
        .mem_wd_reg_o      (ex_mem_wd_reg_o),
        .mem_wd_addr_o     (ex_mem_wd_addr_o),
        .mem_wd_data_o     (ex_mem_wd_data_o),
        .mem_rd_addr_o     (ex_mem_mem_rd_addr_o),
        .is_load_o         (ex_mem_is_load_o),
        .load_hits_dram_o  (ex_mem_load_hits_dram_o),
        .load_fast_eligible_o(ex_mem_load_fast_eligible_o),
        .store_load_fwd_valid_o(ex_mem_store_load_fwd_valid_o),
        .store_load_fwd_valid_cache_o(ex_mem_store_load_fwd_valid_cache_o),
        .store_load_fwd_valid_pipe_o (ex_mem_store_load_fwd_valid_pipe_o),
        .store_load_fwd_wstrb_o(ex_mem_store_load_fwd_wstrb_o),
        .store_load_fwd_data_o (ex_mem_store_load_fwd_data_o),
        .bp_update_en_o    (ex_mem_bp_update_en_o),
        .bp_update_pc_o    (ex_mem_bp_update_pc_o),
        .bp_update_target_o(ex_mem_bp_update_target_o),
        .bp_update_ghr_o   (ex_mem_bp_update_ghr_o),
        .bp_actual_taken_o (ex_mem_bp_actual_taken_o),
        .inst_o            (ex_mem_inst_o)
    );

    // ==================================================================
    // MEM1
    // ==================================================================
    mem1 mem_inst (
        .inst_i        (ex_mem_inst_o),
        .rd_addr_i     (ex_mem_pipe_rd_addr_o),
        .rd_data_i     (ex_mem_rd_data_o),
        .rd_wen_i      (ex_mem_rd_wen_o),
        .mem_rd_addr_i (ex_mem_mem_rd_addr_o),
        .mem_wd_reg_i  (ex_mem_wd_reg_o),
        .mem_wd_addr_i (ex_mem_wd_addr_o),
        .mem_wd_data_i (ex_mem_wd_data_o),
        .is_load_i     (ex_mem_is_load_o),
        .rd_addr_o     (mem_out_rd_addr_o),
        .rd_data_o     (mem_out_rd_data_o),
        .rd_wen_o      (mem_out_rd_wen_o),
        .mem_rd_addr_o (mem_out_mem_rd_addr_o),
        .mem_wd_reg_o  (w_en),
        .mem_wd_addr_o (w_addr_i),
        .mem_wd_data_o (w_data_i),
        .inst_o        (mem_inst_o),
        .is_load_o     (mem_out_is_load_o)
    );

    // ==================================================================
    // MEM1/MEM2
    // ==================================================================
    mem1_mem2 mem1_mem2_inst (
        .clk               (clk),
        .rst               (rst),
        .inst_i            (mem_inst_o),
        .rd_addr_i         (mem_out_rd_addr_o),
        .rd_data_i         (mem1_pipe_rd_data),
        .rd_wen_i          (mem_out_rd_wen_o),
        .mem_rd_addr_i     (mem_out_mem_rd_addr_o),
        .is_load_i         (mem_out_is_load_o),
        .load_hits_dram_i  (ex_mem_load_hits_dram_o),
        .load_cache_hit_i  (mem1_load_cache_hit),
        .store_load_fwd_valid_i(ex_mem_store_load_fwd_valid_pipe_o),
        .store_load_fwd_wstrb_i(ex_mem_store_load_fwd_wstrb_o),
        .store_load_fwd_data_i (ex_mem_store_load_fwd_data_o),
        .bp_update_en_i    (ex_mem_bp_update_en_o),
        .bp_update_pc_i    (ex_mem_bp_update_pc_o),
        .bp_update_target_i(ex_mem_bp_update_target_o),
        .bp_update_ghr_i   (ex_mem_bp_update_ghr_o),
        .bp_actual_taken_i (ex_mem_bp_actual_taken_o),
        .rd_addr_o         (mem1_mem2_rd_addr_o),
        .rd_data_o         (mem1_mem2_rd_data_o),
        .rd_wen_o          (mem1_mem2_rd_wen_o),
        .mem_rd_addr_o     (mem1_mem2_mem_rd_addr_o),
        .is_load_o         (mem1_mem2_is_load_o),
        .load_hits_dram_o  (mem1_mem2_load_hits_dram_o),
        .load_cache_hit_o  (mem1_mem2_load_cache_hit_o),
        .store_load_fwd_valid_o(mem1_mem2_store_load_fwd_valid_o),
        .store_load_fwd_valid_cache_o(mem1_mem2_store_load_fwd_valid_cache_o),
        .store_load_fwd_valid_mem2_o (mem1_mem2_store_load_fwd_valid_mem2_o),
        .store_load_fwd_wstrb_o(mem1_mem2_store_load_fwd_wstrb_o),
        .store_load_fwd_data_o (mem1_mem2_store_load_fwd_data_o),
        .bp_update_en_o    (mem1_mem2_bp_update_en_o),
        .bp_update_pc_o    (mem1_mem2_bp_update_pc_o),
        .bp_update_target_o(mem1_mem2_bp_update_target_o),
        .bp_update_ghr_o   (mem1_mem2_bp_update_ghr_o),
        .bp_actual_taken_o (mem1_mem2_bp_actual_taken_o),
        .inst_o            (mem1_mem2_inst_o)
    );

    // ==================================================================
    // MEM2
    // ==================================================================
    mem2 mem2_inst (
        .inst_i        (mem1_mem2_inst_o),
        .rd_addr_i     (mem1_mem2_rd_addr_o),
        .rd_data_i     (mem1_mem2_rd_data_o),
        .rd_wen_i      (mem1_mem2_rd_wen_o),
        .mem_rd_addr_i (mem1_mem2_mem_rd_addr_o),
        .is_load_i     (mem1_mem2_is_load_o),
        .load_cache_hit_i(mem1_mem2_load_cache_hit_o),
        .mem_rd_data_i (ram_data_i),
        .store_load_fwd_valid_i(mem1_mem2_store_load_fwd_valid_mem2_o),
        .store_load_fwd_wstrb_i(mem1_mem2_store_load_fwd_wstrb_o),
        .store_load_fwd_data_i (mem1_mem2_store_load_fwd_data_o),
        .rd_addr_o     (mem2_rd_addr_o),
        .rd_data_o     (mem2_rd_data_o),
        .rd_wen_o      (mem2_rd_wen_o),
        .inst_o        (mem2_inst_o)
    );

    // ==================================================================
    // MEM2/WB
    // ==================================================================
    mem2_wb mem_wb_inst (
        .clk               (clk),
        .rst               (rst),
        .inst_i            (mem2_inst_o),
        .rd_addr_i         (mem2_rd_addr_o),
        .rd_data_i         (mem2_rd_data_o),
        .rd_wen_i          (mem2_rd_wen_o),
        .mem_rd_addr_i     (mem1_mem2_mem_rd_addr_o),
        .is_slow_load_i    (mem2_is_slow_load_o),
        .bp_update_en_i    (mem1_mem2_bp_update_en_o),
        .bp_update_pc_i    (mem1_mem2_bp_update_pc_o),
        .bp_update_target_i(mem1_mem2_bp_update_target_o),
        .bp_update_ghr_i   (mem1_mem2_bp_update_ghr_o),
        .bp_actual_taken_i (mem1_mem2_bp_actual_taken_o),
        .rd_addr_o         (mem_wb_rd_addr_o),
        .rd_data_o         (mem_wb_rd_data_o),
        .rd_wen_o          (mem_wb_rd_wen_o),
        .mem_rd_addr_o     (mem_wb_mem_rd_addr_o),
        .is_slow_load_o    (mem_wb_is_slow_load_o),
        .bp_update_en_o    (mem_wb_bp_update_en_o),
        .bp_update_pc_o    (mem_wb_bp_update_pc_o),
        .bp_update_target_o(mem_wb_bp_update_target_o),
        .bp_update_ghr_o   (mem_wb_bp_update_ghr_o),
        .bp_actual_taken_o (mem_wb_bp_actual_taken_o),
        .inst_o            (mem_wb_inst_o),
        .rd_data_fwd_o      (mem_wb_rd_data_fwd_o)
    );


    // ==================================================================
    // WB
    // ==================================================================
    wb wb_inst (
        .inst_i         (mem_wb_inst_o),
        .rd_addr_i      (mem_wb_rd_addr_o),
        .rd_data_i      (mem_wb_rd_data_o),
        .rd_wen_i       (mem_wb_rd_wen_o),
        .mem_rd_addr_i  (mem_wb_mem_rd_addr_o),
        .is_slow_load_i (mem_wb_is_slow_load_o),
        .mmio_data_i    (mmio_data_i),
        .inst_o         (),
        .rd_data_o      (wb_rd_data_o),
        .rd_wen_o       (wb_rd_wen_o),
        .rd_addr_o      (wb_rd_addr_o)
    );

endmodule
