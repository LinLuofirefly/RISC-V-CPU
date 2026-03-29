`include "defines.v"

// if_id 流水线寄存器
// stall  (hold_flag_i=1)  : PC 和 IF/ID 冻结，用于 Load-Use 冒险
// flush  (flush_flag_i=1) : IF/ID 清空（插 NOP），用于跳转冲刷
module if_id(
    input  wire        clk,
    input  wire        rst,
    input  wire [31:0] inst_i,
    input  wire [31:0] inst_addr_i,
    input  wire        hold_flag_i,   // stall：Load-Use 冒险时冻结 IF/ID
    input  wire        flush_flag_i,  // flush：跳转时清空 IF/ID（插气泡）
    output wire [31:0] inst_addr_o,
    output wire [31:0] inst_o
);

// 使用 dff_ctrl 以便 stall 与 flush 分离
dff_set #(32) dff_inst      (clk, rst, hold_flag_i, flush_flag_i, `INST_NOP, inst_i,      inst_o);
dff_set #(32) dff_inst_addr (clk, rst, hold_flag_i, flush_flag_i, 32'b0,     inst_addr_i, inst_addr_o);

endmodule
