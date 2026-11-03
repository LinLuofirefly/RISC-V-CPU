`timescale 1ns / 1ps

module tb_shell_coremark10;
    localparam integer CPU_CLK_HZ = 200000000;
    localparam integer UART_BAUD = 115200;
    localparam integer UART_DIV = CPU_CLK_HZ / UART_BAUD;
    localparam integer ECHO_DELAY_US = 200;
    localparam integer ECHO_WIDTH_US = 1166;
    localparam integer CYCLES_PER_US = CPU_CLK_HZ / 1000000;
    localparam longint TIMEOUT_CYCLES = 30000000;
    localparam [31:0] LED_ADDR = 32'h80200040;

    reg         w_cpu_clk = 1'b0;
    reg         w_clk_50Mhz = 1'b0;
    reg         w_clk_rst = 1'b1;
    reg  [7:0]  virtual_key = 8'd0;
    reg  [63:0] virtual_sw = 64'd0;
    reg         cpu_uart_rx = 1'b1;
    reg         hcsr04_echo = 1'b0;
    wire [31:0] virtual_led;
    wire [39:0] virtual_seg;
    wire        cpu_uart_tx;
    wire        hcsr04_trig;

    longint cycle_count = 0;
    longint trig_rise_cycle = 0;
    longint trig_fall_cycle = 0;
    longint coremark_start_cycle = 0;
    longint coremark_stop_cycle = 0;
    integer prompt_count = 0;
    integer trig_count = 0;
    integer led_on_count = 0;
    integer led_off_count = 0;
    reg [39:0] uart_tail = 40'd0;
    reg coremark_running = 1'b0;
    reg unexpected_led_pattern = 1'b0;
    student_top #(
        .P_CPU_CLK_HZ(CPU_CLK_HZ),
        .P_UART_BAUD_RATE(UART_BAUD)
    ) dut (
        .w_cpu_clk(w_cpu_clk),
        .w_clk_50Mhz(w_clk_50Mhz),
        .w_clk_rst(w_clk_rst),
        .virtual_key(virtual_key),
        .virtual_sw(virtual_sw),
        .cpu_uart_rx(cpu_uart_rx),
        .hcsr04_echo(hcsr04_echo),
        .virtual_led(virtual_led),
        .virtual_seg(virtual_seg),
        .cpu_uart_tx(cpu_uart_tx),
        .hcsr04_trig(hcsr04_trig)
    );

    always #2.5 w_cpu_clk = ~w_cpu_clk;
    always #10 w_clk_50Mhz = ~w_clk_50Mhz;

    task automatic uart_send_byte(input [7:0] value);
        integer bit_index;
        begin
            @(negedge w_cpu_clk);
            cpu_uart_rx = 1'b0;
            repeat (UART_DIV) @(posedge w_cpu_clk);
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                cpu_uart_rx = value[bit_index];
                repeat (UART_DIV) @(posedge w_cpu_clk);
            end
            cpu_uart_rx = 1'b1;
            repeat (UART_DIV) @(posedge w_cpu_clk);
        end
    endtask

    task automatic send_help_command;
        begin
            uart_send_byte("h"); uart_send_byte("e");
            uart_send_byte("l"); uart_send_byte("p");
            uart_send_byte(8'h0d);
        end
    endtask

    task automatic send_coremark_command;
        begin
            uart_send_byte("c"); uart_send_byte("o");
            uart_send_byte("r"); uart_send_byte("e");
            uart_send_byte("m"); uart_send_byte("a");
            uart_send_byte("r"); uart_send_byte("k");
            uart_send_byte(8'h0d);
        end
    endtask

    task automatic send_distance_command;
        begin
            uart_send_byte("d"); uart_send_byte("i");
            uart_send_byte("s"); uart_send_byte("t");
            uart_send_byte("a"); uart_send_byte("n");
            uart_send_byte("c"); uart_send_byte("e");
            uart_send_byte(8'h0d);
        end
    endtask

    initial begin
        repeat (32) @(posedge w_cpu_clk);
        w_clk_rst = 1'b0;

        wait (prompt_count >= 1);
        send_help_command();
        wait (prompt_count >= 2);

        send_coremark_command();
        wait (prompt_count >= 3);

        send_distance_command();
        wait (prompt_count >= 4);
        repeat (100) @(posedge w_cpu_clk);

        $display("\nTB_SUMMARY cycles=%0d coremark_cycles=%0d coremark_ms=%0d prompts=%0d led_on=%0d led_off=%0d trig_count=%0d trig_cycles=%0d echo_cycles=%0d echo_us=%0d distance_mm_expected=200 timeout=%0d",
                 cycle_count, coremark_stop_cycle - coremark_start_cycle,
                 (coremark_stop_cycle - coremark_start_cycle) / CYCLES_PER_US / 1000,
                 prompt_count, led_on_count, led_off_count,
                 trig_count, trig_fall_cycle - trig_rise_cycle,
                 dut.bridge_inst.hcsr04_echo_cycles,
                 dut.bridge_inst.hcsr04_echo_us,
                 dut.bridge_inst.hcsr04_timeout);

        if (prompt_count != 4)
            $fatal(1, "expected one prompt after boot and each of three commands");
        if (led_on_count != 1)
            $fatal(1, "CoreMark did not write LED value 1 exactly once");
        if (led_off_count != 1)
            $fatal(1, "CoreMark did not clear the LED exactly once");
        if (coremark_running)
            $fatal(1, "CoreMark LED remained logically on");
        if (virtual_led != 32'd0)
            $fatal(1, "visible LED output did not return to zero");
        if (unexpected_led_pattern)
            $fatal(1, "an LED bit other than LED[0] became active");
        if (trig_count != 1)
            $fatal(1, "expected exactly one HC-SR04 TRIG pulse");
        if ((trig_fall_cycle - trig_rise_cycle < 1999) ||
            (trig_fall_cycle - trig_rise_cycle > 2001))
            $fatal(1, "TRIG width is not 10 us at 200 MHz");
        if (dut.bridge_inst.hcsr04_timeout)
            $fatal(1, "unexpected HC-SR04 timeout");
        if (!dut.bridge_inst.hcsr04_done)
            $fatal(1, "HC-SR04 DONE was not asserted");
        if ((dut.bridge_inst.hcsr04_echo_us < ECHO_WIDTH_US - 1) ||
            (dut.bridge_inst.hcsr04_echo_us > ECHO_WIDTH_US + 1))
            $fatal(1, "captured ECHO width is outside tolerance");

        $display("TB_PASS help/coremark(10)/distance command sequence completed");
        $finish;
    end

    initial begin
        forever begin
            @(posedge hcsr04_trig);
            trig_count = trig_count + 1;
            trig_rise_cycle = cycle_count;
            @(negedge hcsr04_trig);
            trig_fall_cycle = cycle_count;
            repeat (ECHO_DELAY_US * CYCLES_PER_US) @(posedge w_cpu_clk);
            hcsr04_echo = 1'b1;
            repeat (ECHO_WIDTH_US * CYCLES_PER_US) @(posedge w_cpu_clk);
            hcsr04_echo = 1'b0;
        end
    end

    always @(posedge w_cpu_clk) begin
        if (!w_clk_rst) begin
            cycle_count = cycle_count + 1;
            if (cycle_count >= TIMEOUT_CYCLES)
                $fatal(1, "shell system test timeout pc=%08h prompts=%0d",
                       dut.pc, prompt_count);

            if (virtual_led[31:1] != 31'd0)
                unexpected_led_pattern = 1'b1;

            if ((|dut.perip_wstrb) && (dut.perip_addr == LED_ADDR)) begin
                if (dut.perip_wdata == 32'd1) begin
                    led_on_count = led_on_count + 1;
                    coremark_running = 1'b1;
                    coremark_start_cycle = cycle_count;
                end else if ((dut.perip_wdata == 32'd0) && coremark_running) begin
                    led_off_count = led_off_count + 1;
                    coremark_running = 1'b0;
                    coremark_stop_cycle = cycle_count;
                end else begin
                    unexpected_led_pattern = 1'b1;
                end
            end

            if (dut.bridge_inst.uart_data_write) begin
                $write("%c", dut.perip_wdata[7:0]);
                $fflush();
                uart_tail = {uart_tail[31:0], dut.perip_wdata[7:0]};
                if (uart_tail == 40'h6d7368203e)
                    prompt_count = prompt_count + 1;
            end
        end
    end

endmodule
