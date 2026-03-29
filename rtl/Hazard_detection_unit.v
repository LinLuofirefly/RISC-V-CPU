`include "defines.v"
module Hazard_detection_unit(
    input wire [31:0] id_inst_i,
    input wire [31:0] ex_inst_i,
    output reg hold_flag_o,
    output reg flush_flag_o
);

wire [6:0]id_opcode;
wire [6:0]ex_opcode;

wire [4:0]id_rs1;
wire [4:0]id_rs2;
wire [4:0]ex_rd;


assign id_opcode = id_inst_i[6:0];
assign ex_opcode = ex_inst_i[6:0];
assign id_rs1 = id_inst_i[19:15];
assign id_rs2 = id_inst_i[24:20];
assign ex_rd = ex_inst_i[11:7];
always@(*)begin
    hold_flag_o = 1'b0;
    flush_flag_o = 1'b0;
    if(ex_opcode == `INST_TYPE_L && ex_rd != 5'b0 && ex_rd == id_rs1)begin
        hold_flag_o = 1'b1;flush_flag_o = 1'b1;
    end
    if(ex_opcode == `INST_TYPE_L && ex_rd != 5'b0 && ex_rd == id_rs2)begin
        hold_flag_o = 1'b1;flush_flag_o = 1'b1;
    end
end


endmodule
