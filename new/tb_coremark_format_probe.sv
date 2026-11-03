`timescale 1ns / 1ps

`ifndef TB_DUAL_OP_IMM_MASK
`define TB_DUAL_OP_IMM_MASK 255
`endif
`ifndef TB_DUAL_OP_REG_MASK
`define TB_DUAL_OP_REG_MASK 255
`endif

module tb_coremark_format_probe;
    localparam integer CPU_CLK_HZ = 200000000;
    localparam integer UART_DIV = CPU_CLK_HZ / 115200;
    localparam longint TIMEOUT_CYCLES = 40000000;

    reg cpu_clk = 1'b0;
    reg clk50 = 1'b0;
    reg rst = 1'b1;
    reg uart_rx = 1'b1;
    wire [31:0] led;
    wire [39:0] seg;
    wire uart_tx;
    wire trig;

    longint cycles = 0;
    longint pairs = 0;
    integer prompts = 0;
    reg running = 1'b0;
    reg [39:0] uart_tail = 40'b0;
    reg [223:0] validation_tail = 224'b0;
    reg saw_literal_width = 1'b0;
    reg saw_exact_list_crc = 1'b0;
    reg saw_validation = 1'b0;

    student_top #(
        .P_CPU_CLK_HZ(CPU_CLK_HZ),
        .P_UART_BAUD_RATE(115200),
        .P_ENABLE_DUAL_ISSUE(1'b1),
        .P_DUAL_OP_IMM_MASK(`TB_DUAL_OP_IMM_MASK),
        .P_DUAL_OP_REG_MASK(`TB_DUAL_OP_REG_MASK)
    ) dut (
        .w_cpu_clk(cpu_clk), .w_clk_50Mhz(clk50), .w_clk_rst(rst),
        .virtual_key(8'b0), .virtual_sw(64'b0),
        .cpu_uart_rx(uart_rx), .hcsr04_echo(1'b0),
        .virtual_led(led), .virtual_seg(seg),
        .cpu_uart_tx(uart_tx), .hcsr04_trig(trig)
    );

    always #2.5 cpu_clk = ~cpu_clk;
    always #10 clk50 = ~clk50;

    task automatic uart_send_byte(input [7:0] value);
        integer bit_index;
        begin
            @(negedge cpu_clk);
            uart_rx = 1'b0;
            repeat (UART_DIV) @(posedge cpu_clk);
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                uart_rx = value[bit_index];
                repeat (UART_DIV) @(posedge cpu_clk);
            end
            uart_rx = 1'b1;
            repeat (UART_DIV) @(posedge cpu_clk);
        end
    endtask

    task automatic send_coremark;
        begin
            uart_send_byte("c"); uart_send_byte("o");
            uart_send_byte("r"); uart_send_byte("e");
            uart_send_byte("m"); uart_send_byte("a");
            uart_send_byte("r"); uart_send_byte("k");
            uart_send_byte(8'h0d);
        end
    endtask

    initial begin
        repeat (32) @(posedge cpu_clk);
        rst = 1'b0;
        wait (prompts >= 1);
        running = 1'b1;
        send_coremark();
        wait (prompts >= 2);
        running = 1'b0;
        $display("FORMAT_PROBE imm_mask=%0d reg_mask=%0d cycles=%0d pairs=%0d literal=%0b exact_list=%0b validated=%0b",
                 `TB_DUAL_OP_IMM_MASK, `TB_DUAL_OP_REG_MASK,
                 cycles, pairs, saw_literal_width,
                 saw_exact_list_crc, saw_validation);
        if (!saw_validation)
            $fatal(1, "CoreMark validation message missing");
        if (saw_literal_width || !saw_exact_list_crc)
            $fatal(1, "CoreMark CRC width formatting regressed");
        $finish;
    end

    always @(posedge cpu_clk) begin
        if (!rst) begin
            cycles = cycles + 1;
            if (cycles >= TIMEOUT_CYCLES)
                $fatal(1, "format probe timeout pc=%08x", dut.pc);
            if (running && dut.Core_cpu.cpu_core.fetch_pair_accept)
                pairs = pairs + 1;

            if (dut.bridge_inst.uart_data_write) begin
                $write("%c", dut.perip_wdata[7:0]);
                $fflush();
                uart_tail = {uart_tail[31:0], dut.perip_wdata[7:0]};
                validation_tail =
                    {validation_tail[215:0], dut.perip_wdata[7:0]};
                if (uart_tail == 40'h6d7368203e)
                    prompts = prompts + 1;
                if (uart_tail == 40'h3078253478)
                    saw_literal_width = 1'b1;
                if (uart_tail == 40'h3078653731)
                    saw_exact_list_crc = 1'b1;
                if (validation_tail == "Correct operation validated.")
                    saw_validation = 1'b1;
            end
        end
    end
endmodule
