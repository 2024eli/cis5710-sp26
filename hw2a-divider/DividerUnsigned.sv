/* Name: Faiyaz Hasan and Evelyn Li */
/* PennKey: faiyazhasan and 2024eli */

`timescale 1ns / 1ns

// quotient = dividend / divisor

module DividerUnsigned (
    input  wire [31:0] i_dividend,
    input  wire [31:0] i_divisor,
    output wire [31:0] o_remainder,
    output wire [31:0] o_quotient
);

    wire [31:0] dividend_wire [32:0];
    wire [31:0] remainder_wire [32:0];
    wire [31:0] quotient_wire [32:0];

    assign dividend_wire[0] = i_dividend;
    assign remainder_wire[0] = 32'b0;
    assign quotient_wire[0] = 32'b0;

    genvar i;
    generate
        for (i = 0; i < 32; i = i + 1) begin : gen_div_iter
            DividerOneIter div_iter (
                .i_dividend(dividend_wire[i]),
                .i_divisor(i_divisor),
                .i_remainder(remainder_wire[i]),
                .i_quotient(quotient_wire[i]),
                .o_dividend(dividend_wire[i+1]),
                .o_remainder(remainder_wire[i+1]),
                .o_quotient(quotient_wire[i+1])
            );
        end
    endgenerate

    assign o_remainder = remainder_wire[32];
    assign o_quotient = quotient_wire[32];

endmodule


/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNOPTFLAT */
module DividerOneIter (
    input  wire [31:0] i_dividend,
    input  wire [31:0] i_divisor,
    input  wire [31:0] i_remainder,
    input  wire [31:0] i_quotient,
    output wire [31:0] o_dividend,
    output wire [31:0] o_remainder,
    output wire [31:0] o_quotient
);
    /* verilator lint_off WIDTH */
  /*
    for (int i = 0; i < 32; i++) {
        remainder = (remainder << 1) | ((dividend >> 31) & 0x1);
        if (remainder < divisor) {
            quotient = (quotient << 1);
        } else {
            quotient = (quotient << 1) | 0x1;
            remainder = remainder - divisor;
        }
        dividend = dividend << 1;
    }
    */
    
    // remainder = (remainder << 1) | ((dividend >> 31) & 0x1);
    wire [31:0] remainder_next;
    assign remainder_next = (i_remainder << 1) | i_dividend[31];

    // if (remainder < divisor) ... else ...
    wire [30:0] quot_shifted;
    assign quot_shifted = i_quotient[30:0];
    
    assign o_quotient = (remainder_next < i_divisor) ? {quot_shifted, 1'b0} : {quot_shifted, 1'b1};
    assign o_remainder = (remainder_next < i_divisor) ? remainder_next : (remainder_next - i_divisor);
    
    // dividend = dividend << 1;
    wire [30:0] div_shifted;
    assign div_shifted = i_dividend[30:0];
    assign o_dividend = {div_shifted, 1'b0};
    /* verilator lint_on WIDTH */

endmodule
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on DECLFILENAME */
