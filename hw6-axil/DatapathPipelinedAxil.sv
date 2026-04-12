`timescale 1ns / 1ns

// registers are 32 bits in RV32
`define REG_SIZE 31:0

// insns are 32 bits in RV32IM
`define INSN_SIZE 31:0

// RV opcodes are 7 bits
`define OPCODE_SIZE 6:0

`define ADDR_WIDTH 32
`define DATA_WIDTH 32

`ifndef DIVIDER_STAGES
`define DIVIDER_STAGES 8
`endif

`ifndef SYNTHESIS
  `include "../hw3-singlecycle/RvDisassembler.sv"
`endif
`include "../hw2b-cla/CarryLookaheadAdder.sv"
`include "../hw3-singlecycle/cycle_status.sv"
`include "../hw4-multicycle/DividerUnsignedPipelined.sv"
`include "EasyAxilMemory.sv"

module Disasm #(
    PREFIX = "D"
) (
    input wire [31:0] insn,
    output wire [(8*32)-1:0] disasm
);
`ifndef RISCV_FORMAL
`ifndef SYNTHESIS
  // this code is only for simulation, not synthesis
  string disasm_string;
  always_comb begin
    disasm_string = rv_disasm(insn);
  end
  // HACK: get disasm_string to appear in GtkWave, which can apparently show only wire/logic. Also,
  // string needs to be reversed to render correctly.
  genvar i;
  for (i = 3; i < 32; i = i + 1) begin : gen_disasm
    assign disasm[((i+1-3)*8)-1-:8] = disasm_string[31-i];
  end
  assign disasm[255-:8] = PREFIX;
  assign disasm[247-:8] = ":";
  assign disasm[239-:8] = " ";
`endif
`endif
endmodule

module RegFile (
    input logic [4:0] rd,
    input logic [`REG_SIZE] rd_data,
    input logic [4:0] rs1,
    output logic [`REG_SIZE] rs1_data,
    input logic [4:0] rs2,
    output logic [`REG_SIZE] rs2_data,

    input logic clk,
    input logic we,
    input logic rst
);
  localparam int NumRegs = 32;
  logic [`REG_SIZE] regs[NumRegs];
  integer j;

  always_ff @(posedge clk) begin
    if (rst) begin
      for (j = 0; j < NumRegs; j = j + 1) begin
        regs[j] <= '0;
      end
    end else begin
      if (we && (rd != 5'd0)) begin
        regs[rd] <= rd_data;
      end
      regs[0] <= '0;
    end
  end

  always_comb begin
    // WD bypass built into RF:
    if (rs1 == 5'd0) begin
      rs1_data = '0;
    end else if (we && (rd != 5'd0) && (rd == rs1)) begin
      rs1_data = rd_data;
    end else begin
      rs1_data = regs[rs1];
    end

    if (rs2 == 5'd0) begin
      rs2_data = '0;
    end else if (we && (rd != 5'd0) && (rd == rs2)) begin
      rs2_data = rd_data;
    end else begin
      rs2_data = regs[rs2];
    end
  end

endmodule

typedef struct packed {
  logic [`REG_SIZE] pc;
  cycle_status_e cycle_status;
} stage_g_t;

typedef struct packed {
  logic [`REG_SIZE] pc;
  logic [`INSN_SIZE] insn;
  cycle_status_e cycle_status;
} stage_decode_t;

typedef struct packed {
  logic [`REG_SIZE] pc;
  logic [`INSN_SIZE] insn;
  cycle_status_e cycle_status;

  logic [`REG_SIZE] rs1_val;
  logic [`REG_SIZE] rs2_val;
  logic [`REG_SIZE] imm;

  logic [4:0] rs1;
  logic [4:0] rs2;
  logic [4:0] rd;
  logic [2:0] funct3;

  logic regwrite;
  logic is_branch;
  logic branch_taken;
  logic [`REG_SIZE] branch_target;

  logic [`REG_SIZE] alu_result;
  
  logic is_load;
  logic is_store;
  logic is_div_insn;
} stage_execute_t;

typedef struct packed {
  logic [`REG_SIZE] pc;
  logic [`INSN_SIZE] insn;
  cycle_status_e cycle_status;

  logic [4:0] rs2;
  logic [`REG_SIZE] rs2_val;
  logic [2:0] funct3;

  logic is_load;
  logic is_store;

  logic [4:0] rd;
  logic regwrite;
  logic [`REG_SIZE] result;

  logic branch_taken;
  logic [`REG_SIZE] branch_target;
} stage_memory_t;

typedef struct packed {
  logic [`REG_SIZE] pc;
  logic [`INSN_SIZE] insn;
  cycle_status_e cycle_status;

  logic [4:0] rd;
  logic regwrite;
  logic [`REG_SIZE] result;
  logic is_load;
} stage_writeback_t;

typedef struct packed {
  logic valid;
  logic [4:0] rd;
  logic quotient_sign;
  logic remainder_sign;
  logic is_rem;
  logic [`REG_SIZE] pc;
  logic [`INSN_SIZE] insn;
} div_track_t;



module DatapathPipelinedAxil (
    input wire clk,
    input wire rst,

    // interface to insn memory/cache
    axil_if.manager imem,
    // interface to data memory/cache
    axil_if.manager dmem,

    output logic halt,

    // The PC of the insn currently in Writeback. 0 if not a valid insn.
    output logic [`REG_SIZE] trace_completed_pc,
    // The bits of the insn currently in Writeback. 0 if not a valid insn.
    output logic [`INSN_SIZE] trace_completed_insn,
    // The status of the insn (or stall) currently in Writeback. See the cycle_status.sv file for valid values.
    output cycle_status_e trace_completed_cycle_status
);



  // cycle counter



  localparam bit [`OPCODE_SIZE] OpcodeLoad     = 7'b00_000_11;
  localparam bit [`OPCODE_SIZE] OpcodeStore    = 7'b01_000_11;
  localparam bit [`OPCODE_SIZE] OpcodeBranch   = 7'b11_000_11;
  localparam bit [`OPCODE_SIZE] OpcodeJalr     = 7'b11_001_11;
  localparam bit [`OPCODE_SIZE] OpcodeJal      = 7'b11_011_11;
  localparam bit [`OPCODE_SIZE] OpcodeRegImm   = 7'b00_100_11;
  localparam bit [`OPCODE_SIZE] OpcodeRegReg   = 7'b01_100_11;
  localparam bit [`OPCODE_SIZE] OpcodeAuipc    = 7'b00_101_11;
  localparam bit [`OPCODE_SIZE] OpcodeLui      = 7'b01_101_11;

  logic [`REG_SIZE] cycles_current;
  always_ff @(posedge clk) begin
    if (rst) begin
      cycles_current <= 0;
    end else begin
      cycles_current <= cycles_current + 1;
    end
  end


  /***************/
  /* FETCH STAGE */
  /***************/
  logic d_stall;
  logic g_stall;
  assign g_stall = d_stall;
  
  logic inflight_div_exists;
  
  logic [`REG_SIZE] f_pc_current;
  cycle_status_e f_cycle_status;

  wire x_redirect_taken;
  wire [`REG_SIZE] x_redirect_target;

  always_ff @(posedge clk) begin
    if (rst) begin
      f_pc_current   <= 32'd0;
      f_cycle_status <= CYCLE_NO_STALL;
    end else if (halt) begin
      f_pc_current   <= f_pc_current;
      f_cycle_status <= f_cycle_status;
    end else if (x_redirect_taken) begin
      f_pc_current   <= x_redirect_target;
      f_cycle_status <= CYCLE_NO_STALL;
    end else if (g_stall) begin
      f_pc_current   <= f_pc_current;
      f_cycle_status <= f_cycle_status;
    end else begin
      f_pc_current   <= f_pc_current + 4;
      f_cycle_status <= CYCLE_NO_STALL;
    end
  end

  assign imem.ARADDR  = f_pc_current;
  assign imem.ARVALID = !g_stall && !x_redirect_taken && !rst && !halt;
  assign imem.ARPROT  = 3'b0;

  // Unused write ports for imem
  assign imem.AWVALID = 1'b0;
  assign imem.AWADDR = 0;
  assign imem.AWPROT = 3'b0;
  assign imem.WVALID = 1'b0;
  assign imem.WDATA = 0;
  assign imem.WSTRB = 0;
  assign imem.BREADY = 1'b0;

  /***************/
  /* G STAGE     */
  /***************/
  stage_g_t g_state;
  always_ff @(posedge clk) begin
    if (rst) begin
      g_state <= '{pc: 0, cycle_status: CYCLE_IMEM_WAIT};
    end else if (halt) begin
      g_state <= g_state;
    end else if (x_redirect_taken) begin
      g_state <= '{pc: 0, cycle_status: CYCLE_TAKEN_BRANCH};
    end else if (d_stall) begin
      g_state <= g_state;
    end else begin
      // if F was stalled in the previous cycle, the PC we tracked is f_pc_current.
      // But notice if g_stall -> d_stall, g_state remains the same.
      // actually, if x_redirect_taken we put a bubble.
      // If we are here, neither x_redirect_taken nor d_stall is true.
      if (f_cycle_status == CYCLE_TAKEN_BRANCH) begin
        // bubble
        g_state <= '{pc: 0, cycle_status: CYCLE_TAKEN_BRANCH};
      end else begin
        g_state <= '{pc: f_pc_current, cycle_status: f_cycle_status};
      end
    end
  end

  assign imem.RREADY = !d_stall;

  // If a branch is taken, flush F, G, D. We handle F up there, G here, D below.

  /****************/
  /* DECODE STAGE */
  /****************/
  stage_decode_t decode_state;

  always_ff @(posedge clk) begin
    if (rst) begin
      decode_state <= '{
        pc: 0,
        insn: 0,
        cycle_status: CYCLE_IMEM_WAIT
      };
    end else if (x_redirect_taken) begin
      decode_state <= '{
        pc: g_state.pc,
        insn: 32'b0,
        cycle_status: CYCLE_TAKEN_BRANCH
      };
    end else if (d_stall) begin
      decode_state <= decode_state;
    end else begin
      decode_state <= '{
        pc: g_state.pc,
        insn: (g_state.cycle_status != CYCLE_NO_STALL) ? 32'h00000000 : imem.RDATA,
        cycle_status: g_state.cycle_status
      };
    end
  end

  wire [255:0] d_disasm;
  Disasm #(.PREFIX("D")) disasm_1decode (
      .insn  (decode_state.insn),
      .disasm(d_disasm)
  );

  wire [6:0] d_opcode = decode_state.insn[6:0];
  wire [2:0] d_funct3 = decode_state.insn[14:12];
  wire [6:0] d_funct7 = decode_state.insn[31:25];
  wire [4:0] d_rs1    = decode_state.insn[19:15];
  wire [4:0] d_rs2    = decode_state.insn[24:20];
  wire [4:0] d_rd     = decode_state.insn[11:7];

  logic [`REG_SIZE] rf_rs1_data, rf_rs2_data;
  logic wb_we;
  logic [4:0] wb_rd;
  logic [`REG_SIZE] wb_data;

  // required name: rf
  RegFile rf (
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

  function automatic logic [`REG_SIZE] imm_i(input logic [`INSN_SIZE] insn);
    imm_i = {{20{insn[31]}}, insn[31:20]};
  endfunction

  function automatic logic [`REG_SIZE] imm_s(input logic [`INSN_SIZE] insn);
    imm_s = {{20{insn[31]}}, insn[31:25], insn[11:7]};
  endfunction

  function automatic logic [`REG_SIZE] imm_b(input logic [`INSN_SIZE] insn);
    imm_b = {{19{insn[31]}}, insn[31], insn[7], insn[30:25], insn[11:8], 1'b0};
  endfunction

  function automatic logic [`REG_SIZE] imm_u(input logic [`INSN_SIZE] insn);
    imm_u = {insn[31:12], 12'b0};
  endfunction

  function automatic logic [`REG_SIZE] imm_j(input logic [`INSN_SIZE] insn);
    imm_j = {{11{insn[31]}}, insn[31], insn[19:12], insn[20], insn[30:21], 1'b0};
  endfunction

  logic [`REG_SIZE] d_imm;
  always_comb begin
    unique case (d_opcode)
      OpcodeRegImm: d_imm = imm_i(decode_state.insn);
      OpcodeBranch: d_imm = imm_b(decode_state.insn);
      OpcodeLui:    d_imm = imm_u(decode_state.insn);
      OpcodeAuipc:  d_imm = imm_u(decode_state.insn);
      OpcodeJal:    d_imm = imm_j(decode_state.insn);
      OpcodeJalr:   d_imm = imm_i(decode_state.insn);
      OpcodeLoad:   d_imm = imm_i(decode_state.insn);
      OpcodeStore:  d_imm = imm_s(decode_state.insn);
      default:      d_imm = '0;
    endcase
  end

  wire d_is_load  = (d_opcode == OpcodeLoad);
  wire d_is_store = (d_opcode == OpcodeStore);
  wire d_is_div   = (d_opcode == OpcodeRegReg) && (d_funct7 == 7'd1) && (d_funct3 >= 3'b100);

  logic d_uses_rs1, d_uses_rs2;
  always_comb begin
    d_uses_rs1 = 1'b0; d_uses_rs2 = 1'b0;
    unique case (d_opcode)
      OpcodeBranch, OpcodeStore, OpcodeRegReg: begin
        d_uses_rs1 = 1'b1; d_uses_rs2 = 1'b1;
      end
      OpcodeLoad, OpcodeJalr, OpcodeRegImm: begin
        d_uses_rs1 = 1'b1;
      end
      default: ;
    endcase
  end

  wire load_use_hazard = x_state.is_load && x_state.regwrite && (x_state.rd != 5'd0) &&
    ( (d_uses_rs1 && (d_rs1 == x_state.rd)) ||
      (d_uses_rs2 && (d_rs2 == x_state.rd)) );

  div_track_t div_pipe[7];
  
  logic d_depends_on_div;
  always_comb begin
    d_depends_on_div = 1'b0;
    if (x_state.is_div_insn && (x_state.rd != 5'd0)) begin
      if ((d_uses_rs1 && d_rs1 == x_state.rd) || (d_uses_rs2 && d_rs2 == x_state.rd)) d_depends_on_div = 1'b1;
    end
    for (int i=0; i<6; i++) begin // ONLY CHECK UP TO div_pipe[5]! div_pipe[6] result goes to M, so X can bypass it!
      if (div_pipe[i].valid && div_pipe[i].rd != 5'd0) begin
        if ((d_uses_rs1 && d_rs1 == div_pipe[i].rd) || (d_uses_rs2 && d_rs2 == div_pipe[i].rd)) d_depends_on_div = 1'b1;
      end
    end
  end

  logic div_in_early;
  always_comb begin
    div_in_early = x_state.is_div_insn;
    for (int i=0; i<6; i++) if (div_pipe[i].valid) div_in_early = 1'b1; // up to div_pipe[5]
  end

  // Ensure fully in-order completion: ANY instruction following a division must stall until div leaves div_pipe[5].
  // Dependent instructions don't need additional stalling because they will be in X when div is in M, 
  // and X bypasses perfectly from M!
  wire d_stall_div = d_depends_on_div || (!d_is_div && div_in_early);
  assign d_stall = load_use_hazard || d_stall_div;

  /*****************/
  /* EXECUTE STAGE */
  /*****************/
  stage_execute_t x_state, x_state_next;

  // WD bypass only (since X, M bypasses will happen in X stage)
  logic [`REG_SIZE] d_rs1_val, d_rs2_val;
  always_comb begin
    d_rs1_val = rf_rs1_data;
    d_rs2_val = rf_rs2_data;

    // WD bypass: if W is writing to rs1/rs2, grab it right now.
    if (w_state.regwrite && (w_state.rd != 5'd0) && (w_state.rd == d_rs1)) begin
      d_rs1_val = w_state.result;
    end
    if (w_state.regwrite && (w_state.rd != 5'd0) && (w_state.rd == d_rs2)) begin
      d_rs2_val = w_state.result;
    end
  end

  // D stage next-state assignment
  always_comb begin
    x_state_next = '0;
    x_state_next.pc           = decode_state.pc;
    x_state_next.insn         = decode_state.insn;
    x_state_next.cycle_status = decode_state.cycle_status;
    x_state_next.rs1_val      = d_rs1_val;
    x_state_next.rs2_val      = d_rs2_val;
    x_state_next.imm          = d_imm;
    x_state_next.rs1          = d_rs1;
    x_state_next.rs2          = d_rs2;
    x_state_next.rd           = d_rd;
    x_state_next.is_load      = d_is_load;
    x_state_next.is_store     = d_is_store;
    x_state_next.is_div_insn  = d_is_div;
    x_state_next.funct3       = d_funct3;
    x_state_next.regwrite     = 1'b0;
    x_state_next.is_branch    = 1'b0;
    x_state_next.branch_taken = 1'b0;
    x_state_next.branch_target= 32'b0;
    x_state_next.alu_result   = 32'b0;

    unique case (d_opcode)
      7'b00_000_11: x_state_next.regwrite = (d_rd != 5'd0); // Load
      7'b01_101_11: x_state_next.regwrite = (d_rd != 5'd0); // Lui
      7'b00_101_11: x_state_next.regwrite = (d_rd != 5'd0); // Auipc
      7'b11_011_11: x_state_next.regwrite = (d_rd != 5'd0); // Jal
      7'b11_001_11: x_state_next.regwrite = (d_rd != 5'd0); // Jalr
      7'b00_100_11: x_state_next.regwrite = (d_rd != 5'd0); // RegImm
      7'b01_100_11: x_state_next.regwrite = (d_rd != 5'd0); // RegReg
      7'b11_000_11: x_state_next.is_branch = 1'b1;         // Branch
      default:      x_state_next.regwrite = 1'b0;
    endcase
  end
  always_ff @(posedge clk) begin
    if (rst) begin
      x_state <= '{pc: 0, insn: 0, cycle_status: CYCLE_RESET, rs1_val: 0, rs2_val: 0, imm: 0, rs1: 0, rs2: 0, rd: 0, funct3: 0, regwrite: 0, is_branch: 0, branch_taken: 0, branch_target: 0, alu_result: 0, is_load: 0, is_store: 0, is_div_insn: 0};
    end else if (x_redirect_taken) begin
      x_state <= '{pc: 0, insn: 32'b0, cycle_status: CYCLE_TAKEN_BRANCH, rs1_val: 0, rs2_val: 0, imm: 0, rs1: 0, rs2: 0, rd: 0, funct3: 0, regwrite: 0, is_branch: 0, branch_taken: 0, branch_target: 0, alu_result: 0, is_load: 0, is_store: 0, is_div_insn: 0};
    end else if (d_stall) begin
      x_state <= '{pc: 0, insn: 32'b0, cycle_status: (d_stall_div ? CYCLE_DIV : CYCLE_LOAD2USE), rs1_val: 0, rs2_val: 0, imm: 0, rs1: 0, rs2: 0, rd: 0, funct3: 0, regwrite: 0, is_branch: 0, branch_taken: 0, branch_target: 0, alu_result: 0, is_load: 0, is_store: 0, is_div_insn: 0};
    end else begin
      x_state <= x_state_next;
    end
  end

  wire [255:0] x_disasm;
  Disasm #(.PREFIX("X")) disasm_2execute (
      .insn  (x_state.insn),
      .disasm(x_disasm)
  );


  logic [31:0] shifted_load_data;
  assign shifted_load_data = dmem.RDATA >> {m_state.result[1:0], 3'b000};
  
  logic [31:0] final_load_data;
  always_comb begin
    if (m_state.funct3 == 3'b000) final_load_data = {{24{shifted_load_data[7]}}, shifted_load_data[7:0]};
    else if (m_state.funct3 == 3'b001) final_load_data = {{16{shifted_load_data[15]}}, shifted_load_data[15:0]};
    else if (m_state.funct3 == 3'b100) final_load_data = {24'd0, shifted_load_data[7:0]};
    else if (m_state.funct3 == 3'b101) final_load_data = {16'd0, shifted_load_data[15:0]};
    else final_load_data = shifted_load_data;
  end

  logic [31:0] m_result_for_w;
  assign m_result_for_w = m_state.is_load ? final_load_data : m_state.result;

  // M/X and W/X bypass evaluated in X stage!
  logic [`REG_SIZE] x_src1, x_src2;
  always_comb begin
    x_src1 = x_state.rs1_val;
    x_src2 = x_state.rs2_val;

    // rs1 priority M -> W
    if (m_state.regwrite && (m_state.rd != 5'd0) && (m_state.rd == x_state.rs1)) begin
      x_src1 = m_result_for_w;
    end else if (w_state.regwrite && (w_state.rd != 5'd0) && (w_state.rd == x_state.rs1)) begin
      x_src1 = w_state.result;
    end

    // rs2 priority M -> W
    if (m_state.regwrite && (m_state.rd != 5'd0) && (m_state.rd == x_state.rs2)) begin
      x_src2 = m_result_for_w;
    end else if (w_state.regwrite && (w_state.rd != 5'd0) && (w_state.rd == x_state.rs2)) begin
      x_src2 = w_state.result;
    end
  end

  logic x_branch_taken_calc;
  logic [`REG_SIZE] x_branch_target_calc;
  logic [`REG_SIZE] x_alu_result_calc;
  
  logic [63:0] mul_result;
  logic signed [63:0] s_alu_a;
  logic signed [63:0] s_alu_b;

  always_comb begin
    mul_result = '0;
    s_alu_a = '0;
    s_alu_b = '0;
    x_branch_taken_calc  = 1'b0;
    x_branch_target_calc = x_state.pc + x_state.imm;
    x_alu_result_calc    = '0;

    unique case (x_state.insn[6:0])
      7'b00_000_11, 7'b01_000_11: begin // Load, Store
        x_alu_result_calc = x_src1 + x_state.imm;
      end

      7'b01_101_11: begin // Lui
        x_alu_result_calc = x_state.imm;
      end

      7'b00_101_11: begin // Auipc
        x_alu_result_calc = x_state.pc + x_state.imm;
      end

      7'b11_011_11: begin // Jal
        x_branch_taken_calc = 1'b1;
        x_alu_result_calc   = x_state.pc + 4;
      end

      7'b11_001_11: begin // Jalr
        x_branch_taken_calc  = 1'b1;
        x_branch_target_calc = (x_src1 + x_state.imm) & ~32'd1;
        x_alu_result_calc    = x_state.pc + 4;
      end

      7'b00_100_11: begin // RegImm
        unique case (x_state.insn[14:12])
          3'b000: x_alu_result_calc = x_src1 + x_state.imm;
          3'b001: x_alu_result_calc = x_src1 << x_state.insn[24:20];
          3'b010: x_alu_result_calc = {{31{1'b0}}, ($signed(x_src1) < $signed(x_state.imm))};
          3'b011: x_alu_result_calc = {{31{1'b0}}, (x_src1 < x_state.imm)};
          3'b100: x_alu_result_calc = x_src1 ^ x_state.imm;
          3'b101: begin
            if (x_state.insn[30]) x_alu_result_calc = $signed(x_src1) >>> x_state.insn[24:20];
            else                       x_alu_result_calc = x_src1 >> x_state.insn[24:20];
          end
          3'b110: x_alu_result_calc = x_src1 | x_state.imm;
          3'b111: x_alu_result_calc = x_src1 & x_state.imm;
          default: x_alu_result_calc = '0;
        endcase
      end

      7'b01_100_11: begin // RegReg
        if (x_state.insn[31:25] == 7'd1) begin // M-extension
          if (x_state.insn[14:12] == 3'b001) begin
            s_alu_a = {{32{x_src1[31]}}, x_src1};
            s_alu_b = {{32{x_src2[31]}}, x_src2};
            mul_result = s_alu_a * s_alu_b;
            x_alu_result_calc = mul_result[63:32];
          end else if (x_state.insn[14:12] == 3'b010) begin
            s_alu_a = {{32{x_src1[31]}}, x_src1};
            s_alu_b = {32'd0, x_src2};
            mul_result = s_alu_a * s_alu_b;
            x_alu_result_calc = mul_result[63:32];
          end else if (x_state.insn[14:12] == 3'b011) begin
            s_alu_a = {32'd0, x_src1};
            s_alu_b = {32'd0, x_src2};
            mul_result = s_alu_a * s_alu_b;
            x_alu_result_calc = mul_result[63:32];
          end else if (x_state.insn[14:12] == 3'b000) begin
            s_alu_a = {32'd0, x_src1};
            s_alu_b = {32'd0, x_src2};
            mul_result = s_alu_a * s_alu_b;
            x_alu_result_calc = mul_result[31:0];
          end else begin
            x_alu_result_calc = '0;
          end
        end else begin
          unique case (x_state.insn[14:12])
            3'b000: begin
              if (x_state.insn[30]) x_alu_result_calc = x_src1 - x_src2;
              else                       x_alu_result_calc = x_src1 + x_src2;
            end
            3'b001: x_alu_result_calc = x_src1 << x_src2[4:0];
            3'b010: x_alu_result_calc = {{31{1'b0}}, ($signed(x_src1) < $signed(x_src2))};
            3'b011: x_alu_result_calc = {{31{1'b0}}, (x_src1 < x_src2)};
            3'b100: x_alu_result_calc = x_src1 ^ x_src2;
            3'b101: begin
              if (x_state.insn[30]) x_alu_result_calc = $signed(x_src1) >>> x_src2[4:0];
              else                       x_alu_result_calc = x_src1 >> x_src2[4:0];
            end
            3'b110: x_alu_result_calc = x_src1 | x_src2;
            3'b111: x_alu_result_calc = x_src1 & x_src2;
            default: x_alu_result_calc = '0;
          endcase
        end
      end

      7'b11_000_11: begin // Branch
        unique case (x_state.insn[14:12])
          3'b000: x_branch_taken_calc = (x_src1 == x_src2);
          3'b001: x_branch_taken_calc = (x_src1 != x_src2);
          3'b100: x_branch_taken_calc = ($signed(x_src1) < $signed(x_src2));
          3'b101: x_branch_taken_calc = ($signed(x_src1) >= $signed(x_src2));
          3'b110: x_branch_taken_calc = (x_src1 < x_src2);
          3'b111: x_branch_taken_calc = (x_src1 >= x_src2);
          default: x_branch_taken_calc = 1'b0;
        endcase
      end
      default: x_alu_result_calc = '0;
    endcase
  end


  // AXIL Data Memory outputs driven from X stage combinational signals
  assign dmem.ARVALID = x_state.is_load && (x_state.cycle_status == CYCLE_NO_STALL) && !rst && !halt;
  assign dmem.ARADDR  = {x_alu_result_calc[31:2], 2'b00};
  assign dmem.ARPROT  = 3'b0;
  assign dmem.RREADY  = 1'b1;

  logic [3:0] x_store_we;
  always_comb begin
    x_store_we = 4'd0;
    if (x_state.is_store && (x_state.cycle_status == CYCLE_NO_STALL) && !rst && !halt) begin
      if (x_state.funct3 == 3'b000) x_store_we = 4'b0001 << x_alu_result_calc[1:0];      // sb
      else if (x_state.funct3 == 3'b001) x_store_we = 4'b0011 << x_alu_result_calc[1:0]; // sh
      else if (x_state.funct3 == 3'b010) x_store_we = 4'b1111;                           // sw
    end
  end

  assign dmem.AWVALID = x_state.is_store && (x_state.cycle_status == CYCLE_NO_STALL) && !rst && !halt;
  assign dmem.AWADDR  = {x_alu_result_calc[31:2], 2'b00};
  assign dmem.AWPROT  = 3'b0;

  assign dmem.WVALID  = x_state.is_store && (x_state.cycle_status == CYCLE_NO_STALL) && !rst && !halt;
  assign dmem.WDATA   = x_src2 << {x_alu_result_calc[1:0], 3'b000};
  assign dmem.WSTRB   = x_store_we;
  assign dmem.BREADY  = 1'b1;

  /****************/
  /* MEMORY STAGE */
  /****************/
  stage_memory_t m_state;

  logic x_is_signed_div, x_is_rem, x_dividend_sign, x_divisor_sign, x_quotient_sign, x_remainder_sign;
  always_comb begin
    x_is_signed_div = x_state.is_div_insn && (x_state.funct3 == 3'b100 || x_state.funct3 == 3'b110);
    x_is_rem = x_state.is_div_insn && (x_state.funct3 == 3'b110 || x_state.funct3 == 3'b111);
    x_dividend_sign = x_is_signed_div & x_src1[31];
    x_divisor_sign  = x_is_signed_div & x_src2[31];
    x_quotient_sign = (x_dividend_sign ^ x_divisor_sign) && (x_src2 != 0);
    x_remainder_sign = x_dividend_sign;
  end

  logic [31:0] div_quotient_raw;
  logic [31:0] div_remainder_raw;
  logic [31:0] x_div_dividend, x_div_divisor;
  assign x_div_dividend = x_dividend_sign ? (~x_src1 + 1) : x_src1;
  assign x_div_divisor  = x_divisor_sign  ? (~x_src2 + 1) : x_src2;

  DividerUnsignedPipelined divider (
      .clk(clk),
      .rst(rst),
      .stall(1'b0),
      .i_dividend(x_div_dividend),
      .i_divisor(x_div_divisor),
      .o_remainder(div_remainder_raw),
      .o_quotient(div_quotient_raw)
  );

  always_ff @(posedge clk) begin
    if (rst) begin
      for (int i=0; i<7; i++) div_pipe[i] <= '0;
    end else begin
      if (x_state.is_div_insn && !x_state.branch_taken) begin
        div_pipe[0] <= '{valid: 1'b1, rd: x_state.rd, quotient_sign: x_quotient_sign, remainder_sign: x_remainder_sign, is_rem: x_is_rem, pc: x_state.pc, insn: x_state.insn};
      end else begin
        div_pipe[0] <= '0;
      end
      for (int i=1; i<7; i++) begin
        div_pipe[i] <= div_pipe[i-1];
      end
    end
  end

  logic [31:0] true_quotient;
  logic [31:0] true_remainder;
  logic [31:0] div_result_chosen;
  assign true_quotient = div_pipe[6].quotient_sign ? (~div_quotient_raw + 1) : div_quotient_raw;
  assign true_remainder = div_pipe[6].remainder_sign ? (~div_remainder_raw + 1) : div_remainder_raw;
  assign div_result_chosen = div_pipe[6].is_rem ? true_remainder : true_quotient;

  stage_memory_t m_state_next;
  always_comb begin
    if (div_pipe[6].valid) begin
      m_state_next = '{
        pc: div_pipe[6].pc,
        insn: div_pipe[6].insn,
        cycle_status: CYCLE_NO_STALL,
        rs2: 0, rs2_val: 0, funct3: 0, is_load: 0, is_store: 0,
        rd: div_pipe[6].rd,
        regwrite: 1'b1,
        result: div_result_chosen,
        branch_taken: 1'b0,
        branch_target: '0
      };
    end else if (x_state.is_div_insn) begin
      m_state_next = '{pc: 0, insn: 32'b0, cycle_status: CYCLE_DIV, rs2: 0, rs2_val: 0, funct3: 0, is_load: 0, is_store: 0, rd: 0, regwrite: 0, result: 0, branch_taken: 0, branch_target: 0};
    end else begin
      m_state_next = '{
        pc: x_state.pc,
        insn: x_state.insn,
        cycle_status: x_state.cycle_status,
        rs2: x_state.rs2,
        rs2_val: x_src2, // Bypassed rs2 goes into memory
        funct3: x_state.funct3,
        is_load: x_state.is_load,
        is_store: x_state.is_store,
        rd: x_state.rd,
        regwrite: x_state.regwrite,
        result: x_alu_result_calc, // ALU result calculated in X
        branch_taken: x_branch_taken_calc,
        branch_target: x_branch_target_calc
      };
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      m_state <= '{pc: 0, insn: 0, cycle_status: CYCLE_RESET, rs2: 0, rs2_val: 0, funct3: 0, is_load: 0, is_store: 0, rd: 0, regwrite: 0, result: 0, branch_taken: 0, branch_target: 0};
    end else begin
      m_state <= m_state_next;
    end
  end

  assign x_redirect_taken  = x_branch_taken_calc;
  assign x_redirect_target = x_branch_target_calc;

  wire [255:0] m_disasm;
  Disasm #(.PREFIX("M")) disasm_3memory (
      .insn  (m_state.insn),
      .disasm(m_disasm)
  );

  /*******************/
  /* WRITEBACK STAGE */
  /*******************/
  stage_writeback_t w_state;




  always_ff @(posedge clk) begin
    if (rst) begin
      w_state <= '{pc: 0, insn: 0, cycle_status: CYCLE_RESET, rd: 0, regwrite: 0, result: 0, is_load: 0};
    end else begin
      w_state <= '{
        pc: m_state.pc,
        insn: m_state.insn,
        cycle_status: m_state.cycle_status,
        rd: m_state.rd,
        regwrite: m_state.regwrite,
        result: m_result_for_w,
        is_load: m_state.is_load
      };
    end
  end

  wire [255:0] w_disasm;
  Disasm #(.PREFIX("W")) disasm_4writeback (
      .insn  (w_state.insn),
      .disasm(w_disasm)
  );

  assign wb_we   = w_state.regwrite;
  assign wb_rd   = w_state.rd;
  assign wb_data = w_state.result;

  assign halt = (w_state.insn == 32'h00000073);

  /********************/
  /* TRACE OUTPUTS    */
  /********************/
  assign trace_completed_pc           = w_state.pc;
  assign trace_completed_insn         = w_state.insn;
  assign trace_completed_cycle_status = w_state.cycle_status;



endmodule // DatapathPipelinedCache

/* This design has just one clock for both processor and memory. */
module Processor (
    input  wire  clk,
    input  wire  rst,
    output logic halt,
    output wire [`REG_SIZE] trace_completed_pc,
    output wire [`INSN_SIZE] trace_completed_insn,
    output cycle_status_e trace_completed_cycle_status
);

  // This wire is set by cocotb to the name of the currently-running test, to make it easier
  // to see what is going on in the waveforms.
  wire [(8*32)-1:0] test_case;

  axil_if axil_mem_ro ();
  axil_if axil_mem_rw ();

  EasyAxilMemory #(
      .OPT_SKIDBUFFER(1),
      .OPT_LOWPOWER(0),
      .NUM_WORDS(8192)
  ) memory (
      .ACLK(clk),
      .ARESETn(~rst),
      .port_ro(axil_mem_ro.subord),
      .port_rw(axil_mem_rw.subord)
  );

  DatapathPipelinedAxil datapath (
      .clk(clk),
      .rst(rst),
      .imem(axil_mem_ro.manager),
      .dmem(axil_mem_rw.manager),
      .halt(halt),
      .trace_completed_pc(trace_completed_pc),
      .trace_completed_insn(trace_completed_insn),
      .trace_completed_cycle_status(trace_completed_cycle_status)
  );

endmodule
