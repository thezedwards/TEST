-- Filename:          simple_processor.vhd
-- Version:           1.00.a
-- Description:       Simple ARM Thumb(R) processor
-- Date Created:      Wed, Nov 13, 2013 20:59:21
-- Last Modified:     Thu, Dec 26, 2013 17:40:49
-- VHDL Standard:     VHDL'93
-- Author:            Sean McClain <mcclains@ainfosec.com>
-- Copyright:         (c) 2013 Assured Information Security, All Rights Reserved

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library proc_common_v3_00_a;
use proc_common_v3_00_a.proc_common_pkg.all;
use proc_common_v3_00_a.ipif_pkg.all;
use proc_common_v3_00_a.soft_reset;

library simple_processor_v1_00_a;
use simple_processor_v1_00_a.alu;
use simple_processor_v1_00_a.decoder;
use simple_processor_v1_00_a.reg_file;
use simple_processor_v1_00_a.state_machine;
use simple_processor_v1_00_a.opcodes.all;
use simple_processor_v1_00_a.states.all;
use simple_processor_v1_00_a.reg_file_constants.all;

---
-- A single instruction ARM Thumb(R) processor with no flow control
--  or branching.
---
entity simple_processor
is
  generic
  (
    -- number of comm channels owned by EDK register file
    NUM_CHANNELS  : integer          := 32
  );
  port
  (
    -- communication with EDK register file
    data_to_mem   : out   std_logic_vector (
        DATA_WIDTH*NUM_CHANNELS-1 downto 0
        );
    data_from_mem : in    std_logic_vector (
        DATA_WIDTH*NUM_CHANNELS-1 downto 0
        );
    addresses     : out   std_logic_vector (
        DATA_WIDTH*NUM_CHANNELS-1 downto 0
        );
    enables       : out   std_logic_vector(NUM_CHANNELS-1 downto 0);
    data_mode     : out   std_logic;
    rd_ack        : in    std_logic;
    wr_ack        : in    std_logic;

    -- clock and reset
    Clk           : in    std_logic;
    Reset         : in    std_logic
  );

end entity simple_processor;

architecture IMP of simple_processor
is

  -- acknowledgements to drive the state machine
  signal reg_file_reset_ack  : std_logic;
  signal alu_reset_ack       : std_logic;
  signal send_inst_ack       : std_logic;
  signal decode_ack          : std_logic;
  signal load_ack            : std_logic;
  signal math_ack            : std_logic;
  signal store_ack           : std_logic;

  -- raw binary for the current instruction
  signal raw_instruction     : std_logic_vector(15 downto 0);

  -- decoded instruction
  signal opcode              : integer;

  -- argument register addresses m, n, source, and dest
  signal Rm                  : std_logic_vector(2 downto 0);
  signal Rn                  : std_logic_vector(2 downto 0);
  signal Rs                  : std_logic_vector(2 downto 0);
  signal Rd                  : std_logic_vector(2 downto 0);

  -- immediate values hard-coded in the raw instruction binary
  signal Imm_3               : std_logic_vector(2 downto 0);
  signal Imm_5               : std_logic_vector(4 downto 0);
  signal Imm_8               : std_logic_vector(7 downto 0);
  signal Imm_11              : std_logic_vector(10 downto 0);

  -- decoded condition
  signal condition           : std_logic_vector(15 downto 0);

  -- flag used by push/pop
  signal flag_lr_pc          : std_logic;

  -- flags used to access registers 8-15
  signal flags_h             : std_logic_vector(1 downto 0);

  -- flags set by the last ALU operation representing
  --  negative, zero, carry, overflow
  signal flag_n              : std_logic;
  signal flag_z              : std_logic;
  signal flag_c              : std_logic;
  signal flag_v              : std_logic;

  -- 2 arguments and return value for ALU
  signal alu_a               : std_logic_vector(31 downto 0);
  signal alu_b               : std_logic_vector(31 downto 0);
  signal alu_out             : std_logic_vector(31 downto 0);

  -- write enables for register file
  signal alu_wr_en           : std_logic_vector(WR_EN_SIZEOF-1 downto 0);

  -- retrieved register values from register file
  signal sp_plus_off         : std_logic_vector(DATA_WIDTH-1 downto 0);
  signal pc_plus_off         : std_logic_vector(DATA_WIDTH-1 downto 0);
  signal lr_plus_off         : std_logic_vector(DATA_WIDTH-1 downto 0);
  signal rn_plus_off         : std_logic_vector(DATA_WIDTH-1 downto 0);
  signal rm_plus_rn          : std_logic_vector(DATA_WIDTH-1 downto 0);
  signal rm_hh_reg           : std_logic_vector(DATA_WIDTH-1 downto 0);
  signal rm_hl_reg           : std_logic_vector(DATA_WIDTH-1 downto 0);
  signal rn_hh_reg           : std_logic_vector(DATA_WIDTH-1 downto 0);
  signal rn_hl_reg           : std_logic_vector(DATA_WIDTH-1 downto 0);
  signal rm_reg              : std_logic_vector(DATA_WIDTH-1 downto 0);
  signal rn_reg              : std_logic_vector(DATA_WIDTH-1 downto 0);
  signal rs_reg              : std_logic_vector(DATA_WIDTH-1 downto 0);
  signal rd_reg              : std_logic_vector(DATA_WIDTH-1 downto 0);
  signal sp_reg              : std_logic_vector(DATA_WIDTH-1 downto 0);
  signal pc_reg              : std_logic_vector(DATA_WIDTH-1 downto 0);
  signal lr_reg              : std_logic_vector(DATA_WIDTH-1 downto 0);
  signal sp                  : integer;
  signal pc                  : integer;
  signal lr                  : integer;

  -- current processing state
  signal state               : integer range STATE_MIN to STATE_MAX;

begin

  ---
  -- Triggers all processor events in order
  ---
  STATE_MACHINE_I : entity simple_processor_v1_00_a.state_machine
    port map
    (
      reg_file_reset_ack     => reg_file_reset_ack,
      alu_reset_ack          => alu_reset_ack,
      send_inst_ack          => send_inst_ack,
      decode_ack             => decode_ack,
      load_ack               => load_ack,
      math_ack               => math_ack,
      store_ack              => store_ack,
      state                  => state,
      Clk                    => Clk,
      Reset                  => Reset
    );

  ---
  -- Register file, containing both registers and data memory
  ---
  REG_FILE_I : entity simple_processor_v1_00_a.reg_file
    generic map
    (
      NUM_CHANNELS           => NUM_CHANNELS
    )
    port map
    (
      data_to_mem            => data_to_mem,
      data_from_mem          => data_from_mem,
      addresses              => addresses,
      enables                => enables,
      data_mode              => data_mode,
      mem_rd_ack             => rd_ack,
      mem_wr_ack             => wr_ack,
      Rm                     => Rm,
      Rn                     => Rn,
      Rs                     => Rs,
      Rd                     => Rd,
      Imm_3                  => Imm_3,
      Imm_5                  => Imm_5,
      Imm_8                  => Imm_8,
      Imm_11                 => Imm_11,
      flag_lr_pc             => flag_lr_pc,
      flags_h                => flags_h,
      alu_out                => alu_out,
      alu_wr_en              => alu_wr_en,
      flag_n                 => flag_n,
      flag_z                 => flag_z,
      flag_c                 => flag_c,
      flag_v                 => flag_v,
      reg_file_reset_ack     => reg_file_reset_ack,
      send_inst_ack          => send_inst_ack,
      load_ack               => load_ack,
      store_ack              => store_ack,
      sp_plus_off            => sp_plus_off,
      pc_plus_off            => pc_plus_off,
      lr_plus_off            => lr_plus_off,
      rn_plus_off            => rn_plus_off,
      rm_plus_rn             => rm_plus_rn,
      rm_hh_reg              => rm_hh_reg,
      rm_hl_reg              => rm_hl_reg,
      rn_hh_reg              => rn_hh_reg,
      rn_hl_reg              => rn_hl_reg,
      rm_reg                 => rm_reg,
      rn_reg                 => rn_reg,
      rs_reg                 => rs_reg,
      rd_reg                 => rd_reg,
      sp_reg                 => sp_reg,
      pc_reg                 => lr_reg,
      lr_reg                 => pc_reg,
      sp_val                 => sp,
      pc_val                 => pc,
      lr_val                 => lr,
      instruction            => raw_instruction,
      state                  => state
    );

  ---
  -- Selects 2 register file outputs to send into the ALU,
  --  and selects which write enables are on in the register file
  ---
  MUXER_I : entity simple_processor_v1_00_a.muxer
    port map
    (
      opcode                 => opcode,
      Imm_3                  => Imm_3,
      Imm_5                  => Imm_5,
      Imm_8                  => Imm_8,
      Imm_11                 => Imm_11,
      sp_plus_off            => sp_plus_off,
      pc_plus_off            => pc_plus_off,
      rn_plus_off            => rn_plus_off,
      rm_plus_rn             => rm_plus_rn,
      rm_hh_reg              => rm_hh_reg,
      rm_hl_reg              => rm_hl_reg,
      rn_hh_reg              => rn_hh_reg,
      rn_hl_reg              => rn_hl_reg,
      rm_reg                 => rm_reg,
      rn_reg                 => rn_reg,
      rs_reg                 => rs_reg,
      rd_reg                 => rd_reg,
      sp_reg                 => sp_reg,
      pc_reg                 => lr_reg,
      sp                     => sp,
      pc                     => pc,
      alu_a                  => alu_a,
      alu_b                  => alu_b,
      wr_en                  => alu_wr_en
    );

  ---
  -- ARM Thumb(R) decoder
  ---
  DECODER_I : entity simple_processor_v1_00_a.decoder
    port map
    (
      data                   => raw_instruction,
      condition              => condition,
      opcode                 => opcode,
      Rm                     => Rm,
      Rn                     => Rn,
      Rs                     => Rs,
      Rd                     => Rd,
      Imm_3                  => Imm_3,
      Imm_5                  => Imm_5,
      Imm_8                  => Imm_8,
      Imm_11                 => Imm_11,
      flag_lr_pc             => flag_lr_pc,
      flags_h                => flags_h,
      decode_ack             => decode_ack,
      state                  => state
    );

  ---
  -- Arithmetic Logical Unit
  ---
  ALU_I : entity simple_processor_v1_00_a.alu
    port map
    (
      a                      => alu_a,
      b                      => alu_b,
      opcode                 => opcode,
      result                 => alu_out,
      n                      => flag_n,
      z                      => flag_z,
      c                      => flag_c,
      v                      => flag_v,
      alu_reset_ack          => alu_reset_ack,
      math_ack               => math_ack,
      state                  => state
  );

end IMP;
