-- Filename:          state_machine.vhd
-- Version:           0.01
-- Description:       Controls event ordering
-- Date Created:      Tue, Nov 19, 2013 16:00:21
-- Last Modified:     Tue, Nov 26, 2013 14:09:49
-- VHDL Standard:     VHDL '93
-- Author:            Sean McClain <mcclains@ainfosec.com>
-- Copyright:         (c) 2013 Assured Information Security, All Rights Reserved

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library proc_common_v3_00_a;
use proc_common_v3_00_a.proc_common_pkg.all;

library simple_processor_wrapper_v1_00_a;
use simple_processor_wrapper_v1_00_a.opcodes.all;
use simple_processor_wrapper_v1_00_a.states.all;

---
-- Triggers all processor events in order
---
entity state_machine
is
  port
  (
    -- acknowledgements, sent when a signal has done its work
    reg_file_reset_ack : in    std_logic;
    alu_reset_ack      : in    std_logic;
    send_inst_ack      : in    std_logic;
    decode_ack         : in    std_logic;
    load_ack           : in    std_logic;
    math_ack           : in    std_logic;
    store_ack          : in    std_logic;
    soft_write_ack     : in    std_logic;
    soft_read_ack      : in    std_logic;

    -- allows asynchronous trigger of the AXI read signal
    extern_trigger     : in    std_logic;

    -- main state variable, used in a manner similar to a clock
    state              : inout integer;

    -- clock
    Clk                : in    std_logic;

    -- reset
    Reset              : in    std_logic
  );

end entity state_machine;

architecture IMP of state_machine
is

  -- detects whether the extern_trigger signal has been updated
  signal extern_trigger_event : std_logic;

begin

  -- select the current state
  DO_UPDATE : process (
      Clk, state, extern_trigger,
      reg_file_reset_ack, alu_reset_ack,
      send_inst_ack, decode_ack, load_ack, math_ack, store_ack,
      soft_read_ack, soft_write_ack
      )
  is
  begin
    -- new high edge
    if Clk'event and Clk = '1'
    then

      -- reset requested
      if Reset = '0'
      then
        state <= DO_REG_FILE_RESET;

      -- no reset, start processing
      else
        state <= DO_SEND_INST;

      end if;

    -- an AXI read was requested
    elsif extern_trigger /= extern_trigger_event
    then
        state <= DO_SOFT_READ;

    -- already processing, advance to the next state
    elsif state = DO_REG_FILE_RESET
      and reg_file_reset_ack'event
      and reg_file_reset_ack = '1'
    then
      state <= DO_ALU_RESET;
    elsif state = DO_ALU_RESET
      and alu_reset_ack'event
      and alu_reset_ack = '1'
    then
      state <= DO_CLEAR_FLAGS;
    elsif state = DO_SEND_INST
      and send_inst_ack'event
      and send_inst_ack = '1'
    then
      state <= DO_DECODE;
    elsif state = DO_DECODE
      and decode_ack'event
      and decode_ack = '1'
    then
      state <= DO_LOAD;
    elsif state = DO_LOAD
      and load_ack'event
      and load_ack = '1'
    then
      state <= DO_MATH;
    elsif state = DO_MATH
      and math_ack'event
      and math_ack = '1'
    then
      state <= DO_STORE;
    elsif state = DO_STORE
      and store_ack'event
      and store_ack = '1'
    then
      state <= DO_SOFT_WRITE;
    elsif state = DO_SOFT_WRITE
      and soft_write_ack'event
      and soft_write_ack = '1'
    then
      state <= DO_CLEAR_FLAGS;
    elsif state = DO_SOFT_READ
      and soft_read_ack'event
      and soft_read_ack = '1'
    then
      state <= DO_CLEAR_FLAGS;
    end if;

    -- set to allow detecting axi events
    extern_trigger_event <= extern_trigger;

  end process DO_UPDATE;

end IMP;