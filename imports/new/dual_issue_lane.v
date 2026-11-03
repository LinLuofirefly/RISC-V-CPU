`ifndef DUAL_ISSUE_LANE_V
`define DUAL_ISSUE_LANE_V

// Side-effect-free RV32I integer lane. Memory, control-flow, CSR, trap and
// RV32M instructions are rejected by dual_issue_pairing before this stage.
module dual_issue_lane (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [31:0] inst_i,
    input  wire [31:0] pc_i,
    input  wire        issue_valid_i,
    input  wire        issue_older_i,
    input  wire        hold_i,
    input  wire        wait_ex_i,
    input  wire        flush_i,
    input  wire        kill_ex_i,
    input  wire [31:0] rs1_data_i,
    input  wire [31:0] rs2_data_i,

    output wire [4:0]  id_rs1_o,
    output wire [4:0]  id_rs2_o,
    output wire        id_use_rs1_o,
    output wire        id_use_rs2_o,
    output wire        idex_valid_o,
    output wire        idex_older_o,
    output wire [4:0]  idex_rd_o,
    output wire [31:0] ex_result_o,
    output wire        exmem_valid_o,
    output wire [4:0]  exmem_rd_o,
    output wire [31:0] exmem_data_o,
    output wire        mem2_valid_o,
    output wire [4:0]  mem2_rd_o,
    output wire [31:0] mem2_data_o,
    output wire        wb_valid_o,
    output wire [31:0] wb_inst_o,
    output wire [4:0]  wb_rd_o,
    output wire [31:0] wb_data_o
);

    wire [6:0] id_opcode = inst_i[6:0];
    wire [2:0] id_func3  = inst_i[14:12];
    wire [6:0] id_func7  = inst_i[31:25];
    wire [31:0] id_imm = {{20{inst_i[31]}}, inst_i[31:20]};
    wire [31:0] id_u_imm = {inst_i[31:12], 12'b0};
    wire [31:0] id_op2 = (id_opcode == `INST_TYPE_I) ?
        (((id_func3 == `INST_SLLI) || (id_func3 == `INST_SRI)) ?
            {27'b0, inst_i[24:20]} : id_imm) : rs2_data_i;

    assign id_rs1_o     = inst_i[19:15];
    assign id_rs2_o     = inst_i[24:20];
    assign id_use_rs1_o = (id_opcode == `INST_TYPE_I) ||
                          (id_opcode == `INST_TYPE_R_M);
    assign id_use_rs2_o = (id_opcode == `INST_TYPE_R_M);

    // These names are kept local and stable for focused ALU verification.
    reg         lane1_idex_valid;
    reg         lane1_idex_older;
    reg  [31:0] lane1_idex_inst;
    reg  [31:0] lane1_idex_op1;
    reg  [31:0] lane1_idex_op2;
    reg  [4:0]  lane1_idex_rd;
    reg  [2:0]  lane1_idex_func3;
    reg  [6:0]  lane1_idex_func7;
    reg         lane1_idex_is_imm;
    reg  [6:0]  lane1_idex_opcode;
    reg  [31:0] lane1_idex_pc;
    reg  [31:0] lane1_idex_u_imm;

    reg         lane1_exmem_valid;
    reg  [31:0] lane1_exmem_inst;
    reg  [4:0]  lane1_exmem_rd;
    reg  [31:0] lane1_exmem_data;
    reg         lane1_mem2_valid;
    reg  [31:0] lane1_mem2_inst;
    reg  [4:0]  lane1_mem2_rd;
    reg  [31:0] lane1_mem2_data;
    reg         lane1_wb_valid;
    reg  [31:0] lane1_wb_inst;
    reg  [4:0]  lane1_wb_rd;
    reg  [31:0] lane1_wb_data;
    reg  [31:0] lane1_alu_result;

    assign idex_valid_o = lane1_idex_valid;
    assign idex_older_o = lane1_idex_older;
    assign idex_rd_o    = lane1_idex_rd;
    assign ex_result_o  = lane1_alu_result;
    assign exmem_valid_o = lane1_exmem_valid;
    assign exmem_rd_o    = lane1_exmem_rd;
    assign exmem_data_o  = lane1_exmem_data;
    assign mem2_valid_o = lane1_mem2_valid;
    assign mem2_rd_o    = lane1_mem2_rd;
    assign mem2_data_o  = lane1_mem2_data;
    assign wb_valid_o = lane1_wb_valid;
    assign wb_inst_o  = lane1_wb_inst;
    assign wb_rd_o    = lane1_wb_rd;
    assign wb_data_o  = lane1_wb_data;

    always @(posedge clk) begin
        if (!rst_n) begin
            lane1_idex_valid  <= 1'b0;
            lane1_idex_older  <= 1'b0;
            lane1_idex_inst   <= `INST_NOP;
            lane1_idex_op1    <= 32'b0;
            lane1_idex_op2    <= 32'b0;
            lane1_idex_rd     <= 5'b0;
            lane1_idex_func3  <= 3'b0;
            lane1_idex_func7  <= 7'b0;
            lane1_idex_is_imm <= 1'b0;
            lane1_idex_opcode <= `INST_TYPE_I;
            lane1_idex_pc     <= 32'b0;
            lane1_idex_u_imm  <= 32'b0;
        end else if (flush_i) begin
            lane1_idex_valid <= 1'b0;
        end else if (!hold_i) begin
            lane1_idex_valid  <= issue_valid_i;
            lane1_idex_older  <= issue_older_i;
            lane1_idex_inst   <= inst_i;
            lane1_idex_op1    <= rs1_data_i;
            lane1_idex_op2    <= id_op2;
            lane1_idex_rd     <= inst_i[11:7];
            lane1_idex_func3  <= id_func3;
            lane1_idex_func7  <= id_func7;
            lane1_idex_is_imm <= (id_opcode == `INST_TYPE_I);
            lane1_idex_opcode <= id_opcode;
            lane1_idex_pc     <= pc_i;
            lane1_idex_u_imm  <= id_u_imm;
        end
    end

    always @(*) begin
        if (lane1_idex_opcode == `INST_LUI) begin
            lane1_alu_result = lane1_idex_u_imm;
        end else if (lane1_idex_opcode == `INST_AUIPC) begin
            lane1_alu_result = lane1_idex_pc + lane1_idex_u_imm;
        end else case (lane1_idex_func3)
            `INST_ADD_SUB:
                if (!lane1_idex_is_imm &&
                    (lane1_idex_func7 == `INST_FUNC7_SUB))
                    lane1_alu_result = lane1_idex_op1 - lane1_idex_op2;
                else
                    lane1_alu_result = lane1_idex_op1 + lane1_idex_op2;
            `INST_SLL:
                lane1_alu_result = lane1_idex_op1 << lane1_idex_op2[4:0];
            `INST_SLT:
                lane1_alu_result =
                    {31'b0, $signed(lane1_idex_op1) <
                             $signed(lane1_idex_op2)};
            `INST_SLTU:
                lane1_alu_result =
                    {31'b0, lane1_idex_op1 < lane1_idex_op2};
            `INST_XOR:
                lane1_alu_result = lane1_idex_op1 ^ lane1_idex_op2;
            `INST_OR:
                lane1_alu_result = lane1_idex_op1 | lane1_idex_op2;
            `INST_AND:
                lane1_alu_result = lane1_idex_op1 & lane1_idex_op2;
            `INST_SR:
                if (lane1_idex_func7 == `INST_FUNC7_SUB)
                    lane1_alu_result =
                        $signed(lane1_idex_op1) >>> lane1_idex_op2[4:0];
                else
                    lane1_alu_result = lane1_idex_op1 >> lane1_idex_op2[4:0];
            default:
                lane1_alu_result = 32'b0;
        endcase
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            lane1_exmem_valid <= 1'b0;
            lane1_mem2_valid  <= 1'b0;
            lane1_wb_valid    <= 1'b0;
            lane1_exmem_inst  <= `INST_NOP;
            lane1_mem2_inst   <= `INST_NOP;
            lane1_wb_inst     <= `INST_NOP;
            lane1_exmem_rd    <= 5'b0;
            lane1_mem2_rd     <= 5'b0;
            lane1_wb_rd       <= 5'b0;
            lane1_exmem_data  <= 32'b0;
            lane1_mem2_data   <= 32'b0;
            lane1_wb_data     <= 32'b0;
        end else begin
            // A paired RV32M instruction remains in Lane 0 EX until its
            // iterative result is ready.  Keep the younger Lane-1 operation
            // in ID/EX over that interval and release it exactly once beside
            // the RV32M done pulse.
            lane1_exmem_valid <=
                lane1_idex_valid && !kill_ex_i && !wait_ex_i;
            lane1_exmem_inst  <= lane1_idex_inst;
            lane1_exmem_rd    <= lane1_idex_rd;
            lane1_exmem_data  <= lane1_alu_result;

            lane1_mem2_valid <= lane1_exmem_valid;
            lane1_mem2_inst  <= lane1_exmem_inst;
            lane1_mem2_rd    <= lane1_exmem_rd;
            lane1_mem2_data  <= lane1_exmem_data;

            lane1_wb_valid <= lane1_mem2_valid;
            lane1_wb_inst  <= lane1_mem2_inst;
            lane1_wb_rd    <= lane1_mem2_rd;
            lane1_wb_data  <= lane1_mem2_data;
        end
    end

endmodule

`endif
