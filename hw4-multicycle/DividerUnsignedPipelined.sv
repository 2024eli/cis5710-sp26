/* verilator lint_off WIDTH */
/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off UNOPTFLAT */
/* INSERT NAME AND PENNKEY HERE */

`timescale 1ns / 1ns

// quotient = dividend / divisor

module DividerUnsignedPipelined (
    input wire clk, rst, stall,
    input  wire  [31:0] i_dividend,
    input  wire  [31:0] i_divisor,
    output wire [31:0] o_remainder,
    output wire [31:0] o_quotient
);

    logic [31:0] dividend_stage [8:1];
    logic [31:0] remainder_stage [8:1];
    logic [31:0] quotient_stage [8:1];
    logic [31:0] divisor_stage  [8:1];

    genvar i;
    generate
        for (i = 0; i < 8; i = i + 1) begin : gen_stage
            wire [31:0] d_temp [4:0];
            wire [31:0] r_temp [4:0];
            wire [31:0] q_temp [4:0];

            wire [31:0] current_divisor;

            if (i == 0) begin : gen_first
                assign d_temp[0] = i_dividend;
                assign r_temp[0] = 32'b0;
                assign q_temp[0] = 32'b0;
                assign current_divisor = i_divisor;
            end else begin : gen_others
                assign d_temp[0] = dividend_stage[i];
                assign r_temp[0] = remainder_stage[i];
                assign q_temp[0] = quotient_stage[i];
                assign current_divisor = divisor_stage[i];
            end

            genvar j;
            for (j = 0; j < 4; j = j + 1) begin : gen_iter
                divu_1iter div_iter (
                    .i_dividend(d_temp[j]),
                    .i_divisor(current_divisor),
                    .i_remainder(r_temp[j]),
                    .i_quotient(q_temp[j]),
                    .o_dividend(d_temp[j+1]),
                    .o_remainder(r_temp[j+1]),
                    .o_quotient(q_temp[j+1])
                );
            end

            always_ff @(posedge clk) begin
                if (rst) begin
                    dividend_stage[i+1] <= 32'b0;
                    remainder_stage[i+1] <= 32'b0;
                    quotient_stage[i+1] <= 32'b0;
                    divisor_stage[i+1] <= 32'b0;
                end else if (!stall) begin
                    dividend_stage[i+1] <= d_temp[4];
                    remainder_stage[i+1] <= r_temp[4];
                    quotient_stage[i+1] <= q_temp[4];
                    divisor_stage[i+1] <= current_divisor;
                end
            end
        end
    endgenerate

    assign o_remainder = gen_stage[7].r_temp[4];
    assign o_quotient = gen_stage[7].q_temp[4];

endmodule


/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNOPTFLAT */
module divu_1iter (
    input  wire  [31:0] i_dividend,
    input  wire  [31:0] i_divisor,
    input  wire  [31:0] i_remainder,
    input  wire  [31:0] i_quotient,
    output wire [31:0] o_dividend,
    output wire [31:0] o_remainder,
    output wire [31:0] o_quotient
);

/* verilator lint_off WIDTH */
/* verilator lint_off WIDTHEXPAND */
    wire [31:0] remainder_next;
    assign remainder_next = (i_remainder << 1) | i_dividend[31];

    wire [30:0] quot_shifted;
    assign quot_shifted = i_quotient[30:0];
    
    assign o_quotient = (remainder_next < i_divisor) ? {quot_shifted, 1'b0} : {quot_shifted, 1'b1};
    assign o_remainder = (remainder_next < i_divisor) ? remainder_next : (remainder_next - i_divisor);
    
    assign o_dividend = i_dividend << 1;
/* verilator lint_on WIDTHEXPAND */
/* verilator lint_on WIDTH */

endmodule
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on DECLFILENAME */
