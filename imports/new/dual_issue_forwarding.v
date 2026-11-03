`ifndef DUAL_ISSUE_FORWARDING_V
`define DUAL_ISSUE_FORWARDING_V

// Cross-lane forwarding and conservative dependency interlock.
module dual_issue_forwarding (
    input  wire        id_valid_i,
    input  wire        pair_valid_i,
    input  wire [4:0]  lane1_id_rs1_i,
    input  wire [4:0]  lane1_id_rs2_i,
    input  wire        lane1_id_use_rs1_i,
    input  wire        lane1_id_use_rs2_i,
    input  wire        lane0_id_use_rs1_i,
    input  wire [4:0]  lane0_id_rs1_i,
    input  wire        lane0_id_use_rs2_i,
    input  wire [4:0]  lane0_id_rs2_i,
    input  wire [31:0] lane0_reg_rs1_data_i,
    input  wire [31:0] lane0_reg_rs2_data_i,
    input  wire [31:0] lane1_reg_rs1_data_i,
    input  wire [31:0] lane1_reg_rs2_data_i,

    input  wire        main_idex_valid_i,
    input  wire        main_idex_wen_i,
    input  wire [4:0]  main_idex_rd_i,
    input  wire        main_idex_is_load_i,
    input  wire [31:0] main_idex_data_i,
    input  wire        main_exmem_wen_i,
    input  wire [4:0]  main_exmem_rd_i,
    input  wire        main_exmem_is_load_i,
    input  wire [31:0] main_exmem_data_i,
    input  wire        main_mem2_wen_i,
    input  wire [4:0]  main_mem2_rd_i,
    input  wire        main_mem2_is_load_i,
    input  wire        main_mem2_load_ready_i,
    input  wire [31:0] main_mem2_data_i,

    input  wire        side_idex_valid_i,
    input  wire [4:0]  side_idex_rd_i,
    input  wire [31:0] side_idex_data_i,
    input  wire        side_exmem_valid_i,
    input  wire [4:0]  side_exmem_rd_i,
    input  wire [31:0] side_exmem_data_i,
    input  wire        side_mem2_valid_i,
    input  wire [4:0]  side_mem2_rd_i,
    input  wire [31:0] side_mem2_data_i,

    output wire [31:0] lane0_rs1_data_o,
    output wire [31:0] lane0_rs2_data_o,
    output wire [31:0] lane1_rs1_data_o,
    output wire [31:0] lane1_rs2_data_o,
    output wire        lane0_rs1_side_newer_o,
    output wire        lane0_rs2_side_newer_o,
    output wire        dependency_wait_o
);

    wire lane1_rs1_main_idex = pair_valid_i && lane1_id_use_rs1_i &&
        (lane1_id_rs1_i != 5'b0) && main_idex_valid_i &&
        main_idex_wen_i && (main_idex_rd_i == lane1_id_rs1_i);
    wire lane1_rs1_main_exmem = pair_valid_i && lane1_id_use_rs1_i &&
        (lane1_id_rs1_i != 5'b0) && main_exmem_wen_i &&
        (main_exmem_rd_i == lane1_id_rs1_i);
    wire lane1_rs1_main_mem2 = pair_valid_i && lane1_id_use_rs1_i &&
        (lane1_id_rs1_i != 5'b0) && main_mem2_wen_i &&
        (main_mem2_rd_i == lane1_id_rs1_i);
    wire lane1_rs2_main_idex = pair_valid_i && lane1_id_use_rs2_i &&
        (lane1_id_rs2_i != 5'b0) && main_idex_valid_i &&
        main_idex_wen_i && (main_idex_rd_i == lane1_id_rs2_i);
    wire lane1_rs2_main_exmem = pair_valid_i && lane1_id_use_rs2_i &&
        (lane1_id_rs2_i != 5'b0) && main_exmem_wen_i &&
        (main_exmem_rd_i == lane1_id_rs2_i);
    wire lane1_rs2_main_mem2 = pair_valid_i && lane1_id_use_rs2_i &&
        (lane1_id_rs2_i != 5'b0) && main_mem2_wen_i &&
        (main_mem2_rd_i == lane1_id_rs2_i);

    wire lane1_src1_wait_main =
        (lane1_rs1_main_idex && main_idex_is_load_i) ||
        (!lane1_rs1_main_idex && lane1_rs1_main_exmem &&
         main_exmem_is_load_i) ||
        (!lane1_rs1_main_idex && !lane1_rs1_main_exmem &&
         lane1_rs1_main_mem2 && main_mem2_is_load_i &&
         !main_mem2_load_ready_i);
    wire lane1_src2_wait_main =
        (lane1_rs2_main_idex && main_idex_is_load_i) ||
        (!lane1_rs2_main_idex && lane1_rs2_main_exmem &&
         main_exmem_is_load_i) ||
        (!lane1_rs2_main_idex && !lane1_rs2_main_exmem &&
         lane1_rs2_main_mem2 && main_mem2_is_load_i &&
         !main_mem2_load_ready_i);

    wire lane0_rs1_side_idex = lane0_id_use_rs1_i &&
        (lane0_id_rs1_i != 5'b0) && side_idex_valid_i &&
        (side_idex_rd_i == lane0_id_rs1_i);
    wire lane0_rs1_side_exmem = lane0_id_use_rs1_i &&
        (lane0_id_rs1_i != 5'b0) && side_exmem_valid_i &&
        (side_exmem_rd_i == lane0_id_rs1_i);
    wire lane0_rs1_side_mem2 = lane0_id_use_rs1_i &&
        (lane0_id_rs1_i != 5'b0) && side_mem2_valid_i &&
        (side_mem2_rd_i == lane0_id_rs1_i);
    wire lane0_rs2_side_idex = lane0_id_use_rs2_i &&
        (lane0_id_rs2_i != 5'b0) && side_idex_valid_i &&
        (side_idex_rd_i == lane0_id_rs2_i);
    wire lane0_rs2_side_exmem = lane0_id_use_rs2_i &&
        (lane0_id_rs2_i != 5'b0) && side_exmem_valid_i &&
        (side_exmem_rd_i == lane0_id_rs2_i);
    wire lane0_rs2_side_mem2 = lane0_id_use_rs2_i &&
        (lane0_id_rs2_i != 5'b0) && side_mem2_valid_i &&
        (side_mem2_rd_i == lane0_id_rs2_i);

    wire lane0_rs1_main_idex = lane0_id_use_rs1_i &&
        (lane0_id_rs1_i != 5'b0) &&
        main_idex_valid_i && main_idex_wen_i &&
        (main_idex_rd_i == lane0_id_rs1_i);
    wire lane0_rs1_main_exmem = lane0_id_use_rs1_i &&
        (lane0_id_rs1_i != 5'b0) &&
        main_exmem_wen_i && (main_exmem_rd_i == lane0_id_rs1_i);
    wire lane0_rs1_main_mem2 = lane0_id_use_rs1_i &&
        (lane0_id_rs1_i != 5'b0) &&
        main_mem2_wen_i && (main_mem2_rd_i == lane0_id_rs1_i);
    wire lane0_rs2_main_idex = lane0_id_use_rs2_i &&
        (lane0_id_rs2_i != 5'b0) &&
        main_idex_valid_i && main_idex_wen_i &&
        (main_idex_rd_i == lane0_id_rs2_i);
    wire lane0_rs2_main_exmem = lane0_id_use_rs2_i &&
        (lane0_id_rs2_i != 5'b0) &&
        main_exmem_wen_i && (main_exmem_rd_i == lane0_id_rs2_i);
    wire lane0_rs2_main_mem2 = lane0_id_use_rs2_i &&
        (lane0_id_rs2_i != 5'b0) &&
        main_mem2_wen_i && (main_mem2_rd_i == lane0_id_rs2_i);

    wire lane0_rs1_main_pending = lane0_rs1_main_idex ||
        lane0_rs1_main_exmem || lane0_rs1_main_mem2;
    wire lane0_rs2_main_pending = lane0_rs2_main_idex ||
        lane0_rs2_main_exmem || lane0_rs2_main_mem2;

    wire lane1_pipe_writes_id_rs1 =
        (lane0_rs1_side_idex || lane0_rs1_side_exmem ||
         lane0_rs1_side_mem2) && lane0_rs1_main_pending;
    wire lane1_pipe_writes_id_rs2 =
        (lane0_rs2_side_idex || lane0_rs2_side_exmem ||
         lane0_rs2_side_mem2) && lane0_rs2_main_pending;

    // Resolve simultaneous main/side versions by packet age instead of
    // stalling until one disappears.  An earlier pipeline stage is always the
    // younger producer.  When the side producer is newest, the normal main
    // forwarding selector must fall back to the side value captured in ID.
    assign lane0_rs1_side_newer_o =
        (lane0_rs1_side_idex && !lane0_rs1_main_idex) ||
        (!lane0_rs1_main_idex && lane0_rs1_side_exmem &&
         !lane0_rs1_main_exmem) ||
        (!lane0_rs1_main_idex && !lane0_rs1_main_exmem &&
         lane0_rs1_side_mem2 && !lane0_rs1_main_mem2);
    assign lane0_rs2_side_newer_o =
        (lane0_rs2_side_idex && !lane0_rs2_main_idex) ||
        (!lane0_rs2_main_idex && lane0_rs2_side_exmem &&
         !lane0_rs2_main_exmem) ||
        (!lane0_rs2_main_idex && !lane0_rs2_main_exmem &&
         lane0_rs2_side_mem2 && !lane0_rs2_main_mem2);

    wire lane1_rs1_side_idex = pair_valid_i && lane1_id_use_rs1_i &&
        (lane1_id_rs1_i != 5'b0) && side_idex_valid_i &&
        (side_idex_rd_i == lane1_id_rs1_i);
    wire lane1_rs1_side_exmem = pair_valid_i && lane1_id_use_rs1_i &&
        (lane1_id_rs1_i != 5'b0) && side_exmem_valid_i &&
        (side_exmem_rd_i == lane1_id_rs1_i);
    wire lane1_rs1_side_mem2 = pair_valid_i && lane1_id_use_rs1_i &&
        (lane1_id_rs1_i != 5'b0) && side_mem2_valid_i &&
        (side_mem2_rd_i == lane1_id_rs1_i);
    wire lane1_rs2_side_idex = pair_valid_i && lane1_id_use_rs2_i &&
        (lane1_id_rs2_i != 5'b0) && side_idex_valid_i &&
        (side_idex_rd_i == lane1_id_rs2_i);
    wire lane1_rs2_side_exmem = pair_valid_i && lane1_id_use_rs2_i &&
        (lane1_id_rs2_i != 5'b0) && side_exmem_valid_i &&
        (side_exmem_rd_i == lane1_id_rs2_i);
    wire lane1_rs2_side_mem2 = pair_valid_i && lane1_id_use_rs2_i &&
        (lane1_id_rs2_i != 5'b0) && side_mem2_valid_i &&
        (side_mem2_rd_i == lane1_id_rs2_i);

    wire lane1_rs1_main_pending = lane1_rs1_main_idex ||
        lane1_rs1_main_exmem || lane1_rs1_main_mem2;
    wire lane1_rs2_main_pending = lane1_rs2_main_idex ||
        lane1_rs2_main_exmem || lane1_rs2_main_mem2;
    wire lane1_pipe_writes_lane1_rs1 =
        (lane1_rs1_side_idex || lane1_rs1_side_exmem ||
         lane1_rs1_side_mem2) && lane1_rs1_main_pending;
    wire lane1_pipe_writes_lane1_rs2 =
        (lane1_rs2_side_idex || lane1_rs2_side_exmem ||
         lane1_rs2_side_mem2) && lane1_rs2_main_pending;

    assign lane0_rs1_data_o =
        lane0_rs1_side_idex  ? side_idex_data_i :
        lane0_rs1_side_exmem ? side_exmem_data_i :
        lane0_rs1_side_mem2  ? side_mem2_data_i : lane0_reg_rs1_data_i;
    assign lane0_rs2_data_o =
        lane0_rs2_side_idex  ? side_idex_data_i :
        lane0_rs2_side_exmem ? side_exmem_data_i :
        lane0_rs2_side_mem2  ? side_mem2_data_i : lane0_reg_rs2_data_i;
    assign lane1_rs1_data_o =
        lane1_rs1_side_idex  ? side_idex_data_i :
        lane1_rs1_side_exmem ? side_exmem_data_i :
        lane1_rs1_side_mem2  ? side_mem2_data_i :
        (lane1_rs1_main_idex && !main_idex_is_load_i) ? main_idex_data_i :
        (lane1_rs1_main_exmem && !main_exmem_is_load_i) ?
            main_exmem_data_i :
        (lane1_rs1_main_mem2 &&
         (!main_mem2_is_load_i || main_mem2_load_ready_i)) ?
            main_mem2_data_i : lane1_reg_rs1_data_i;
    assign lane1_rs2_data_o =
        lane1_rs2_side_idex  ? side_idex_data_i :
        lane1_rs2_side_exmem ? side_exmem_data_i :
        lane1_rs2_side_mem2  ? side_mem2_data_i :
        (lane1_rs2_main_idex && !main_idex_is_load_i) ? main_idex_data_i :
        (lane1_rs2_main_exmem && !main_exmem_is_load_i) ?
            main_exmem_data_i :
        (lane1_rs2_main_mem2 &&
         (!main_mem2_is_load_i || main_mem2_load_ready_i)) ?
            main_mem2_data_i : lane1_reg_rs2_data_i;

    assign dependency_wait_o = id_valid_i &&
        (lane1_src1_wait_main || lane1_src2_wait_main ||
         lane1_pipe_writes_lane1_rs1 || lane1_pipe_writes_lane1_rs2);

endmodule

`endif
