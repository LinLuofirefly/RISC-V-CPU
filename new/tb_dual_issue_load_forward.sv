`timescale 1ns / 1ps

module tb_dual_issue_load_forward;
    reg         pair_valid = 1'b1;
    reg         mem2_load_ready = 1'b0;
    wire [31:0] lane1_rs1_data;
    wire [31:0] lane1_rs2_data;
    wire        dependency_wait;

    dual_issue_forwarding dut (
        .id_valid_i(1'b1),
        .pair_valid_i(pair_valid),
        .lane1_id_rs1_i(5'd5),
        .lane1_id_rs2_i(5'd0),
        .lane1_id_use_rs1_i(1'b1),
        .lane1_id_use_rs2_i(1'b0),
        .lane0_id_use_rs1_i(1'b0),
        .lane0_id_rs1_i(5'd0),
        .lane0_id_use_rs2_i(1'b0),
        .lane0_id_rs2_i(5'd0),
        .lane0_reg_rs1_data_i(32'b0),
        .lane0_reg_rs2_data_i(32'b0),
        .lane1_reg_rs1_data_i(32'hdead_beef),
        .lane1_reg_rs2_data_i(32'b0),

        .main_idex_valid_i(1'b0),
        .main_idex_wen_i(1'b0),
        .main_idex_rd_i(5'd0),
        .main_idex_is_load_i(1'b0),
        .main_idex_data_i(32'b0),
        .main_exmem_wen_i(1'b0),
        .main_exmem_rd_i(5'd0),
        .main_exmem_is_load_i(1'b0),
        .main_exmem_data_i(32'b0),
        .main_mem2_wen_i(1'b1),
        .main_mem2_rd_i(5'd5),
        .main_mem2_is_load_i(1'b1),
        .main_mem2_load_ready_i(mem2_load_ready),
        .main_mem2_data_i(32'h8000_0081),

        .side_idex_valid_i(1'b0),
        .side_idex_rd_i(5'd0),
        .side_idex_data_i(32'b0),
        .side_exmem_valid_i(1'b0),
        .side_exmem_rd_i(5'd0),
        .side_exmem_data_i(32'b0),
        .side_mem2_valid_i(1'b0),
        .side_mem2_rd_i(5'd0),
        .side_mem2_data_i(32'b0),

        .lane0_rs1_data_o(),
        .lane0_rs2_data_o(),
        .lane1_rs1_data_o(lane1_rs1_data),
        .lane1_rs2_data_o(lane1_rs2_data),
        .lane0_rs1_side_newer_o(),
        .lane0_rs2_side_newer_o(),
        .dependency_wait_o(dependency_wait)
    );

    initial begin
        #1;
        if (!dependency_wait)
            $fatal(1, "slow MEM2 load did not interlock");
        if (lane1_rs1_data !== 32'hdead_beef)
            $fatal(1, "slow load leaked early data=%08x", lane1_rs1_data);

        mem2_load_ready = 1'b1;
        #1;
        if (dependency_wait)
            $fatal(1, "ready MEM2 load still interlocked");
        if (lane1_rs1_data !== 32'h8000_0081)
            $fatal(1, "ready MEM2 load bypass mismatch=%08x",
                   lane1_rs1_data);

        pair_valid = 1'b0;
        #1;
        if (dependency_wait || (lane1_rs1_data !== 32'hdead_beef))
            $fatal(1, "inactive pair used cross-lane load bypass");

        $display("TB_PASS dual MEM2 load forwarding");
        $finish;
    end
endmodule
