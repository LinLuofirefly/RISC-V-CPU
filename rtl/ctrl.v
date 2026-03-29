// ctrl: 中央控制器
// 职责：处理跳转指令引起的流水线冲刷
// 当 jump_en_i=1 时，输出 flush_flag_o=1，用于清空 IF/ID 和 ID/EX（冲刷错误取的指令）
module ctrl(
    input  wire [31:0] jump_addr_i,
    input  wire        jump_en_i,
    output reg  [31:0] jump_addr_o,
    output reg         jump_en_o,
    output reg         flush_flag_o   // 跳转时冲刷流水线（清空 IF/ID 与 ID/EX）
);

always @(*) begin
    jump_addr_o  = jump_addr_i;
    jump_en_o    = jump_en_i;
    flush_flag_o = jump_en_i;   // 跳转时立即冲刷
end

endmodule
