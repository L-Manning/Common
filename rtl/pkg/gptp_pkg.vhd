-- =============================================================================
-- File        : gptp_pkg.vhd
-- Entity      : gptp_pkg (package)
-- Description : IEEE Std 802.1AS-2020 gPTP type definitions, memory-map
--               constants, and utility functions for the Xilinx UltraScale+
--               boundary-clock implementation.
-- Standard    : VHDL-2008
-- =============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package gptp_pkg is

  ---------------------------------------------------------------------------
  -- IEEE 802.1AS-2020 Timestamp Types  (Section 6.3.3)
  ---------------------------------------------------------------------------

  -- ExtendedTimestamp (Section 6.3.3.3): 96-bit hardware timestamp.
  -- Used for the LocalClock output and MII-layer capture registers.
  type t_extended_timestamp is record
    seconds     : unsigned(47 downto 0);  -- seconds field
    nanoseconds : unsigned(31 downto 0);  -- nanoseconds [0, 999_999_999]
    frac_ns     : unsigned(15 downto 0);  -- fractional ns, units of 2^-16 ns
  end record t_extended_timestamp;

  -- Timestamp (Section 6.3.3.2): 80-bit, as carried in PTP message fields.
  -- e.g., preciseOriginTimestamp in Follow_Up messages.
  type t_timestamp is record
    seconds     : unsigned(47 downto 0);  -- seconds field
    nanoseconds : unsigned(31 downto 0);  -- nanoseconds [0, 999_999_999]
  end record t_timestamp;

  constant C_EXTENDED_TIMESTAMP_ZERO : t_extended_timestamp := (
    seconds     => (others => '0'),
    nanoseconds => (others => '0'),
    frac_ns     => (others => '0')
  );

  constant C_TIMESTAMP_ZERO : t_timestamp := (
    seconds     => (others => '0'),
    nanoseconds => (others => '0')
  );

  ---------------------------------------------------------------------------
  -- IEEE 802.1AS-2020 Scaled Time Types  (Sections 6.3.3.1, 6.4.3)
  ---------------------------------------------------------------------------

  -- UScaledNs: 80-bit unsigned, units of 2^-16 nanoseconds.
  -- Used for meanPathDelay, propagationDelay.
  subtype t_uscaled_ns is unsigned(79 downto 0);

  -- ScaledNs: 96-bit signed, units of 2^-16 nanoseconds.
  -- Used for lastGmPhaseChange and similar signed time quantities.
  subtype t_scaled_ns is signed(95 downto 0);

  -- CorrectionField: 64-bit signed integer, units of 2^-16 nanoseconds.
  -- As defined in IEEE 1588-2019 and carried in 802.1AS message headers.
  subtype t_correction_field is signed(63 downto 0);

  ---------------------------------------------------------------------------
  -- neighborRateRatio Fixed-Point Representation
  --
  -- IEEE 802.1AS-2020 defines neighborRateRatio as a Double.
  -- Hardware representation: signed 32-bit integer where
  --   stored_value = round( (neighborRateRatio - 1.0) * 2^30 )
  -- Range  : approximately +/- 930 ppm  (ample for any standard oscillator)
  -- LSB    : 2^-30 ~= 0.93 ppb
  ---------------------------------------------------------------------------
  subtype t_rate_ratio is signed(31 downto 0);

  -- Represents a ratio of exactly 1.0 (no frequency deviation)
  constant C_RATE_RATIO_UNITY : t_rate_ratio := (others => '0');

  ---------------------------------------------------------------------------
  -- Clock Servo Offset Type
  -- Signed 64-bit in units of 2^-16 ns.
  -- Range : +/- 2^47 ns  (~+/- 140 000 s, far beyond any realistic offset)
  -- LSB   : 2^-16 ns ~= 15 fs
  ---------------------------------------------------------------------------
  subtype t_offset_scaled_ns is signed(63 downto 0);

  ---------------------------------------------------------------------------
  -- Global AXI Memory Map
  --
  -- The gPTP global memory is partitioned by port index.  Each port occupies
  -- exactly C_PORT_MEM_SIZE bytes starting at:
  --
  --   PORT_MEM_BASE + port_index * C_PORT_MEM_SIZE
  --
  -- PDelay SM writes offsets 0x00..0x14 after each PDelay calculation.
  -- Sync   SM writes offsets 0x14..0x3C after each validated Follow_Up.
  -- slave_clock reads all fields to compute offsetFromMaster.
  --
  -- New-data detection uses a 4-bit sequence counter in the status word.
  -- The slave_clock caches the last-seen counter and detects increments
  -- without needing to write back to memory.
  --
  -- All registers are 32-bit wide; multi-word fields use LE word order.
  ---------------------------------------------------------------------------

  constant C_PORT_MEM_SIZE_LOG2 : natural := 8;             -- 256 bytes per port
  constant C_PORT_MEM_SIZE      : natural := 2**C_PORT_MEM_SIZE_LOG2;

  -- PDelay data (written by PDelay SM)
  -- 0x00 : pdelay_status
  --   bit 0      : pdelay_valid  (at least one round-trip completed)
  --   bits [7:4] : pdelay_seq_num (4-bit counter, incremented on each result)
  constant C_OFF_PDELAY_STATUS        : natural := 16#00#;
  -- 0x04 : neighborRateRatio  signed 32-bit, (ratio - 1.0) * 2^30
  constant C_OFF_NEIGHBOUR_RATE_RATIO : natural := 16#04#;
  -- 0x08..0x10 : meanPathDelay  UScaledNs[79:0], three 32-bit words, LE
  constant C_OFF_MEAN_PATH_DELAY_LO   : natural := 16#08#;  -- UScaledNs[31:0]
  constant C_OFF_MEAN_PATH_DELAY_MID  : natural := 16#0C#;  -- UScaledNs[63:32]
  constant C_OFF_MEAN_PATH_DELAY_HI   : natural := 16#10#;  -- UScaledNs[79:64] in [15:0]

  -- Sync data (written by Sync SM after Follow_Up validated)
  -- 0x14 : sync_status
  --   bit 0      : sync_valid    (at least one Sync/Follow_Up pair processed)
  --   bits [7:4] : sync_seq_num  (4-bit counter, incremented on each result)
  constant C_OFF_SYNC_STATUS          : natural := 16#14#;
  -- syncReceiptLocalTime  (hardware timestamp at Sync ingress, ExtendedTimestamp)
  constant C_OFF_SYNC_TS_SEC_LO       : natural := 16#18#;  -- seconds[31:0]
  constant C_OFF_SYNC_TS_SEC_HI       : natural := 16#1C#;  -- seconds[47:32] in [15:0]
  constant C_OFF_SYNC_TS_NS           : natural := 16#20#;  -- nanoseconds[31:0]
  constant C_OFF_SYNC_TS_FRAC         : natural := 16#24#;  -- frac_ns[15:0]
  -- preciseOriginTimestamp  (from Follow_Up message, Timestamp type)
  constant C_OFF_PRECISE_ORIG_SEC_LO  : natural := 16#28#;  -- seconds[31:0]
  constant C_OFF_PRECISE_ORIG_SEC_HI  : natural := 16#2C#;  -- seconds[47:32] in [15:0]
  constant C_OFF_PRECISE_ORIG_NS      : natural := 16#30#;  -- nanoseconds[31:0]
  -- followUpCorrectionField  (from Follow_Up message, CorrectionField type)
  constant C_OFF_CORR_FIELD_LO        : natural := 16#34#;  -- correctionField[31:0]
  constant C_OFF_CORR_FIELD_HI        : natural := 16#38#;  -- correctionField[63:32]
  -- Total used per port: 0x3C = 60 bytes (within the 256-byte C_PORT_MEM_SIZE)

  ---------------------------------------------------------------------------
  -- Utility Constants
  ---------------------------------------------------------------------------

  constant C_NS_PER_SEC : natural := 1_000_000_000;

  -- C_NS_PER_SEC expressed in units of 2^-16 ns (UScaledNs equivalent).
  -- = 10^9 * 2^16 = 65_536_000_000_000.  Fits in 47 bits; safe as signed(47:0).
  constant C_NS_PER_SEC_SCALED : signed(47 downto 0) :=
    to_signed(65_536_000_000_000, 48);

  ---------------------------------------------------------------------------
  -- Utility Functions
  ---------------------------------------------------------------------------

  -- Promote a Timestamp to an ExtendedTimestamp (fractional ns set to zero).
  function f_ts_to_ext_ts(ts : t_timestamp) return t_extended_timestamp;

  -- Sub-second component of an ExtendedTimestamp in units of 2^-16 ns.
  -- Returns: nanoseconds * 2^16 + frac_ns  (result fits in 46 bits; returned as 48-bit)
  function f_sub_second_scaled(ts : t_extended_timestamp) return unsigned;

end package gptp_pkg;

-- =============================================================================
package body gptp_pkg is

  function f_ts_to_ext_ts(ts : t_timestamp) return t_extended_timestamp is
    variable v_result : t_extended_timestamp;
  begin
    v_result.seconds     := ts.seconds;
    v_result.nanoseconds := ts.nanoseconds;
    v_result.frac_ns     := (others => '0');
    return v_result;
  end function f_ts_to_ext_ts;

  function f_sub_second_scaled(ts : t_extended_timestamp) return unsigned is
    variable v_ns_part   : unsigned(47 downto 0);
    variable v_frac_part : unsigned(47 downto 0);
  begin
    v_ns_part   := resize(ts.nanoseconds, 48) sll 16;  -- nanoseconds * 2^16
    v_frac_part := resize(ts.frac_ns, 48);
    return v_ns_part + v_frac_part;                     -- 46-bit value, safe in 48 bits
  end function f_sub_second_scaled;

end package body gptp_pkg;
