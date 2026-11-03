`timescale 1ns / 1ps

// Four asynchronous read ports and two synchronous write ports.
// The second write port belongs to the younger instruction, so it wins both
// same-cycle read bypass and a same-address write collision.
module regs (
    input  wire        clk,
    input  wire [4:0]  reg1_raddr_i,
    output reg  [31:0] reg1_rdata_o,
    input  wire [4:0]  reg2_raddr_i,
    output reg  [31:0] reg2_rdata_o,
    input  wire [4:0]  reg3_raddr_i,
    output reg  [31:0] reg3_rdata_o,
    input  wire [4:0]  reg4_raddr_i,
    output reg  [31:0] reg4_rdata_o,
    input  wire [4:0]  reg_waddr_i,
    input  wire [31:0] reg_wdata_i,
    input  wire        reg_wen,
    input  wire [4:0]  reg2_waddr_i,
    input  wire [31:0] reg2_wdata_i,
    input  wire        reg2_wen
);

    reg [31:0] regs [0:31];

    always @(*) begin
        if (reg1_raddr_i == 5'b0)
            reg1_rdata_o = 32'b0;
        else if (reg2_wen && (reg1_raddr_i == reg2_waddr_i))
            reg1_rdata_o = reg2_wdata_i;
        else if (reg_wen && (reg1_raddr_i == reg_waddr_i))
            reg1_rdata_o = reg_wdata_i;
        else
            reg1_rdata_o = regs[reg1_raddr_i];
    end

    always @(*) begin
        if (reg2_raddr_i == 5'b0)
            reg2_rdata_o = 32'b0;
        else if (reg2_wen && (reg2_raddr_i == reg2_waddr_i))
            reg2_rdata_o = reg2_wdata_i;
        else if (reg_wen && (reg2_raddr_i == reg_waddr_i))
            reg2_rdata_o = reg_wdata_i;
        else
            reg2_rdata_o = regs[reg2_raddr_i];
    end

    always @(*) begin
        if (reg3_raddr_i == 5'b0)
            reg3_rdata_o = 32'b0;
        else if (reg2_wen && (reg3_raddr_i == reg2_waddr_i))
            reg3_rdata_o = reg2_wdata_i;
        else if (reg_wen && (reg3_raddr_i == reg_waddr_i))
            reg3_rdata_o = reg_wdata_i;
        else
            reg3_rdata_o = regs[reg3_raddr_i];
    end

    always @(*) begin
        if (reg4_raddr_i == 5'b0)
            reg4_rdata_o = 32'b0;
        else if (reg2_wen && (reg4_raddr_i == reg2_waddr_i))
            reg4_rdata_o = reg2_wdata_i;
        else if (reg_wen && (reg4_raddr_i == reg_waddr_i))
            reg4_rdata_o = reg_wdata_i;
        else
            reg4_rdata_o = regs[reg4_raddr_i];
    end

    always @(posedge clk) begin
        if (reg_wen && (reg_waddr_i != 5'b0))
            regs[reg_waddr_i] <= reg_wdata_i;
        if (reg2_wen && (reg2_waddr_i != 5'b0))
            regs[reg2_waddr_i] <= reg2_wdata_i;
    end

endmodule
