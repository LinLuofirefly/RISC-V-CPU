`ifndef DUAL_ISSUE_PAIRING_V
`define DUAL_ISSUE_PAIRING_V

// Selects independent pairs for the full main pipeline and the integer side
// lane.  A younger load/store may use the main lane while its older ALU peer
// is swapped into the side lane.
module dual_issue_pairing #(
    parameter ENABLE_DUAL_ISSUE = 1'b1,
    parameter [7:0] OP_IMM_MASK = 8'hff,
    parameter [7:0] OP_REG_MASK = 8'hff,
    // bit0=integer, bit1=RV32M, bit2=load, bit3=store, bit4=branch.
    // Branch pairing is disabled: allowing a younger side-lane instruction
    // beside a branch can leave a stale side-pipeline version across redirect
    // sequences. CoreMark's linked-list workload exposes the corruption.
    parameter [4:0] LANE0_CLASS_MASK = 5'b0_1111
) (
    input  wire [2:0]  fetch_pc_i,
    input  wire [31:0] inst0_i,
    input  wire [31:0] inst1_i,
    output wire        pair_eligible_o,
    output wire        pair_swap_o
);

    // Every implemented instruction is 32-bit and therefore has opcode bit 1
    // set. Comparing [6:1] instead of all seven opcode bits maps each opcode
    // test into one LUT6; bit 0 is redundant for the supported instruction
    // stream. Share these predecodes between class selection and hazards.
    localparam [5:0] OP6_IMM    = 6'b001001;
    localparam [5:0] OP6_REG    = 6'b011001;
    localparam [5:0] OP6_LOAD   = 6'b000001;
    localparam [5:0] OP6_STORE  = 6'b010001;
    localparam [5:0] OP6_BRANCH = 6'b110001;
    localparam [5:0] OP6_LUI    = 6'b011011;
    localparam [5:0] OP6_AUIPC  = 6'b001011;

    wire op0_imm    = inst0_i[6:1] == OP6_IMM;
    wire op0_reg    = inst0_i[6:1] == OP6_REG;
    wire op0_load   = inst0_i[6:1] == OP6_LOAD;
    wire op0_store  = inst0_i[6:1] == OP6_STORE;
    wire op0_branch = inst0_i[6:1] == OP6_BRANCH;
    wire op0_lui    = inst0_i[6:1] == OP6_LUI;
    wire op0_auipc  = inst0_i[6:1] == OP6_AUIPC;

    wire op1_imm    = inst1_i[6:1] == OP6_IMM;
    wire op1_reg    = inst1_i[6:1] == OP6_REG;
    wire op1_load   = inst1_i[6:1] == OP6_LOAD;
    wire op1_store  = inst1_i[6:1] == OP6_STORE;
    wire op1_lui    = inst1_i[6:1] == OP6_LUI;
    wire op1_auipc  = inst1_i[6:1] == OP6_AUIPC;

    wire op0_rv32i_reg = op0_reg &&
        ((inst0_i[31:25] == `INST_FUNC7_R) ||
         ((inst0_i[31:25] == `INST_FUNC7_SUB) &&
          ((inst0_i[14:12] == `INST_ADD_SUB) ||
           (inst0_i[14:12] == `INST_SR))));
    wire op1_rv32i_reg = op1_reg &&
        ((inst1_i[31:25] == `INST_FUNC7_R) ||
         ((inst1_i[31:25] == `INST_FUNC7_SUB) &&
          ((inst1_i[14:12] == `INST_ADD_SUB) ||
           (inst1_i[14:12] == `INST_SR))));

    wire op0_imm_shift_legal =
        (inst0_i[14:12] != `INST_SLLI) &&
        (inst0_i[14:12] != `INST_SRI) ? 1'b1 :
        (inst0_i[31:25] == `INST_FUNC7_R) ||
        ((inst0_i[14:12] == `INST_SRI) &&
         (inst0_i[31:25] == `INST_FUNC7_SUB));
    wire op1_imm_shift_legal =
        (inst1_i[14:12] != `INST_SLLI) &&
        (inst1_i[14:12] != `INST_SRI) ? 1'b1 :
        (inst1_i[31:25] == `INST_FUNC7_R) ||
        ((inst1_i[14:12] == `INST_SRI) &&
         (inst1_i[31:25] == `INST_FUNC7_SUB));

    wire lane1_inst0 =
        (op0_imm && OP_IMM_MASK[inst0_i[14:12]] &&
         op0_imm_shift_legal) ||
        (op0_rv32i_reg && OP_REG_MASK[inst0_i[14:12]]) ||
        op0_lui || op0_auipc;
    wire lane1_inst1 =
        (op1_imm && OP_IMM_MASK[inst1_i[14:12]] &&
         op1_imm_shift_legal) ||
        (op1_rv32i_reg && OP_REG_MASK[inst1_i[14:12]]) ||
        op1_lui || op1_auipc;

    wire load0_legal = op0_load &&
        ((inst0_i[14:12] == `INST_LB) ||
         (inst0_i[14:12] == `INST_LH) ||
         (inst0_i[14:12] == `INST_LW) ||
         (inst0_i[14:12] == `INST_LBU) ||
         (inst0_i[14:12] == `INST_LHU));
    wire load1_legal = op1_load &&
        ((inst1_i[14:12] == `INST_LB) ||
         (inst1_i[14:12] == `INST_LH) ||
         (inst1_i[14:12] == `INST_LW) ||
         (inst1_i[14:12] == `INST_LBU) ||
         (inst1_i[14:12] == `INST_LHU));
    wire store0_legal = op0_store &&
        ((inst0_i[14:12] == `INST_SB) ||
         (inst0_i[14:12] == `INST_SH) ||
         (inst0_i[14:12] == `INST_SW));
    wire store1_legal = op1_store &&
        ((inst1_i[14:12] == `INST_SB) ||
         (inst1_i[14:12] == `INST_SH) ||
         (inst1_i[14:12] == `INST_SW));
    wire branch0_legal = op0_branch &&
        ((inst0_i[14:12] == `INST_BEQ) ||
         (inst0_i[14:12] == `INST_BNE) ||
         (inst0_i[14:12] == `INST_BLT) ||
         (inst0_i[14:12] == `INST_BGE) ||
         (inst0_i[14:12] == `INST_BLTU) ||
         (inst0_i[14:12] == `INST_BGEU));

    wire lane0_inst0 =
        (LANE0_CLASS_MASK[0] && lane1_inst0) ||
        (LANE0_CLASS_MASK[1] && op0_reg &&
         (inst0_i[31:25] == `INST_FUNC7_M)) ||
        (LANE0_CLASS_MASK[2] && load0_legal) ||
        (LANE0_CLASS_MASK[3] && store0_legal) ||
        (LANE0_CLASS_MASK[4] && branch0_legal);

    wire lane0_has_rd = (inst0_i[11:7] != 5'b0) &&
        (op0_imm || op0_reg || op0_load || op0_lui || op0_auipc);
    wire lane1_has_rd = (inst1_i[11:7] != 5'b0) &&
        (op1_imm || op1_reg || op1_load || op1_lui || op1_auipc);
    wire lane1_uses_rs1 = op1_imm || op1_reg || op1_load || op1_store;
    wire lane1_uses_rs2 = op1_reg || op1_store;
    wire pair_raw_hazard = lane0_has_rd &&
        ((lane1_uses_rs1 &&
          (inst1_i[19:15] == inst0_i[11:7])) ||
         (lane1_uses_rs2 &&
          (inst1_i[24:20] == inst0_i[11:7])));
    wire pair_waw_hazard = lane0_has_rd &&
        lane1_has_rd &&
        (inst0_i[11:7] == inst1_i[11:7]);

    wire normal_pair =
        lane0_inst0 && lane1_inst1;

    // The core has one memory pipeline.  For an older ALU followed by a
    // younger memory operation, execute memory in the full main lane and the
    // ALU in the integer side lane.  Architectural order is retained by
    // carrying the swap bit with the pair and tracking that the side result
    // is the older instruction at interrupt boundaries.
    wire swapped_memory_pair =
        lane1_inst0 && (load1_legal || store1_legal);

    wire pair_hazard_free = !pair_raw_hazard && !pair_waw_hazard;
    assign pair_eligible_o = ENABLE_DUAL_ISSUE &&
        (fetch_pc_i == 3'b000) && pair_hazard_free &&
        (normal_pair || swapped_memory_pair);
    assign pair_swap_o = pair_eligible_o && swapped_memory_pair;

endmodule

`endif
