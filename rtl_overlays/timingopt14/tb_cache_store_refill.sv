`timescale 1ns / 1ps
`include "dram_cache.v"
module tb_cache_store_refill;
    reg clk = 0, rst = 0;
    reg [31:0] read_addr = 32'h80101000;
    reg refill = 0;
    reg [31:0] refill_addr = 0, refill_data = 0;
    reg [3:0] store_mask = 0;
    reg [31:0] store_addr = 0, store_data = 0;
    wire hit;
    wire [31:0] data;
    localparam [31:0] A = 32'h80101000;
    localparam [31:0] B = A + 4;
    localparam [31:0] ALIAS = A + (4 << `DCACHE_INDEX_BITS);
    dram_cache #(.INDEX_BITS(`DCACHE_INDEX_BITS), .TAG_ADDR_MSB(17)) dut (
        .clk(clk), .rst(rst), .ex_load_addr_i(read_addr),
        .ex_fast_load_addr_i(read_addr), .mem1_is_load_i(1'b1),
        .mem1_load_hits_dram_i(1'b1), .mem1_inst_i(32'h00002203),
        .mem1_load_addr_i(read_addr), .mem1_uncached_rd_data_i(32'b0),
        .mem1_store_load_fwd_valid_i(1'b0), .mem1_store_load_fwd_wstrb_i(4'b0),
        .mem1_store_load_fwd_data_i(32'b0), .mem2_is_load_i(refill),
        .mem2_load_hits_dram_i(1'b1), .mem2_load_cache_hit_i(1'b0),
        .mem2_load_addr_i(refill_addr), .mem2_ram_data_i(refill_data),
        .mem2_store_load_fwd_valid_i(1'b0), .mem2_store_load_fwd_wstrb_i(4'b0),
        .mem2_store_load_fwd_data_i(32'b0), .store_wstrb_i(store_mask),
        .store_addr_i(store_addr), .store_data_i(store_data),
        .mem1_load_cache_hit_o(hit), .mem1_rd_data_o(data)
    );
    always #5 clk = ~clk;
    task automatic read_check(input [31:0] addr, input expected_hit,
                              input [31:0] expected_data);
        @(negedge clk); read_addr = addr;
        @(posedge clk); #1;
        if (hit !== expected_hit || (expected_hit && data !== expected_data))
            $fatal(1, "read %08x hit=%b data=%08x expected=%b/%08x",
                   addr, hit, data, expected_hit, expected_data);
    endtask
    task automatic start_fill(input [31:0] addr, word);
        @(negedge clk); refill = 1; refill_addr = addr; refill_data = word;
        @(posedge clk); #1;
        @(negedge clk); refill = 0;
    endtask
    task automatic finish_fill;
        @(posedge clk); #1;
        @(negedge clk); store_mask = 0;
    endtask
    initial begin
        repeat (3) @(negedge clk);
        rst = 1;
        start_fill(A, 32'h11223344); finish_fill();
        read_check(A, 1, 32'h11223344);

        // A partial store to A must never remain a stale hit while B refills.
        start_fill(B, 32'h55667788);
        store_addr = A; store_data = 32'h0000aa00; store_mask = 4'b0010;
        finish_fill();
        read_check(B, 1, 32'h55667788);
        read_check(A, 0, 0);
        start_fill(A, 32'h1122aa44); finish_fill();
        read_check(A, 1, 32'h1122aa44);

        // Same-word partial stores must merge into the pending refill.
        start_fill(B, 32'h55667788);
        store_addr = B; store_data = 32'hee000000; store_mask = 4'b1000;
        finish_fill();
        read_check(B, 1, 32'hee667788);

        // A store to the evicted tag must not contaminate a new same-index tag.
        start_fill(ALIAS, 32'habcdef01);
        store_addr = A; store_data = 32'h0000bb00; store_mask = 4'b0010;
        finish_fill();
        read_check(ALIAS, 1, 32'habcdef01);
        read_check(A, 0, 0);

        // Ordinary hit stores preserve the unaffected bytes.
        @(negedge clk);
        store_addr = ALIAS; store_data = 32'h000000cc; store_mask = 4'b0001;
        @(posedge clk); #1;
        @(negedge clk); store_mask = 0;
        read_check(ALIAS, 1, 32'habcdefcc);
        $display("TB_PASS cache partial stores, refill conflicts and tag replacement");
        $finish;
    end
    initial begin
        #10000; $fatal(1, "cache refill test timeout");
    end
endmodule
