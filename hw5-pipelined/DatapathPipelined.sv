`timescale 1ns / 1ns

/* verilator lint_off UNUSEDPARAM */

// registers are 32 bits in RV32
`define REG_SIZE 31:0

// insns are 32 bits in RV32IM
`define INSN_SIZE 31:0

// RV opcodes are 7 bits
`define OPCODE_SIZE 6:0

`ifndef DIVIDER_STAGES
`define DIVIDER_STAGES 8
`endif

`ifndef SYNTHESIS
`include "../hw3-singlecycle/RvDisassembler.sv"
`endif
`include "../hw2b-cla/CarryLookaheadAdder.sv"
`include "../hw4-multicycle/DividerUnsignedPipelined.sv"
`include "../hw3-singlecycle/cycle_status.sv"

module Disasm #(
    byte PREFIX = "D"
) (
    input wire [31:0] insn,
    output wire [(8*32)-1:0] disasm
);
`ifndef SYNTHESIS
  string disasm_string;
  always_comb begin
    disasm_string = rv_disasm(insn);
  end
  genvar i;
  for (i = 3; i < 32; i = i + 1) begin : gen_disasm
    assign disasm[((i+1-3)*8)-1-:8] = disasm_string[31-i];
  end
  assign disasm[255-:8] = PREFIX;
  assign disasm[247-:8] = ":";
  assign disasm[239-:8] = " ";
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

  logic regwrite;
  logic is_branch;
  logic branch_taken;
  logic [`REG_SIZE] branch_target;

  logic [`REG_SIZE] alu_result;
} stage_execute_t;

typedef struct packed {
  logic [`REG_SIZE] pc;
  logic [`INSN_SIZE] insn;
  cycle_status_e cycle_status;

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
} stage_writeback_t;

module DatapathPipelined (
    input wire clk,
    input wire rst,
    output logic [`REG_SIZE] pc_to_imem,
    input wire [`INSN_SIZE] insn_from_imem,
    output logic [`REG_SIZE] addr_to_dmem,
    input wire [`REG_SIZE] load_data_from_dmem,
    output logic [`REG_SIZE] store_data_to_dmem,
    output logic [3:0] store_we_to_dmem,

    output logic halt,

    output logic [`REG_SIZE] trace_completed_pc,
    output logic [`INSN_SIZE] trace_completed_insn,
    output cycle_status_e trace_completed_cycle_status
);

  localparam bit [`OPCODE_SIZE] OpcodeLoad     = 7'b00_000_11;
  localparam bit [`OPCODE_SIZE] OpcodeStore    = 7'b01_000_11;
  localparam bit [`OPCODE_SIZE] OpcodeBranch   = 7'b11_000_11;
  localparam bit [`OPCODE_SIZE] OpcodeJalr     = 7'b11_001_11;
  localparam bit [`OPCODE_SIZE] OpcodeMiscMem  = 7'b00_011_11;
  localparam bit [`OPCODE_SIZE] OpcodeJal      = 7'b11_011_11;
  localparam bit [`OPCODE_SIZE] OpcodeRegImm   = 7'b00_100_11;
  localparam bit [`OPCODE_SIZE] OpcodeRegReg   = 7'b01_100_11;
  localparam bit [`OPCODE_SIZE] OpcodeEnviron  = 7'b11_100_11;
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
  logic [`REG_SIZE] f_pc_current;
  wire  [`INSN_SIZE] f_insn;
  cycle_status_e f_cycle_status;

  wire m_redirect_taken;
  wire [`REG_SIZE] m_redirect_target;

  always_ff @(posedge clk) begin
    if (rst) begin
      f_pc_current    <= 32'd0;
      f_cycle_status  <= CYCLE_NO_STALL;
    end else begin
      if (x_redirect_taken) begin
        f_pc_current   <= x_redirect_target;
        f_cycle_status <= CYCLE_NO_STALL;
      end else begin
        f_pc_current   <= f_pc_current + 4;
        f_cycle_status <= CYCLE_NO_STALL;
      end
    end
  end

  assign pc_to_imem = f_pc_current;
  assign f_insn = insn_from_imem;

  wire [255:0] f_disasm;
  Disasm #(.PREFIX("F")) disasm_0fetch (
      .insn  (f_insn),
      .disasm(f_disasm)
  );

  /****************/
  /* DECODE STAGE */
  /****************/
  stage_decode_t decode_state;

  // flush F/D when branch is taken in X and reaches M redirect point
  // inserted bubble carries branch status
  always_ff @(posedge clk) begin
    if (rst) begin
      decode_state <= '{
        pc: 0,
        insn: 0,
        cycle_status: CYCLE_RESET
      };
    end else if (x_redirect_taken) begin
      decode_state <= '{
        pc: 0,
        insn: 32'b0,
        cycle_status: CYCLE_TAKEN_BRANCH
      };
    end else begin
      decode_state <= '{
        pc: f_pc_current,
        insn: f_insn,
        cycle_status: f_cycle_status
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

  function automatic logic [`REG_SIZE] imm_b(input logic [`INSN_SIZE] insn);
    imm_b = {{19{insn[31]}}, insn[31], insn[7], insn[30:25], insn[11:8], 1'b0};
  endfunction

  function automatic logic [`REG_SIZE] imm_u(input logic [`INSN_SIZE] insn);
    imm_u = {insn[31:12], 12'b0};
  endfunction

  logic [`REG_SIZE] d_imm;
  always_comb begin
    unique case (d_opcode)
      OpcodeRegImm: d_imm = imm_i(decode_state.insn);
      OpcodeBranch: d_imm = imm_b(decode_state.insn);
      OpcodeLui:    d_imm = imm_u(decode_state.insn);
      default:      d_imm = '0;
    endcase
  end

  /*****************/
  /* EXECUTE STAGE */
  /*****************/
  stage_execute_t x_state, x_state_next;

  // M/X and W/X bypass
  logic [`REG_SIZE] x_src1, x_src2;
  always_comb begin
    x_src1 = x_state.rs1_val;
    x_src2 = x_state.rs2_val;

    // MX bypass has priority over WX
    if (m_state.regwrite && (m_state.rd != 5'd0) && (m_state.rd == x_state.rs1)) begin
      x_src1 = m_state.result;
    end else if (w_state.regwrite && (w_state.rd != 5'd0) && (w_state.rd == x_state.rs1)) begin
      x_src1 = w_state.result;
    end

    if (m_state.regwrite && (m_state.rd != 5'd0) && (m_state.rd == x_state.rs2)) begin
      x_src2 = m_state.result;
    end else if (w_state.regwrite && (w_state.rd != 5'd0) && (w_state.rd == x_state.rs2)) begin
      x_src2 = w_state.result;
    end
  end

  logic x_branch_taken_calc;
  logic [`REG_SIZE] x_branch_target_calc;
  logic [`REG_SIZE] x_alu_result_calc;

  always_comb begin
    x_branch_taken_calc  = 1'b0;
    x_branch_target_calc = x_state.pc + x_state.imm;
    x_alu_result_calc    = '0;

    unique case (x_state.insn[6:0])

      OpcodeLui: begin
        x_alu_result_calc = x_state.imm;
      end

      OpcodeRegImm: begin
        unique case (x_state.insn[14:12])
          3'b000: x_alu_result_calc = x_src1 + x_state.imm;                      // ADDI
          3'b010: x_alu_result_calc = {{31{1'b0}}, ($signed(x_src1) < $signed(x_state.imm))};  // SLTI
          3'b011: x_alu_result_calc = {{31{1'b0}}, (x_src1 < x_state.imm)};                     // SLTIU
          3'b100: x_alu_result_calc = x_src1 ^ x_state.imm;                      // XORI
          3'b110: x_alu_result_calc = x_src1 | x_state.imm;                      // ORI
          3'b111: x_alu_result_calc = x_src1 & x_state.imm;                      // ANDI
          3'b001: x_alu_result_calc = x_src1 << x_state.insn[24:20];             // SLLI
          3'b101: begin
            if (x_state.insn[30]) begin
              x_alu_result_calc = $signed(x_src1) >>> x_state.insn[24:20];       // SRAI
            end else begin
              x_alu_result_calc = x_src1 >> x_state.insn[24:20];                 // SRLI
            end
          end
          default: x_alu_result_calc = '0;
        endcase
      end

      OpcodeRegReg: begin
        unique case (x_state.insn[14:12])
          3'b000: begin
            if (x_state.insn[30]) x_alu_result_calc = x_src1 - x_src2;           // SUB
            else                  x_alu_result_calc = x_src1 + x_src2;           // ADD
          end
          3'b001: x_alu_result_calc = x_src1 << x_src2[4:0];                     // SLL
          3'b010: x_alu_result_calc = {{31{1'b0}}, ($signed(x_src1) < $signed(x_src2))}; // SLT
          3'b011: x_alu_result_calc = {{31{1'b0}}, (x_src1 < x_src2)};                     // SLTU
          3'b100: x_alu_result_calc = x_src1 ^ x_src2;                           // XOR
          3'b101: begin
            if (x_state.insn[30]) x_alu_result_calc = $signed(x_src1) >>> x_src2[4:0]; // SRA
            else                  x_alu_result_calc = x_src1 >> x_src2[4:0];            // SRL
          end
          3'b110: x_alu_result_calc = x_src1 | x_src2;                           // OR
          3'b111: x_alu_result_calc = x_src1 & x_src2;                           // AND
          default: x_alu_result_calc = '0;
        endcase
      end

      OpcodeBranch: begin
        unique case (x_state.insn[14:12])
          3'b000: x_branch_taken_calc = (x_src1 == x_src2);                      // BEQ
          3'b001: x_branch_taken_calc = (x_src1 != x_src2);                      // BNE
          3'b100: x_branch_taken_calc = ($signed(x_src1) <  $signed(x_src2));    // BLT
          3'b101: x_branch_taken_calc = ($signed(x_src1) >= $signed(x_src2));    // BGE
          3'b110: x_branch_taken_calc = (x_src1 < x_src2);                       // BLTU
          3'b111: x_branch_taken_calc = (x_src1 >= x_src2);                      // BGEU
          default: x_branch_taken_calc = 1'b0;
        endcase
        x_alu_result_calc = '0;
      end

      default: begin
        x_alu_result_calc = '0;
      end
    endcase
  end

  always_comb begin
    x_state_next = '0;
    x_state_next.pc           = decode_state.pc;
    x_state_next.insn         = decode_state.insn;
    x_state_next.cycle_status = decode_state.cycle_status;
    x_state_next.rs1_val      = rf_rs1_data;
    x_state_next.rs2_val      = rf_rs2_data;
    x_state_next.imm          = d_imm;
    x_state_next.rs1          = d_rs1;
    x_state_next.rs2          = d_rs2;
    x_state_next.rd           = d_rd;
    x_state_next.regwrite     = 1'b0;
    x_state_next.is_branch    = 1'b0;
    x_state_next.branch_taken = 1'b0;
    x_state_next.branch_target= '0;
    x_state_next.alu_result   = '0;

    unique case (d_opcode)
      OpcodeLui: begin
        x_state_next.regwrite = (d_rd != 5'd0);
      end
      OpcodeRegImm: begin
        x_state_next.regwrite = (d_rd != 5'd0);
      end
      OpcodeRegReg: begin
        x_state_next.regwrite = (d_rd != 5'd0);
      end
      OpcodeBranch: begin
        x_state_next.is_branch = 1'b1;
      end
      default: begin
        x_state_next.regwrite = 1'b0;
      end
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      x_state <= '{
        pc: 0,
        insn: 0,
        cycle_status: CYCLE_RESET,
        rs1_val: 0,
        rs2_val: 0,
        imm: 0,
        rs1: 0,
        rs2: 0,
        rd: 0,
        regwrite: 0,
        is_branch: 0,
        branch_taken: 0,
        branch_target: 0,
        alu_result: 0
      };
    end else if (x_redirect_taken) begin
      // flush younger insn entering X
      x_state <= '{
        pc: 0,
        insn: 32'b0,
        cycle_status: CYCLE_TAKEN_BRANCH,
        rs1_val: 0,
        rs2_val: 0,
        imm: 0,
        rs1: 0,
        rs2: 0,
        rd: 0,
        regwrite: 0,
        is_branch: 0,
        branch_taken: 0,
        branch_target: 0,
        alu_result: 0
      };
    end else begin
      x_state <= x_state_next;
      x_state.branch_taken  <= x_branch_taken_calc;
      x_state.branch_target <= x_branch_target_calc;
      x_state.alu_result    <= x_alu_result_calc;
    end
  end

  wire [255:0] x_disasm;
  Disasm #(.PREFIX("X")) disasm_2execute (
      .insn  (x_state.insn),
      .disasm(x_disasm)
  );

  /****************/
  /* MEMORY STAGE */
  /****************/
  stage_memory_t m_state;

  always_ff @(posedge clk) begin
    if (rst) begin
      m_state <= '{
        pc: 0,
        insn: 0,
        cycle_status: CYCLE_RESET,
        rd: 0,
        regwrite: 0,
        result: 0,
        branch_taken: 0,
        branch_target: 0
      };
    end else begin
      m_state <= '{
        pc: x_state.pc,
        insn: x_state.insn,
        cycle_status: x_state.cycle_status,
        rd: x_state.rd,
        regwrite: x_state.regwrite,
        result: x_alu_result_calc,
        branch_taken: x_branch_taken_calc,
        branch_target: x_branch_target_calc
      };
    end
  end

  wire x_redirect_taken;
  wire [`REG_SIZE] x_redirect_target;

  assign x_redirect_taken  = x_state.branch_taken;
  assign x_redirect_target = x_state.branch_target;

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
      w_state <= '{
        pc: 0,
        insn: 0,
        cycle_status: CYCLE_RESET,
        rd: 0,
        regwrite: 0,
        result: 0
      };
    end else begin
      w_state <= '{
        pc: m_state.pc,
        insn: m_state.insn,
        cycle_status: m_state.cycle_status,
        rd: m_state.rd,
        regwrite: m_state.regwrite,
        result: m_state.result
      };
    end
  end

  wire [255:0] w_disasm;
  Disasm #(.PREFIX("W")) disasm_4writeback (
      .insn  (w_state.insn),
      .disasm(w_disasm)
  );

  // writeback signals into RF
  assign wb_we   = w_state.regwrite;
  assign wb_rd   = w_state.rd;
  assign wb_data = w_state.result;

  /********************/
  /* UNUSED FOR M1    */
  /********************/
  assign addr_to_dmem       = 32'b0;
  assign store_data_to_dmem = 32'b0;
  assign store_we_to_dmem   = 4'b0000;
  assign halt               = 1'b0;

  /********************/
  /* TRACE OUTPUTS    */
  /********************/
  assign trace_completed_pc           = w_state.pc;
  assign trace_completed_insn         = w_state.insn;
  assign trace_completed_cycle_status = w_state.cycle_status;

endmodule

module MemorySingleCycle #(
    parameter int NUM_WORDS = 512
) (
    input wire rst,
    input wire clk,
    input wire [`REG_SIZE] pc_to_imem,
    output logic [`REG_SIZE] insn_from_imem,
    input wire [`REG_SIZE] addr_to_dmem,
    output logic [`REG_SIZE] load_data_from_dmem,
    input wire [`REG_SIZE] store_data_to_dmem,
    input wire [3:0] store_we_to_dmem
);

  logic [`REG_SIZE] mem_array[NUM_WORDS];

`ifdef SYNTHESIS
  initial begin
    $readmemh("mem_initial_contents.hex", mem_array);
  end
`endif

  always_comb begin
    assert (pc_to_imem[1:0] == 2'b00);
    assert (addr_to_dmem[1:0] == 2'b00);
  end

  localparam int AddrMsb = $clog2(NUM_WORDS) + 1;
  localparam int AddrLsb = 2;

  always @(negedge clk) begin
    if (rst) begin
    end else begin
      insn_from_imem <= mem_array[{pc_to_imem[AddrMsb:AddrLsb]}];
    end
  end

  always @(negedge clk) begin
    if (rst) begin
    end else begin
      if (store_we_to_dmem[0]) begin
        mem_array[addr_to_dmem[AddrMsb:AddrLsb]][7:0] <= store_data_to_dmem[7:0];
      end
      if (store_we_to_dmem[1]) begin
        mem_array[addr_to_dmem[AddrMsb:AddrLsb]][15:8] <= store_data_to_dmem[15:8];
      end
      if (store_we_to_dmem[2]) begin
        mem_array[addr_to_dmem[AddrMsb:AddrLsb]][23:16] <= store_data_to_dmem[23:16];
      end
      if (store_we_to_dmem[3]) begin
        mem_array[addr_to_dmem[AddrMsb:AddrLsb]][31:24] <= store_data_to_dmem[31:24];
      end
      load_data_from_dmem <= mem_array[{addr_to_dmem[AddrMsb:AddrLsb]}];
    end
  end
endmodule

module Processor (
    input  wire  clk,
    input  wire  rst,
    output logic halt,
    output wire [`REG_SIZE] trace_completed_pc,
    output wire [`INSN_SIZE] trace_completed_insn,
    output cycle_status_e trace_completed_cycle_status
);

  wire [`INSN_SIZE] insn_from_imem;
  wire [`REG_SIZE] pc_to_imem, mem_data_addr, mem_data_loaded_value, mem_data_to_write;
  wire [3:0] mem_data_we;
  wire [(8*32)-1:0] test_case;

  MemorySingleCycle #(
      .NUM_WORDS(8192)
  ) memory (
      .rst                (rst),
      .clk                (clk),
      .pc_to_imem         (pc_to_imem),
      .insn_from_imem     (insn_from_imem),
      .addr_to_dmem       (mem_data_addr),
      .load_data_from_dmem(mem_data_loaded_value),
      .store_data_to_dmem (mem_data_to_write),
      .store_we_to_dmem   (mem_data_we)
  );

  DatapathPipelined datapath (
      .clk(clk),
      .rst(rst),
      .pc_to_imem(pc_to_imem),
      .insn_from_imem(insn_from_imem),
      .addr_to_dmem(mem_data_addr),
      .store_data_to_dmem(mem_data_to_write),
      .store_we_to_dmem(mem_data_we),
      .load_data_from_dmem(mem_data_loaded_value),
      .halt(halt),
      .trace_completed_pc(trace_completed_pc),
      .trace_completed_insn(trace_completed_insn),
      .trace_completed_cycle_status(trace_completed_cycle_status)
  );

endmodule

/* verilator lint_on UNUSEDPARAM */
