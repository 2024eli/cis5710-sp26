`timescale 1ns / 1ps

/**
 * @param a first 1-bit input
 * @param b second 1-bit input
 * @param g whether a and b generate a carry
 * @param p whether a and b would propagate an incoming carry
 */
module gp1(input wire a, b,
           output wire g, p);
   assign g = a & b;
   assign p = a | b;
endmodule

/**
 * Computes aggregate generate/propagate signals over a 4-bit window.
 * @param gin incoming generate signals
 * @param pin incoming propagate signals
 * @param cin the incoming carry
 * @param gout whether these 4 bits internally would generate a carry-out (independent of cin)
 * @param pout whether these 4 bits internally would propagate an incoming carry from cin
 * @param cout the carry outs for the low-order 3 bits
 */
module gp4(input wire [3:0] gin, pin,
           input wire cin,
           output wire gout, pout,
           output wire [2:0] cout);

   // TODO: your code here
   wire [3:0] g, p;
   assign g = gin;
   assign p = pin;

   wire c1, c2, c3;
   assign c1 = g[0] | (p[0] & cin);
   assign c2 = g[1] | (p[1] & g[0]) | (p[1] & p[0] & cin);
   assign c3 = g[2] | (p[2] & g[1]) | (p[2] & p[1] & g[0]) | (p[2] & p[1] & p[0] & cin);

   assign cout = {c3, c2, c1};
   assign gout = g[3] | (p[3] & g[2]) | (p[3] & p[2] & g[1]) | (p[3] & p[2] & p[1] & g[0]);
   assign pout = &p;

endmodule

/** Same as gp4 but for an 8-bit window instead */
module gp8(input wire [7:0] gin, pin,
           input wire cin,
           output wire gout, pout,
           output wire [6:0] cout);

   // TODO: your code here
   wire [7:0] g, p;
   assign g = gin;
   assign p = pin;

   wire c1, c2, c3, c4, c5, c6, c7;
   assign c1 = g[0] | (p[0] & cin);
   assign c2 = g[1] | (p[1] & g[0]) | (p[1] & p[0] & cin);
   assign c3 = g[2] | (p[2] & g[1]) | (p[2] & p[1] & g[0]) | (p[2] & p[1] & p[0] & cin);
   assign c4 = g[3] | (p[3] & g[2]) | (p[3] & p[2] & g[1]) | (p[3] & p[2] & p[1] & g[0]) | (p[3] & p[2] & p[1] & p[0] & cin);
   assign c5 = g[4] | (p[4] & g[3]) | (p[4] & p[3] & g[2]) | (p[4] & p[3] & p[2] & g[1]) | (p[4] & p[3] & p[2] & p[1] & g[0]) | 
               (p[4] & p[3] & p[2] & p[1] & p[0] & cin);
   assign c6 = g[5] | (p[5] & g[4]) | (p[5] & p[4] & g[3]) | (p[5] & p[4] & p[3] & g[2]) | (p[5] & p[4] & p[3] & p [2]& g [1]) | 
               (p [5]& 	p [4]& 	p [3]& 	p [2]& 	p [1]& 	g [0])|	(p [5]& 	p [4]& 	p [3]& 	p [2]& 	p [1]& 	p [0]& 	cin);
   assign c7 = g[6] | (p[6] & g[5]) | (p[6] & p[5] & g[4]) | (p[6] & p[5] & p[4] & g[3]) | (p[6] & p[5] & p[4] & p[3] & g[2]) | 
               (p[6] & p[5] & p[4] & p[3] & p[2] & g[1]) | (p[6] & p[5] & p[4] & p[3] & p[2] & p[1] & g[0]) | 
               (p[6] & p[5] & p[4] & p[3] & p[2] & p[1] & p[0] & cin);

   assign cout = {c7, c6, c5, c4, c3, c2, c1};
   assign gout = g[7] | (p[7] & g[6]) | (p[7] & p[6] & g[5]) | 
                  (p[7] & p[6] & p[5] & g[4]) | (p[7] & p[6] & p[5] & p[4] & g[3]) | 
                  (p[7] & p[6] & p[5] & p[4] & p[3] & g[2]) | (p[7] & p[6] & p[5] & p[4] & p[3] & p[2] & g[1]) 
                  | (p[7] & p[6] & p[5] & p[4] & p[3] & p[2] & p[1] & g[0]);
   assign pout = &p;


endmodule

module CarryLookaheadAdder
  (input wire [31:0]  a, b,
   input wire         cin,
   output wire [31:0] sum);

   // TODO: your code here
   wire [31:0] g, p;
   genvar i;
   generate
      for (i = 0; i < 32; i = i + 1) begin : GEN_GP
         gp1 g_loop(.a(a[i]), .b(b[i]), .g(g[i]), .p(p[i]));
      end
   endgenerate

   wire gout0, pout0;
   wire gout1, pout1;
   wire gout2, pout2;
   wire gout3, pout3;

   wire c8, c16, c24;
   wire [6:0] c0_int, c1_int, c2_int, c3_int;

   // First block uses cin
   gp8 gp0(.gin(g[7:0]),   .pin(p[7:0]),   .cin(cin), .gout(gout0), .pout(pout0), .cout(c0_int));

   // These cin's are block carries
   gp8 gp1(.gin(g[15:8]),  .pin(p[15:8]),  .cin(c8),  .gout(gout1), .pout(pout1), .cout(c1_int));
   gp8 gp2(.gin(g[23:16]), .pin(p[23:16]), .cin(c16), .gout(gout2), .pout(pout2), .cout(c2_int));
   gp8 gp3(.gin(g[31:24]), .pin(p[31:24]), .cin(c24), .gout(gout3), .pout(pout3), .cout(c3_int));

   wire gout4, pout4;
   wire [2:0] group_cout;
   gp4 gp4_groups(
      .gin({gout3, gout2, gout1, gout0}),
      .pin({pout3, pout2, pout1, pout0}),
      .cin(cin),
      .gout(gout4),
      .pout(pout4),
      .cout(group_cout)
   );

   assign c8  = group_cout[0];
   assign c16 = group_cout[1];
   assign c24 = group_cout[2];

   // ---- build carry into each bit (32-wide) ----
   wire [31:0] cbit;
   assign cbit[0]    = cin;
   assign cbit[7:1]  = c0_int;   

   assign cbit[8]    = c8;
   assign cbit[15:9] = c1_int;  

   assign cbit[16]   = c16;
   assign cbit[23:17]= c2_int;

   assign cbit[24]   = c24;
   assign cbit[31:25] = c3_int; 

   assign sum = a ^ b ^ cbit;


endmodule
