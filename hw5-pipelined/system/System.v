module MyClockGen (
	input_clk_25MHz,
	clk_proc,
	locked
);
	input input_clk_25MHz;
	output wire clk_proc;
	output wire locked;
	wire clkfb;
	(* FREQUENCY_PIN_CLKI = "25" *) (* FREQUENCY_PIN_CLKOP = "20" *) (* ICP_CURRENT = "12" *) (* LPF_RESISTOR = "8" *) (* MFG_ENABLE_FILTEROPAMP = "1" *) (* MFG_GMCREF_SEL = "2" *) EHXPLLL #(
		.PLLRST_ENA("DISABLED"),
		.INTFB_WAKE("DISABLED"),
		.STDBY_ENABLE("DISABLED"),
		.DPHASE_SOURCE("DISABLED"),
		.OUTDIVIDER_MUXA("DIVA"),
		.OUTDIVIDER_MUXB("DIVB"),
		.OUTDIVIDER_MUXC("DIVC"),
		.OUTDIVIDER_MUXD("DIVD"),
		.CLKI_DIV(5),
		.CLKOP_ENABLE("ENABLED"),
		.CLKOP_DIV(30),
		.CLKOP_CPHASE(15),
		.CLKOP_FPHASE(0),
		.FEEDBK_PATH("INT_OP"),
		.CLKFB_DIV(4)
	) pll_i(
		.RST(1'b0),
		.STDBY(1'b0),
		.CLKI(input_clk_25MHz),
		.CLKOP(clk_proc),
		.CLKFB(clkfb),
		.CLKINTFB(clkfb),
		.PHASESEL0(1'b0),
		.PHASESEL1(1'b0),
		.PHASEDIR(1'b1),
		.PHASESTEP(1'b1),
		.PHASELOADREG(1'b1),
		.PLLWAKESYNC(1'b0),
		.ENCLKOP(1'b0),
		.LOCK(locked)
	);
endmodule
module Disasm (
	insn,
	disasm
);
	parameter signed [7:0] PREFIX = "D";
	input wire [31:0] insn;
	output wire [255:0] disasm;
endmodule
module RegFile (
	rd,
	rd_data,
	rs1,
	rs1_data,
	rs2,
	rs2_data,
	clk,
	we,
	rst
);
	reg _sv2v_0;
	input wire [4:0] rd;
	input wire [31:0] rd_data;
	input wire [4:0] rs1;
	output reg [31:0] rs1_data;
	input wire [4:0] rs2;
	output reg [31:0] rs2_data;
	input wire clk;
	input wire we;
	input wire rst;
	localparam signed [31:0] NumRegs = 32;
	reg [31:0] regs [0:31];
	integer j;
	always @(posedge clk)
		if (rst)
			for (j = 0; j < NumRegs; j = j + 1)
				regs[j] <= 1'sb0;
		else begin
			if (we && (rd != 5'd0))
				regs[rd] <= rd_data;
			regs[0] <= 1'sb0;
		end
	always @(*) begin
		if (_sv2v_0)
			;
		if (rs1 == 5'd0)
			rs1_data = 1'sb0;
		else if ((we && (rd != 5'd0)) && (rd == rs1))
			rs1_data = rd_data;
		else
			rs1_data = regs[rs1];
		if (rs2 == 5'd0)
			rs2_data = 1'sb0;
		else if ((we && (rd != 5'd0)) && (rd == rs2))
			rs2_data = rd_data;
		else
			rs2_data = regs[rs2];
	end
	initial _sv2v_0 = 0;
endmodule
module DatapathPipelined (
	clk,
	rst,
	pc_to_imem,
	insn_from_imem,
	addr_to_dmem,
	load_data_from_dmem,
	store_data_to_dmem,
	store_we_to_dmem,
	halt,
	trace_completed_pc,
	trace_completed_insn,
	trace_completed_cycle_status
);
	reg _sv2v_0;
	input wire clk;
	input wire rst;
	output wire [31:0] pc_to_imem;
	input wire [31:0] insn_from_imem;
	output wire [31:0] addr_to_dmem;
	input wire [31:0] load_data_from_dmem;
	output wire [31:0] store_data_to_dmem;
	output wire [3:0] store_we_to_dmem;
	output wire halt;
	output wire [31:0] trace_completed_pc;
	output wire [31:0] trace_completed_insn;
	output wire [31:0] trace_completed_cycle_status;
	localparam [6:0] OpcodeLoad = 7'b0000011;
	localparam [6:0] OpcodeStore = 7'b0100011;
	localparam [6:0] OpcodeBranch = 7'b1100011;
	localparam [6:0] OpcodeJalr = 7'b1100111;
	localparam [6:0] OpcodeMiscMem = 7'b0001111;
	localparam [6:0] OpcodeJal = 7'b1101111;
	localparam [6:0] OpcodeRegImm = 7'b0010011;
	localparam [6:0] OpcodeRegReg = 7'b0110011;
	localparam [6:0] OpcodeEnviron = 7'b1110011;
	localparam [6:0] OpcodeAuipc = 7'b0010111;
	localparam [6:0] OpcodeLui = 7'b0110111;
	reg [31:0] cycles_current;
	always @(posedge clk)
		if (rst)
			cycles_current <= 0;
		else
			cycles_current <= cycles_current + 1;
	reg [31:0] f_pc_current;
	wire [31:0] f_insn;
	reg [31:0] f_cycle_status;
	wire x_redirect_taken;
	wire [31:0] x_redirect_target;
	always @(posedge clk)
		if (rst) begin
			f_pc_current <= 32'd0;
			f_cycle_status <= 32'd4;
		end
		else if (halt) begin
			f_pc_current <= f_pc_current;
			f_cycle_status <= f_cycle_status;
		end
		else if (x_redirect_taken) begin
			f_pc_current <= x_redirect_target;
			f_cycle_status <= 32'd8;
		end
		else begin
			f_pc_current <= f_pc_current + 4;
			f_cycle_status <= 32'd1;
		end
	assign pc_to_imem = f_pc_current;
	assign f_insn = insn_from_imem;
	wire [255:0] f_disasm;
	Disasm #(.PREFIX("F")) disasm_0fetch(
		.insn(f_insn),
		.disasm(f_disasm)
	);
	reg [95:0] decode_state;
	always @(posedge clk)
		if (rst)
			decode_state <= 96'h000000000000000000000004;
		else if (x_redirect_taken)
			decode_state <= 96'h000000000000000000000008;
		else
			decode_state <= {f_pc_current, f_insn, 32'd1};
	wire [255:0] d_disasm;
	Disasm #(.PREFIX("D")) disasm_1decode(
		.insn(decode_state[63-:32]),
		.disasm(d_disasm)
	);
	wire [6:0] d_opcode = decode_state[38:32];
	wire [2:0] d_funct3 = decode_state[46:44];
	wire [6:0] d_funct7 = decode_state[63:57];
	wire [4:0] d_rs1 = decode_state[51:47];
	wire [4:0] d_rs2 = decode_state[56:52];
	wire [4:0] d_rd = decode_state[43:39];
	wire [31:0] rf_rs1_data;
	wire [31:0] rf_rs2_data;
	wire wb_we;
	wire [4:0] wb_rd;
	wire [31:0] wb_data;
	RegFile rf(
		.rd(wb_rd),
		.rd_data(wb_data),
		.rs1(d_rs1),
		.rs1_data(rf_rs1_data),
		.rs2(d_rs2),
		.rs2_data(rf_rs2_data),
		.clk(clk),
		.we(wb_we),
		.rst(rst)
	);
	function automatic [31:0] imm_i;
		input reg [31:0] insn;
		imm_i = {{20 {insn[31]}}, insn[31:20]};
	endfunction
	function automatic [31:0] imm_b;
		input reg [31:0] insn;
		imm_b = {{19 {insn[31]}}, insn[31], insn[7], insn[30:25], insn[11:8], 1'b0};
	endfunction
	function automatic [31:0] imm_u;
		input reg [31:0] insn;
		imm_u = {insn[31:12], 12'b000000000000};
	endfunction
	function automatic [31:0] imm_j;
		input reg [31:0] insn;
		imm_j = {{11 {insn[31]}}, insn[31], insn[19:12], insn[20], insn[30:21], 1'b0};
	endfunction
	reg [31:0] d_imm;
	always @(*) begin
		if (_sv2v_0)
			;
		(* full_case, parallel_case *)
		case (d_opcode)
			OpcodeRegImm: d_imm = imm_i(decode_state[63-:32]);
			OpcodeBranch: d_imm = imm_b(decode_state[63-:32]);
			OpcodeLui: d_imm = imm_u(decode_state[63-:32]);
			OpcodeAuipc: d_imm = imm_u(decode_state[63-:32]);
			OpcodeJal: d_imm = imm_j(decode_state[63-:32]);
			OpcodeJalr: d_imm = imm_i(decode_state[63-:32]);
			default: d_imm = 1'sb0;
		endcase
	end
	reg [273:0] x_state;
	reg [273:0] x_state_next;
	reg [31:0] x_src1;
	reg [31:0] x_src2;
	reg [166:0] m_state;
	reg [133:0] w_state;
	always @(*) begin
		if (_sv2v_0)
			;
		x_src1 = rf_rs1_data;
		x_src2 = rf_rs2_data;
		if ((x_state[66] && (x_state[71-:5] != 5'd0)) && (x_state[71-:5] == d_rs1))
			x_src1 = x_state[31-:32];
		else if ((m_state[65] && (m_state[70-:5] != 5'd0)) && (m_state[70-:5] == d_rs1))
			x_src1 = m_state[64-:32];
		else if ((w_state[32] && (w_state[37-:5] != 5'd0)) && (w_state[37-:5] == d_rs1))
			x_src1 = w_state[31-:32];
		if ((x_state[66] && (x_state[71-:5] != 5'd0)) && (x_state[71-:5] == d_rs2))
			x_src2 = x_state[31-:32];
		else if ((m_state[65] && (m_state[70-:5] != 5'd0)) && (m_state[70-:5] == d_rs2))
			x_src2 = m_state[64-:32];
		else if ((w_state[32] && (w_state[37-:5] != 5'd0)) && (w_state[37-:5] == d_rs2))
			x_src2 = w_state[31-:32];
	end
	reg d_branch_taken_calc;
	reg [31:0] d_branch_target_calc;
	reg [31:0] x_alu_result_calc;
	always @(*) begin
		if (_sv2v_0)
			;
		d_branch_taken_calc = 1'b0;
		d_branch_target_calc = decode_state[95-:32] + d_imm;
		x_alu_result_calc = 1'sb0;
		(* full_case, parallel_case *)
		case (decode_state[38:32])
			OpcodeLui: x_alu_result_calc = d_imm;
			OpcodeAuipc: x_alu_result_calc = decode_state[95-:32] + d_imm;
			OpcodeJal: begin
				x_alu_result_calc = decode_state[95-:32] + 32'd4;
				d_branch_taken_calc = 1'b1;
				d_branch_target_calc = decode_state[95-:32] + d_imm;
			end
			OpcodeJalr: begin
				x_alu_result_calc = decode_state[95-:32] + 32'd4;
				d_branch_taken_calc = 1'b1;
				d_branch_target_calc = (x_src1 + d_imm) & ~32'd1;
			end
			OpcodeRegImm:
				(* full_case, parallel_case *)
				case (decode_state[46:44])
					3'b000: x_alu_result_calc = x_src1 + d_imm;
					3'b010: x_alu_result_calc = {{31 {1'b0}}, $signed(x_src1) < $signed(d_imm)};
					3'b011: x_alu_result_calc = {{31 {1'b0}}, x_src1 < d_imm};
					3'b100: x_alu_result_calc = x_src1 ^ d_imm;
					3'b110: x_alu_result_calc = x_src1 | d_imm;
					3'b111: x_alu_result_calc = x_src1 & d_imm;
					3'b001: x_alu_result_calc = x_src1 << decode_state[56:52];
					3'b101:
						if (decode_state[62])
							x_alu_result_calc = $signed(x_src1) >>> decode_state[56:52];
						else
							x_alu_result_calc = x_src1 >> decode_state[56:52];
					default: x_alu_result_calc = 1'sb0;
				endcase
			OpcodeRegReg:
				(* full_case, parallel_case *)
				case (decode_state[46:44])
					3'b000:
						if (decode_state[62])
							x_alu_result_calc = x_src1 - x_src2;
						else
							x_alu_result_calc = x_src1 + x_src2;
					3'b001: x_alu_result_calc = x_src1 << x_src2[4:0];
					3'b010: x_alu_result_calc = {{31 {1'b0}}, $signed(x_src1) < $signed(x_src2)};
					3'b011: x_alu_result_calc = {{31 {1'b0}}, x_src1 < x_src2};
					3'b100: x_alu_result_calc = x_src1 ^ x_src2;
					3'b101:
						if (decode_state[62])
							x_alu_result_calc = $signed(x_src1) >>> x_src2[4:0];
						else
							x_alu_result_calc = x_src1 >> x_src2[4:0];
					3'b110: x_alu_result_calc = x_src1 | x_src2;
					3'b111: x_alu_result_calc = x_src1 & x_src2;
					default: x_alu_result_calc = 1'sb0;
				endcase
			OpcodeBranch: begin
				(* full_case, parallel_case *)
				case (decode_state[46:44])
					3'b000: d_branch_taken_calc = x_src1 == x_src2;
					3'b001: d_branch_taken_calc = x_src1 != x_src2;
					3'b100: d_branch_taken_calc = $signed(x_src1) < $signed(x_src2);
					3'b101: d_branch_taken_calc = $signed(x_src1) >= $signed(x_src2);
					3'b110: d_branch_taken_calc = x_src1 < x_src2;
					3'b111: d_branch_taken_calc = x_src1 >= x_src2;
					default: d_branch_taken_calc = 1'b0;
				endcase
				x_alu_result_calc = 1'sb0;
			end
			default: x_alu_result_calc = 1'sb0;
		endcase
	end
	always @(*) begin
		if (_sv2v_0)
			;
		x_state_next = 1'sb0;
		x_state_next[273-:32] = decode_state[95-:32];
		x_state_next[241-:32] = decode_state[63-:32];
		x_state_next[209-:32] = decode_state[31-:32];
		x_state_next[177-:32] = rf_rs1_data;
		x_state_next[145-:32] = rf_rs2_data;
		x_state_next[113-:32] = d_imm;
		x_state_next[81-:5] = d_rs1;
		x_state_next[76-:5] = d_rs2;
		x_state_next[71-:5] = d_rd;
		x_state_next[64] = d_branch_taken_calc;
		x_state_next[63-:32] = d_branch_target_calc;
		x_state_next[31-:32] = x_alu_result_calc;
		x_state_next[66] = 1'b0;
		x_state_next[65] = 1'b0;
		(* full_case, parallel_case *)
		case (d_opcode)
			OpcodeLui: x_state_next[66] = d_rd != 5'd0;
			OpcodeAuipc: x_state_next[66] = d_rd != 5'd0;
			OpcodeJal: x_state_next[66] = d_rd != 5'd0;
			OpcodeJalr: x_state_next[66] = d_rd != 5'd0;
			OpcodeRegImm: x_state_next[66] = d_rd != 5'd0;
			OpcodeRegReg: x_state_next[66] = d_rd != 5'd0;
			OpcodeBranch: x_state_next[65] = 1'b1;
			default: x_state_next[66] = 1'b0;
		endcase
	end
	always @(posedge clk)
		if (rst)
			x_state <= 274'h1000000000000000000000000000000000000000000000;
		else if (x_redirect_taken)
			x_state <= 274'h2000000000000000000000000000000000000000000000;
		else
			x_state <= x_state_next;
	wire [255:0] x_disasm;
	Disasm #(.PREFIX("X")) disasm_2execute(
		.insn(x_state[241-:32]),
		.disasm(x_disasm)
	);
	function automatic [31:0] sv2v_cast_32;
		input reg [31:0] inp;
		sv2v_cast_32 = inp;
	endfunction
	function automatic [4:0] sv2v_cast_5;
		input reg [4:0] inp;
		sv2v_cast_5 = inp;
	endfunction
	always @(posedge clk)
		if (rst)
			m_state <= 167'h000000000000000000000002000000000000000000;
		else
			m_state <= {sv2v_cast_32(x_state[273-:32]), sv2v_cast_32(x_state[241-:32]), sv2v_cast_32(x_state[209-:32]), sv2v_cast_5(x_state[71-:5]), x_state[66], sv2v_cast_32(x_state[31-:32]), x_state[64], sv2v_cast_32(x_state[63-:32])};
	assign x_redirect_taken = x_state[64];
	assign x_redirect_target = x_state[63-:32];
	wire [255:0] m_disasm;
	Disasm #(.PREFIX("M")) disasm_3memory(
		.insn(m_state[134-:32]),
		.disasm(m_disasm)
	);
	always @(posedge clk)
		if (rst)
			w_state <= 134'h0000000000000000000000010000000000;
		else
			w_state <= {sv2v_cast_32(m_state[166-:32]), sv2v_cast_32(m_state[134-:32]), sv2v_cast_32(m_state[102-:32]), sv2v_cast_5(m_state[70-:5]), m_state[65], sv2v_cast_32(m_state[64-:32])};
	wire [255:0] w_disasm;
	Disasm #(.PREFIX("W")) disasm_4writeback(
		.insn(w_state[101-:32]),
		.disasm(w_disasm)
	);
	assign wb_we = w_state[32];
	assign wb_rd = w_state[37-:5];
	assign wb_data = w_state[31-:32];
	assign addr_to_dmem = 32'b00000000000000000000000000000000;
	assign store_data_to_dmem = 32'b00000000000000000000000000000000;
	assign store_we_to_dmem = 4'b0000;
	assign halt = w_state[101-:32] == 32'h00000073;
	assign trace_completed_pc = w_state[133-:32];
	assign trace_completed_insn = w_state[101-:32];
	assign trace_completed_cycle_status = w_state[69-:32];
	initial _sv2v_0 = 0;
endmodule
module MemorySingleCycle (
	rst,
	clk,
	pc_to_imem,
	insn_from_imem,
	addr_to_dmem,
	load_data_from_dmem,
	store_data_to_dmem,
	store_we_to_dmem
);
	reg _sv2v_0;
	parameter signed [31:0] NUM_WORDS = 512;
	input wire rst;
	input wire clk;
	input wire [31:0] pc_to_imem;
	output reg [31:0] insn_from_imem;
	input wire [31:0] addr_to_dmem;
	output reg [31:0] load_data_from_dmem;
	input wire [31:0] store_data_to_dmem;
	input wire [3:0] store_we_to_dmem;
	reg [31:0] mem_array [0:NUM_WORDS - 1];
	initial $readmemh("mem_initial_contents.hex", mem_array);
	always @(*)
		if (_sv2v_0)
			;
	localparam signed [31:0] AddrMsb = $clog2(NUM_WORDS) + 1;
	localparam signed [31:0] AddrLsb = 2;
	always @(negedge clk)
		if (rst)
			;
		else
			insn_from_imem <= mem_array[{pc_to_imem[AddrMsb:AddrLsb]}];
	always @(negedge clk)
		if (rst)
			;
		else begin
			if (store_we_to_dmem[0])
				mem_array[addr_to_dmem[AddrMsb:AddrLsb]][7:0] <= store_data_to_dmem[7:0];
			if (store_we_to_dmem[1])
				mem_array[addr_to_dmem[AddrMsb:AddrLsb]][15:8] <= store_data_to_dmem[15:8];
			if (store_we_to_dmem[2])
				mem_array[addr_to_dmem[AddrMsb:AddrLsb]][23:16] <= store_data_to_dmem[23:16];
			if (store_we_to_dmem[3])
				mem_array[addr_to_dmem[AddrMsb:AddrLsb]][31:24] <= store_data_to_dmem[31:24];
			load_data_from_dmem <= mem_array[{addr_to_dmem[AddrMsb:AddrLsb]}];
		end
	initial _sv2v_0 = 0;
endmodule
module SystemResourceCheck (
	external_clk_25MHz,
	btn,
	led
);
	input wire external_clk_25MHz;
	input wire [6:0] btn;
	output wire [7:0] led;
	wire clk_proc;
	wire clk_locked;
	MyClockGen clock_gen(
		.input_clk_25MHz(external_clk_25MHz),
		.clk_proc(clk_proc),
		.locked(clk_locked)
	);
	wire [31:0] pc_to_imem;
	wire [31:0] insn_from_imem;
	wire [31:0] mem_data_addr;
	wire [31:0] mem_data_loaded_value;
	wire [31:0] mem_data_to_write;
	wire [3:0] mem_data_we;
	wire [31:0] trace_writeback_pc;
	wire [31:0] trace_writeback_insn;
	wire [31:0] trace_writeback_cycle_status;
	MemorySingleCycle #(.NUM_WORDS(128)) memory(
		.rst(!clk_locked),
		.clk(clk_proc),
		.pc_to_imem(pc_to_imem),
		.insn_from_imem(insn_from_imem),
		.addr_to_dmem(mem_data_addr),
		.load_data_from_dmem(mem_data_loaded_value),
		.store_data_to_dmem(mem_data_to_write),
		.store_we_to_dmem(mem_data_we)
	);
	DatapathPipelined datapath(
		.clk(clk_proc),
		.rst(!clk_locked),
		.pc_to_imem(pc_to_imem),
		.insn_from_imem(insn_from_imem),
		.addr_to_dmem(mem_data_addr),
		.store_data_to_dmem(mem_data_to_write),
		.store_we_to_dmem(mem_data_we),
		.load_data_from_dmem(mem_data_loaded_value),
		.halt(led[0]),
		.trace_completed_pc(trace_writeback_pc),
		.trace_completed_insn(trace_writeback_insn),
		.trace_completed_cycle_status(trace_writeback_cycle_status)
	);
endmodule