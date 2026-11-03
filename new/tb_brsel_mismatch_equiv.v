`timescale 1ns / 1ps
//
// Equivalence check for the two CPI-neutral timing transforms:
//
//   A) early_forwarding_select.rs*_br_sel_o  (2-bit pre-decoded select)
//      vs. the old 3-bit rs*_fwd_sel_o driven through
//      forwarding.select_branch_data / select_nonlate_data.
//      Exhaustive over the 5 match booleans (32 cases) x 2 (rs1/rs2 share
//      the same priority structure, so one instance covers both).
//
//   B) ex.branch_dir_mismatch(kind, eq, lts, ltu, inv^pred)
//      vs. (branch_cond_result(cond, eq, lts, ltu) != pred).
//      Exhaustive over cond 0..6 x eq x lts x ltu x pred (112 cases).
//
// Pure reference model - no DUT instantiation, so it runs anywhere.
//
module tb_brsel_mismatch_equiv;

    integer errors_a = 0;
    integer errors_b = 0;

    // ------------------------------------------------------------------
    // A) forwarding select encodings
    // ------------------------------------------------------------------
    localparam [2:0] FWD_REG       = 3'd0;
    localparam [2:0] FWD_EX_MEM    = 3'd1;
    localparam [2:0] FWD_MEM1_MEM2 = 3'd2;
    localparam [2:0] FWD_LATE_LOAD = 3'd3;
    localparam [2:0] FWD_MEM_WB    = 3'd4;
    localparam [2:0] FWD_MEM2_LOAD = 3'd5;

    // Source indices: 0=resident operand, 1=ex_mem, 2=mem1_mem2, 3=mem_wb
    function [1:0] old_branch_src;      // forwarding.select_branch_data
        input [2:0] sel;
        begin
            case (sel)
                FWD_EX_MEM:    old_branch_src = 2'd1;
                FWD_MEM1_MEM2: old_branch_src = 2'd2;
                FWD_MEM_WB:    old_branch_src = 2'd3;
                default:       old_branch_src = 2'd0;
            endcase
        end
    endfunction

    function [1:0] new_branch_src;      // forwarding.select_nonlate_data (2-bit)
        input [1:0] sel;
        begin
            case (sel)
                2'd1:    new_branch_src = 2'd1;
                2'd2:    new_branch_src = 2'd2;
                2'd3:    new_branch_src = 2'd3;
                default: new_branch_src = 2'd0;
            endcase
        end
    endfunction

    // ------------------------------------------------------------------
    // B) branch condition encodings (defines.v)
    // ------------------------------------------------------------------
    localparam [2:0] BR_NONE = 3'd0;
    localparam [2:0] BR_EQ   = 3'd1;
    localparam [2:0] BR_NE   = 3'd2;
    localparam [2:0] BR_LT   = 3'd3;
    localparam [2:0] BR_GE   = 3'd4;
    localparam [2:0] BR_LTU  = 3'd5;
    localparam [2:0] BR_GEU  = 3'd6;

    function branch_cond_result;        // ex.v, unchanged
        input [2:0] cond_i;
        input       eq_i;
        input       lt_signed_i;
        input       lt_unsigned_i;
        begin
            case (cond_i)
                BR_EQ:   branch_cond_result = eq_i;
                BR_NE:   branch_cond_result = ~eq_i;
                BR_LT:   branch_cond_result = lt_signed_i;
                BR_GE:   branch_cond_result = ~lt_signed_i;
                BR_LTU:  branch_cond_result = lt_unsigned_i;
                BR_GEU:  branch_cond_result = ~lt_unsigned_i;
                default: branch_cond_result = 1'b0;
            endcase
        end
    endfunction

    function branch_dir_mismatch;       // ex.v, new
        input [1:0] kind_i;
        input       eq_i;
        input       lt_signed_i;
        input       lt_unsigned_i;
        input       inv_x_pred_i;
        begin
            case (kind_i)
                2'd0:    branch_dir_mismatch = eq_i          ^ inv_x_pred_i;
                2'd1:    branch_dir_mismatch = lt_signed_i   ^ inv_x_pred_i;
                2'd2:    branch_dir_mismatch = lt_unsigned_i ^ inv_x_pred_i;
                default: branch_dir_mismatch = ~inv_x_pred_i;
            endcase
        end
    endfunction

    integer i, c, e, s, u, p;

    reg m_ex_late, m_ex, m_mem1_slow, m_mem1, m_mem2;
    reg [2:0] fwd_sel;
    reg [1:0] br_sel;
    reg [2:0] cond;
    reg [1:0] kind;
    reg inv_x_pred, ref_mismatch, new_mismatch;

    initial begin
        // ---------------- A ----------------
        for (i = 0; i < 32; i = i + 1) begin
            {m_ex_late, m_ex, m_mem1_slow, m_mem1, m_mem2} = i[4:0];

            fwd_sel = m_ex_late    ? FWD_LATE_LOAD :
                      m_ex         ? FWD_EX_MEM    :
                      m_mem1_slow  ? FWD_MEM2_LOAD :
                      m_mem1       ? FWD_MEM1_MEM2 :
                      m_mem2       ? FWD_MEM_WB    :
                                     FWD_REG;

            br_sel  = m_ex_late    ? 2'd0 :
                      m_ex         ? 2'd1 :
                      m_mem1_slow  ? 2'd0 :
                      m_mem1       ? 2'd2 :
                      m_mem2       ? 2'd3 :
                                     2'd0;

            if (old_branch_src(fwd_sel) !== new_branch_src(br_sel)) begin
                errors_a = errors_a + 1;
                $display("A MISMATCH: matches=%b fwd_sel=%0d(src %0d) br_sel=%0d(src %0d)",
                         i[4:0], fwd_sel, old_branch_src(fwd_sel),
                         br_sel, new_branch_src(br_sel));
            end
        end

        // ---------------- B ----------------
        for (c = 0; c <= 6; c = c + 1)
        for (e = 0; e <= 1; e = e + 1)
        for (s = 0; s <= 1; s = s + 1)
        for (u = 0; u <= 1; u = u + 1)
        for (p = 0; p <= 1; p = p + 1) begin
            cond         = c[2:0];
            kind         = (cond - 3'd1) >> 1;
            inv_x_pred   = (~cond[0]) ^ p[0];
            ref_mismatch = branch_cond_result(cond, e[0], s[0], u[0]) != p[0];
            new_mismatch = branch_dir_mismatch(kind, e[0], s[0], u[0], inv_x_pred);
            if (ref_mismatch !== new_mismatch) begin
                errors_b = errors_b + 1;
                $display("B MISMATCH: cond=%0d kind=%0d eq=%0d lts=%0d ltu=%0d pred=%0d ref=%0d new=%0d",
                         cond, kind, e[0], s[0], u[0], p[0],
                         ref_mismatch, new_mismatch);
            end
        end

        $display("A (br_sel encoding)     : 32 cases,  %0d mismatches", errors_a);
        $display("B (direction mismatch)  : 112 cases, %0d mismatches", errors_b);
        if (errors_a == 0 && errors_b == 0)
            $display("PASS");
        else
            $display("FAIL");
        $finish;
    end

endmodule
