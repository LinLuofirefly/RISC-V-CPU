`timescale 1ns / 1ps

module myCPU #(
    parameter ENABLE_DUAL_ISSUE = 1'b1,
    parameter [7:0] DUAL_OP_IMM_MASK = 8'hff,
    parameter [7:0] DUAL_OP_REG_MASK = 8'hff
) (
    input  logic         cpu_rst,
    input  logic         cpu_clk,
    output logic [31:0]  irom_addr,
    output logic [12:0]  irom_word_addr,
    output logic [12:0]  irom_word_addr_next,
    input  logic [31:0]  irom_data,
    input  logic [31:0]  irom_data_next,
    output logic [31:0]  perip_addr,
    output logic [3:0]   perip_wen,
    output logic [31:0]  perip_wdata,
    input  logic [31:0]  perip_dram_rdata,
    input  logic [31:0]  perip_mmio_rdata,
    output logic [31:0]  perip_rd_addr,
    output logic         perip_rd_en
);

    // Minimal machine timer used by RT-Thread's system tick.
    localparam logic [31:0] MTIMER_PERIOD_ADDR = 32'h8020_0060;
    localparam logic [31:0] MTIMER_CTRL_ADDR   = 32'h8020_0064;
    localparam logic [31:0] MTIMER_ACK_ADDR    = 32'h8020_0068;

    logic [31:0] timer_period_r;
    logic [31:0] timer_count_r;
    logic        timer_enable_r;
    logic        timer_irq_pending_r;

    wire timer_write = |perip_wen;

    always_ff @(posedge cpu_clk) begin
        if (cpu_rst) begin
            timer_period_r      <= 32'd0;
            timer_count_r       <= 32'd0;
            timer_enable_r      <= 1'b0;
            timer_irq_pending_r <= 1'b0;
        end else if (timer_write && (perip_addr == MTIMER_CTRL_ADDR)) begin
            timer_enable_r      <= perip_wdata[0];
            timer_count_r       <= 32'd0;
            timer_irq_pending_r <= 1'b0;
        end else if (timer_write && (perip_addr == MTIMER_ACK_ADDR)) begin
            timer_count_r       <= 32'd0;
            timer_irq_pending_r <= 1'b0;
        end else if (timer_write && (perip_addr == MTIMER_PERIOD_ADDR)) begin
            timer_period_r <= perip_wdata;
            timer_count_r  <= 32'd0;
        end else if (timer_enable_r && !timer_irq_pending_r &&
                     (timer_period_r != 32'd0)) begin
            if (timer_count_r >= (timer_period_r - 32'd1)) begin
                timer_count_r       <= 32'd0;
                timer_irq_pending_r <= 1'b1;
            end else begin
                timer_count_r <= timer_count_r + 32'd1;
            end
        end
    end

    open_risc_v #(
        .ENABLE_DUAL_ISSUE (ENABLE_DUAL_ISSUE),
        .DUAL_OP_IMM_MASK  (DUAL_OP_IMM_MASK),
        .DUAL_OP_REG_MASK  (DUAL_OP_REG_MASK)
    ) cpu_core (
        .clk           (cpu_clk),
        .rst_n         (~cpu_rst),
        .inst_i        (irom_data),
        .inst_next_i   (irom_data_next),
        .ram_data_i    (perip_dram_rdata),
        .mmio_data_i   (perip_mmio_rdata),
        .timer_irq_i   (timer_irq_pending_r),
        .pc_reg_pc_o   (),
        .irom_addr_o   (irom_addr),
        .irom_word_addr_o(irom_word_addr),
        .irom_word_addr_next_o(irom_word_addr_next),
        .mem_rd_reg_o  (perip_rd_en),
        .mem_rd_addr_o (perip_rd_addr),
        .w_en          (perip_wen),
        .w_addr_i      (perip_addr),
        .w_data_i      (perip_wdata)
    );

endmodule
