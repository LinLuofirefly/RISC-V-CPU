`ifndef DUAL_ISSUE_PAIRING_V
`define DUAL_ISSUE_PAIRING_V

// Selects independent pairs for the full main pipeline and the integer side
// lane.  A younger load/store may use the main lane while its older ALU peer
// is swapped into the side lane.
module dual_issue_pairing #(
    parameter ENABLE_DUAL_ISSUE = 1'b1,
    parameter [7:0] OP_IMM_MASK = 8'hff,
    parameter [7:0] OP_REG_MASK = 8'hff
) (
    input  wire [2:0]  fetch_pc_i,
    input  wire [31:0] inst0_i,
    input  wire [31:0] inst1_i,
    output wire        pair_eligible_o,
    output wire        pair_swap_o
);

    function automatic is_lane1_instruction;
        input [31:0] inst;
        reg [6:0] opcode;
        reg [2:0] func3;
        reg [6:0] func7;
        begin
            opcode = inst[6:0];
            func3  = inst[14:12];
            func7  = inst[31:25];

            if ((opcode == `INST_TYPE_I) && OP_IMM_MASK[func3]) begin
                case (func3)
                    `INST_ADDI, `INST_SLTI, `INST_SLTIU,
                    `INST_XORI, `INST_ORI, `INST_ANDI:
                        is_lane1_instruction = 1'b1;
                    `INST_SLLI:
                        is_lane1_instruction = (func7 == `INST_FUNC7_R);
                    `INST_SRI:
                        is_lane1_instruction = (func7 == `INST_FUNC7_R) ||
                                               (func7 == `INST_FUNC7_SUB);
                    default:
                        is_lane1_instruction = 1'b0;
                endcase
            end else if ((opcode == `INST_TYPE_R_M) &&
                         OP_REG_MASK[func3]) begin
                case (func3)
                    `INST_ADD_SUB, `INST_SR:
                        is_lane1_instruction = (func7 == `INST_FUNC7_R) ||
                                               (func7 == `INST_FUNC7_SUB);
                    `INST_SLL, `INST_SLT, `INST_SLTU,
                    `INST_XOR, `INST_OR, `INST_AND:
                        is_lane1_instruction = (func7 == `INST_FUNC7_R);
                    default:
                        is_lane1_instruction = 1'b0;
                endcase
            end else begin
                is_lane1_instruction =
                    (opcode == `INST_LUI) || (opcode == `INST_AUIPC);
            end
        end
    endfunction

    function automatic lane1_uses_rs1;
        input [31:0] inst;
        begin
            lane1_uses_rs1 = (inst[6:0] == `INST_TYPE_I) ||
                             (inst[6:0] == `INST_TYPE_R_M) ||
                             (inst[6:0] == `INST_TYPE_L) ||
                             (inst[6:0] == `INST_TYPE_S);
        end
    endfunction

    function automatic is_store_instruction;
        input [31:0] inst;
        begin
            if (inst[6:0] == `INST_TYPE_S) begin
                case (inst[14:12])
                    `INST_SB, `INST_SH, `INST_SW:
                        is_store_instruction = 1'b1;
                    default:
                        is_store_instruction = 1'b0;
                endcase
            end else begin
                is_store_instruction = 1'b0;
            end
        end
    endfunction

    function automatic is_load_instruction;
        input [31:0] inst;
        begin
            if (inst[6:0] == `INST_TYPE_L) begin
                case (inst[14:12])
                    `INST_LB, `INST_LH, `INST_LW,
                    `INST_LBU, `INST_LHU:
                        is_load_instruction = 1'b1;
                    default:
                        is_load_instruction = 1'b0;
                endcase
            end else begin
                is_load_instruction = 1'b0;
            end
        end
    endfunction

    function automatic lane1_uses_rs2;
        input [31:0] inst;
        begin
            lane1_uses_rs2 = (inst[6:0] == `INST_TYPE_R_M) ||
                             (inst[6:0] == `INST_TYPE_S);
        end
    endfunction

    function automatic is_lane0_instruction;
        input [31:0] inst;
        reg [6:0] opcode;
        reg [2:0] func3;
        reg [6:0] func7;
        begin
            opcode = inst[6:0];
            func3  = inst[14:12];
            func7  = inst[31:25];
            if (is_lane1_instruction(inst)) begin
                is_lane0_instruction = 1'b1;
            end else if ((opcode == `INST_TYPE_R_M) &&
                         (func7 == `INST_FUNC7_M)) begin
                // All eight funct3 encodings are defined by RV32M.  The
                // iterative unit remains in Lane 0; Lane 1 may carry one
                // independent RV32I integer instruction beside it.
                is_lane0_instruction = 1'b1;
            end else if (opcode == `INST_TYPE_L) begin
                case (func3)
                    `INST_LB, `INST_LH, `INST_LW,
                    `INST_LBU, `INST_LHU:
                        is_lane0_instruction = 1'b1;
                    default:
                        is_lane0_instruction = 1'b0;
                endcase
            end else if (opcode == `INST_TYPE_S) begin
                case (func3)
                    `INST_SB, `INST_SH, `INST_SW:
                        is_lane0_instruction = 1'b1;
                    default:
                        is_lane0_instruction = 1'b0;
                endcase
            end else if (opcode == `INST_TYPE_B) begin
                case (func3)
                    `INST_BEQ, `INST_BNE, `INST_BLT,
                    `INST_BGE, `INST_BLTU, `INST_BGEU:
                        is_lane0_instruction = 1'b1;
                    default:
                        is_lane0_instruction = 1'b0;
                endcase
            end else begin
                is_lane0_instruction = 1'b0;
            end
        end
    endfunction

    function automatic lane0_writes_rd;
        input [31:0] inst;
        reg [6:0] opcode;
        begin
            opcode = inst[6:0];
            lane0_writes_rd = (inst[11:7] != 5'b0) &&
                ((opcode == `INST_TYPE_I) ||
                 (opcode == `INST_TYPE_R_M) ||
                 (opcode == `INST_TYPE_L) ||
                 (opcode == `INST_LUI) ||
                 (opcode == `INST_AUIPC));
        end
    endfunction

    wire lane0_has_rd = lane0_writes_rd(inst0_i);
    wire pair_raw_hazard = lane0_has_rd &&
        ((lane1_uses_rs1(inst1_i) &&
          (inst1_i[19:15] == inst0_i[11:7])) ||
         (lane1_uses_rs2(inst1_i) &&
          (inst1_i[24:20] == inst0_i[11:7])));
    wire pair_waw_hazard = lane0_has_rd &&
        lane0_writes_rd(inst1_i) &&
        (inst0_i[11:7] == inst1_i[11:7]);

    wire normal_pair =
        is_lane0_instruction(inst0_i) &&
        is_lane1_instruction(inst1_i);

    // The core has one memory pipeline.  For an older ALU followed by a
    // younger memory operation, execute memory in the full main lane and the
    // ALU in the integer side lane.  Architectural order is retained by
    // carrying the swap bit with the pair and tracking that the side result
    // is the older instruction at interrupt boundaries.
    wire swapped_memory_pair =
        is_lane1_instruction(inst0_i) &&
        (is_load_instruction(inst1_i) ||
         is_store_instruction(inst1_i));

    wire pair_hazard_free = !pair_raw_hazard && !pair_waw_hazard;
    assign pair_eligible_o = ENABLE_DUAL_ISSUE &&
        (fetch_pc_i == 3'b000) && pair_hazard_free &&
        (normal_pair || swapped_memory_pair);
    assign pair_swap_o = pair_eligible_o && swapped_memory_pair;

endmodule

`endif
