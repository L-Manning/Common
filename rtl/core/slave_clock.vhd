-- =============================================================================
-- File        : slave_clock.vhd
-- Entity      : slave_clock
-- Description : Per-instance gPTP slave clock for IEEE Std 802.1AS-2020.
--               Implements three logical entities from the standard:
--
--                 LocalClock      (Section 10.2.4) -- 96-bit hardware timer
--                 ClockSlaveSync  (Section 10.2.7) -- offset calc + PI servo
--                 ClockMasterSync (Section 10.2.8) -- downstream trigger gen
--
--               The entity reads Sync and PDelay results written by the
--               per-port ethernet_gptp_controller blocks into the global AXI
--               memory, computes offsetFromMaster, disciplines the local clock
--               via a PI servo, and generates periodic sync_trigger /
--               announce_trigger pulses for the master-facing port controller.
--
--               Two-step clock model assumed throughout.
--               Switch is never grandmaster; GM port index is fixed via generic.
--
-- Standard    : VHDL-2008
-- Target      : AMD Xilinx UltraScale+
-- =============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.gptp_pkg.all;

-- -----------------------------------------------------------------------------
entity slave_clock is
  generic (
    -- Index of the port physically connected to the grandmaster.
    -- Selects which AXI memory region the slave_clock reads from.
    GM_PORT_INDEX         : natural   := 0;

    -- log2(syncInterval in seconds) per IEEE 802.1AS-2020 logMessageInterval.
    -- 0 => 1 s, 1 => 2 s, -1 => 0.5 s  (negative values require wider counters;
    -- restrict to >= 0 for this implementation).
    SYNC_LOG_MSG_INTERVAL : integer   := 0;

    -- log2(announceInterval in seconds).
    ANNC_LOG_MSG_INTERVAL : integer   := 0;

    -- Local reference clock period in nanoseconds (125 MHz => 8 ns).
    CLK_PERIOD_NS         : positive  := 8;

    -- PI servo proportional gain expressed as a right-shift of the offset.
    -- freq_adj_P = -(offset >> KP_SHIFT).  Default 11 => Kp ~ 2^-11.
    KP_SHIFT              : natural   := 11;

    -- PI servo integral gain expressed as a right-shift of the offset.
    -- integrator += -(offset >> KI_SHIFT) each sync interval.
    KI_SHIFT              : natural   := 21;

    -- Offset magnitude (nanoseconds) above which a one-shot phase step is
    -- issued instead of relying on frequency-only servo correction.
    -- Applied both at startup and after large disturbances.
    PHASE_STEP_THRESHOLD_NS : natural := 1_000;

    -- AXI4 Full master interface parameters.
    AXI_ADDR_WIDTH        : positive  := 32;
    AXI_DATA_WIDTH        : positive  := 32;   -- must be 32
    AXI_ID_WIDTH          : positive  := 4;

    -- Base address of the gPTP global memory in the AXI address space.
    -- Port n region starts at PORT_MEM_BASE + n * C_PORT_MEM_SIZE.
    PORT_MEM_BASE         : unsigned(31 downto 0) := (others => '0')
  );
  port (
    -- System clock (125 MHz recovered / system clock) and synchronous reset
    clk              : in  std_logic;  -- system clock
    rst              : in  std_logic;  -- synchronous reset, active-high

    -- -------------------------------------------------------------------------
    -- AXI4 Full read-only master
    -- Reads PDelay and Sync results from the global gPTP memory via the
    -- AXI crossbar.  Write channels are omitted; only AR + R are needed.
    -- All transactions are single-beat (ARLEN = 0, ARSIZE = "010").
    -- -------------------------------------------------------------------------
    m_axi_arid       : out std_logic_vector(AXI_ID_WIDTH-1   downto 0);  -- read address ID
    m_axi_araddr     : out std_logic_vector(AXI_ADDR_WIDTH-1 downto 0);  -- read address
    m_axi_arlen      : out std_logic_vector(7 downto 0);                  -- burst length (always 0)
    m_axi_arsize     : out std_logic_vector(2 downto 0);                  -- beat size (always "010")
    m_axi_arburst    : out std_logic_vector(1 downto 0);                  -- burst type (always INCR)
    m_axi_arvalid    : out std_logic;                                     -- address valid
    m_axi_arready    : in  std_logic;                                     -- address accepted
    m_axi_rid        : in  std_logic_vector(AXI_ID_WIDTH-1   downto 0);  -- read ID tag
    m_axi_rdata      : in  std_logic_vector(AXI_DATA_WIDTH-1 downto 0);  -- read data
    m_axi_rresp      : in  std_logic_vector(1 downto 0);                  -- read response
    m_axi_rlast      : in  std_logic;                                     -- last beat
    m_axi_rvalid     : in  std_logic;                                     -- read data valid
    m_axi_rready     : out std_logic;                                     -- read data accepted

    -- -------------------------------------------------------------------------
    -- Synchronized LocalClock output
    -- Continuously valid once the servo has converged (local_time_valid = '1').
    -- -------------------------------------------------------------------------
    local_time       : out t_extended_timestamp;  -- current synchronized time
    local_time_valid : out std_logic;             -- asserted after servo convergence

    -- -------------------------------------------------------------------------
    -- ClockMasterSync trigger outputs
    -- One-cycle pulses delivered to the master-facing (endpoint) port
    -- controller to initiate Sync and Announce message transmission.
    -- -------------------------------------------------------------------------
    sync_trigger     : out std_logic;  -- pulse at syncInterval rate
    announce_trigger : out std_logic;  -- pulse at announceInterval rate

    -- -------------------------------------------------------------------------
    -- Diagnostics / status
    -- -------------------------------------------------------------------------
    locked           : out std_logic;             -- servo converged, offset within 100 ns
    offset_valid     : out std_logic;             -- at least one offset calculation complete
    offset_scaled_ns : out signed(63 downto 0)   -- current offsetFromMaster in 2^-16 ns
  );
end entity slave_clock;

-- =============================================================================
architecture rtl of slave_clock is

  ---------------------------------------------------------------------------
  -- AXI poll FSM type
  -- A single FSM handles both the sequential AXI reads and data decoding.
  ---------------------------------------------------------------------------
  type t_poll_state is (
    P_IDLE,       -- waiting for poll interval to expire
    P_SEND_AR,    -- driving AXI AR channel
    P_WAIT_R,     -- waiting for AXI R channel response
    P_ADVANCE,    -- decide next read index or finish
    P_PROCESS,    -- decode latched words, pulse r_sync_new if new data seen
    P_OTHERS      -- mandatory catch-all per Rule N3
  );

  -- Attribute for FSM encoding on UltraScale+
  attribute FSM_ENCODING : string;

  ---------------------------------------------------------------------------
  -- AXI read register index constants
  -- Each index maps to one 32-bit read from the GM port memory region.
  ---------------------------------------------------------------------------
  constant C_N_READS              : natural := 15;

  constant C_IDX_PDELAY_STATUS    : natural :=  0;  -- C_OFF_PDELAY_STATUS
  constant C_IDX_NRR              : natural :=  1;  -- C_OFF_NEIGHBOUR_RATE_RATIO
  constant C_IDX_MPD_LO           : natural :=  2;  -- C_OFF_MEAN_PATH_DELAY_LO
  constant C_IDX_MPD_MID          : natural :=  3;  -- C_OFF_MEAN_PATH_DELAY_MID
  constant C_IDX_MPD_HI           : natural :=  4;  -- C_OFF_MEAN_PATH_DELAY_HI
  constant C_IDX_SYNC_STATUS      : natural :=  5;  -- C_OFF_SYNC_STATUS
  constant C_IDX_SYNC_TS_SEC_LO   : natural :=  6;  -- C_OFF_SYNC_TS_SEC_LO
  constant C_IDX_SYNC_TS_SEC_HI   : natural :=  7;  -- C_OFF_SYNC_TS_SEC_HI
  constant C_IDX_SYNC_TS_NS       : natural :=  8;  -- C_OFF_SYNC_TS_NS
  constant C_IDX_SYNC_TS_FRAC     : natural :=  9;  -- C_OFF_SYNC_TS_FRAC
  constant C_IDX_ORIG_SEC_LO      : natural := 10;  -- C_OFF_PRECISE_ORIG_SEC_LO
  constant C_IDX_ORIG_SEC_HI      : natural := 11;  -- C_OFF_PRECISE_ORIG_SEC_HI
  constant C_IDX_ORIG_NS          : natural := 12;  -- C_OFF_PRECISE_ORIG_NS
  constant C_IDX_CF_LO            : natural := 13;  -- C_OFF_CORR_FIELD_LO
  constant C_IDX_CF_HI            : natural := 14;  -- C_OFF_CORR_FIELD_HI

  -- Address offset table: maps read index -> byte offset within port region
  type t_offset_table is array(0 to C_N_READS-1) of natural;
  constant C_ADDR_OFFSETS : t_offset_table := (
    C_OFF_PDELAY_STATUS,
    C_OFF_NEIGHBOUR_RATE_RATIO,
    C_OFF_MEAN_PATH_DELAY_LO,
    C_OFF_MEAN_PATH_DELAY_MID,
    C_OFF_MEAN_PATH_DELAY_HI,
    C_OFF_SYNC_STATUS,
    C_OFF_SYNC_TS_SEC_LO,
    C_OFF_SYNC_TS_SEC_HI,
    C_OFF_SYNC_TS_NS,
    C_OFF_SYNC_TS_FRAC,
    C_OFF_PRECISE_ORIG_SEC_LO,
    C_OFF_PRECISE_ORIG_SEC_HI,
    C_OFF_PRECISE_ORIG_NS,
    C_OFF_CORR_FIELD_LO,
    C_OFF_CORR_FIELD_HI
  );

  -- Read data capture array
  type t_mem_data_array is array(0 to C_N_READS-1) of
    std_logic_vector(AXI_DATA_WIDTH-1 downto 0);

  ---------------------------------------------------------------------------
  -- Derived constants
  ---------------------------------------------------------------------------

  -- Base address of the GM port's memory region in the global AXI memory
  constant C_GM_BASE : unsigned(AXI_ADDR_WIDTH-1 downto 0) :=
    resize(PORT_MEM_BASE, AXI_ADDR_WIDTH) +
    to_unsigned(GM_PORT_INDEX * C_PORT_MEM_SIZE, AXI_ADDR_WIDTH);

  -- LocalClock nominal increment per clock cycle in the 64-bit phase
  -- accumulator.  Format: [63:32] = integer ns, [31:0] = fractional ns.
  -- = CLK_PERIOD_NS * 2^32  (e.g. 8 * 2^32 = 0x0000_0008_0000_0000)
  constant C_NOM_INC : unsigned(63 downto 0) :=
    to_unsigned(CLK_PERIOD_NS, 32) & to_unsigned(0, 32);

  -- Poll interval: half the sync interval, to guarantee we read new data
  -- within one sync period.  Units: clock cycles.
  constant C_POLL_INTERVAL : natural :=
    C_NS_PER_SEC * (2**SYNC_LOG_MSG_INTERVAL) / CLK_PERIOD_NS / 2;

  -- Sync and announce trigger intervals in clock cycles
  constant C_SYNC_INTERVAL : natural :=
    C_NS_PER_SEC * (2**SYNC_LOG_MSG_INTERVAL) / CLK_PERIOD_NS;

  constant C_ANNC_INTERVAL : natural :=
    C_NS_PER_SEC * (2**ANNC_LOG_MSG_INTERVAL) / CLK_PERIOD_NS;

  -- Phase-step threshold in 2^-16 ns units (PHASE_STEP_THRESHOLD_NS * 2^16)
  constant C_STEP_THRESH : signed(63 downto 0) :=
    to_signed(PHASE_STEP_THRESHOLD_NS * 65536, 64);

  -- Lock threshold: declare converged when |offset| < 100 ns (in 2^-16 ns)
  constant C_LOCK_THRESH : signed(63 downto 0) :=
    to_signed(100 * 65536, 64);

  ---------------------------------------------------------------------------
  -- LocalClock signals  (proc_local_clock)
  ---------------------------------------------------------------------------

  -- 64-bit phase accumulator: upper 32 bits = nanoseconds (integer),
  -- lower 32 bits = sub-nanosecond fraction (units of 2^-32 ns).
  signal r_phase_acc        : unsigned(63 downto 0);

  signal r_seconds          : unsigned(47 downto 0);  -- seconds counter

  -- Signed frequency adjustment from the PI servo.
  -- Units: 2^-32 ns per clock cycle.
  -- LSB at 125 MHz: 1/2^32 * 125e6 ns/s ~= 0.029 ppb per LSB.
  signal r_freq_adj         : signed(31 downto 0);

  -- One-cycle phase-step request (driven by proc_servo, read by proc_local_clock).
  -- Asserted for exactly one clock cycle when a large offset demands a direct
  -- time correction rather than a frequency nudge.
  signal r_phase_step_valid : std_logic;
  signal r_phase_step_ts    : t_extended_timestamp;  -- target time for the step

  ---------------------------------------------------------------------------
  -- AXI read master / poll FSM signals  (proc_poll_axi)
  ---------------------------------------------------------------------------
  signal r_poll_state       : t_poll_state;
  attribute FSM_ENCODING of r_poll_state : signal is "ONE_HOT";

  signal r_poll_ctr         : unsigned(30 downto 0);  -- interval counter
  signal r_read_idx         : natural range 0 to C_N_READS;
  signal r_mem_data         : t_mem_data_array;

  signal r_ar_valid         : std_logic;
  signal r_ar_addr          : unsigned(AXI_ADDR_WIDTH-1 downto 0);

  -- Latched PDelay results (GM port)
  signal r_pdelay_seq_prev  : unsigned(3 downto 0);  -- last seen sequence number
  signal r_nrr              : t_rate_ratio;           -- neighborRateRatio
  signal r_mpd              : t_uscaled_ns;           -- meanPathDelay
  signal r_pdelay_latched   : std_logic;              -- at least one valid PDelay result

  -- Latched Sync / Follow_Up results (GM port)
  signal r_sync_seq_prev    : unsigned(3 downto 0);  -- last seen sequence number
  signal r_rx_ts            : t_extended_timestamp;  -- syncReceiptLocalTime
  signal r_precise_orig_ts  : t_timestamp;           -- preciseOriginTimestamp
  signal r_corr_field       : t_correction_field;    -- followUpCorrectionField

  -- One-cycle pulse to proc_servo: new, validated Sync data is ready.
  -- Driven exclusively by proc_poll_axi (Rule N5).
  signal r_sync_new         : std_logic;

  ---------------------------------------------------------------------------
  -- PI servo signals  (proc_servo)
  ---------------------------------------------------------------------------
  signal r_integrator       : signed(63 downto 0);
  signal r_offset           : t_offset_scaled_ns;
  signal r_offset_valid     : std_logic;
  signal r_locked           : std_logic;
  signal r_locked_count     : unsigned(3 downto 0);

  ---------------------------------------------------------------------------
  -- ClockMasterSync signals  (proc_master_sync)
  ---------------------------------------------------------------------------
  signal r_sync_ctr         : unsigned(30 downto 0);
  signal r_annc_ctr         : unsigned(30 downto 0);
  signal r_sync_trig        : std_logic;
  signal r_annc_trig        : std_logic;

begin

  -- ===========================================================================
  -- Static AXI channel outputs (these never change)
  -- ===========================================================================
  m_axi_arid    <= (others => '0');
  m_axi_arlen   <= (others => '0');          -- single beat (LEN = 0)
  m_axi_arsize  <= "010";                    -- 4 bytes per beat
  m_axi_arburst <= "01";                     -- INCR (value irrelevant for LEN=0)
  m_axi_arvalid <= r_ar_valid;
  m_axi_araddr  <= std_logic_vector(r_ar_addr);
  m_axi_rready  <= '1';                      -- always ready to accept read data

  -- ===========================================================================
  -- LocalClock output (combinational, updated each cycle)
  -- ===========================================================================
  local_time.seconds     <= r_seconds;
  local_time.nanoseconds <= r_phase_acc(63 downto 32);
  local_time.frac_ns     <= r_phase_acc(31 downto 16);  -- upper 16 bits of sub-ns fraction

  -- ===========================================================================
  -- Diagnostic / status outputs
  -- ===========================================================================
  locked           <= r_locked;
  offset_valid     <= r_offset_valid;
  offset_scaled_ns <= r_offset;
  local_time_valid <= r_locked;
  sync_trigger     <= r_sync_trig;
  announce_trigger <= r_annc_trig;

  -- ===========================================================================
  -- proc_local_clock : LocalClock  (IEEE 802.1AS-2020 Section 10.2.4)
  --
  -- Maintains a 96-bit Extended Timestamp using a 64-bit phase accumulator:
  --   r_phase_acc[63:32] = nanoseconds  (integer part, 0..999_999_999)
  --   r_phase_acc[31:0]  = sub-ns fraction (units of 2^-32 ns)
  --   r_seconds          = seconds counter
  --
  -- Each cycle the nominal increment C_NOM_INC (= CLK_PERIOD_NS * 2^32) is
  -- added together with the signed r_freq_adj from the PI servo.  This gives
  -- a frequency adjustment resolution of ~0.029 ppb at 125 MHz.
  --
  -- When proc_servo asserts r_phase_step_valid for one cycle, the accumulator
  -- is loaded directly with r_phase_step_ts (large-offset correction).
  -- ===========================================================================
  proc_local_clock : process(clk)
    variable v_next       : unsigned(63 downto 0);  -- next accumulator value
    variable v_ns         : unsigned(31 downto 0);  -- integer ns after increment
  begin
    if rising_edge(clk) then
      if rst = '1' then
        r_phase_acc <= (others => '0');
        r_seconds   <= (others => '0');
      else
        if r_phase_step_valid = '1' then
          -- ----------------------------------------------------------------
          -- Phase step: load accumulator directly from the servo-supplied
          -- target time.  Sub-ns fraction is zeroed (error < 1 LSB of frac_ns).
          -- ----------------------------------------------------------------
          r_phase_acc <=   r_phase_step_ts.nanoseconds      -- [63:32]
                         & r_phase_step_ts.frac_ns          -- [47:32]
                         & to_unsigned(0, 16);              -- [15:0] sub-frac
          r_seconds   <= r_phase_step_ts.seconds;

        else
          -- ----------------------------------------------------------------
          -- Normal operation: accumulate nominal increment + freq adjustment.
          -- r_freq_adj is signed; handle via separate add/subtract to keep
          -- the accumulator unsigned throughout (Rule N2).
          -- ----------------------------------------------------------------
          v_next := r_phase_acc + C_NOM_INC;

          if r_freq_adj >= 0 then
            v_next := v_next + resize(unsigned(r_freq_adj), 64);
          else
            v_next := v_next - resize(unsigned(-r_freq_adj), 64);
          end if;

          -- Nanosecond roll-over: subtract 10^9 and increment seconds
          v_ns := v_next(63 downto 32);
          if v_ns >= to_unsigned(C_NS_PER_SEC, 32) then
            r_phase_acc <=   (v_ns - to_unsigned(C_NS_PER_SEC, 32))
                           & v_next(31 downto 0);
            r_seconds   <= r_seconds + 1;
          else
            r_phase_acc <= v_next;
          end if;
        end if;
      end if;
    end if;
  end process proc_local_clock;

  -- ===========================================================================
  -- proc_poll_axi : AXI read master + poll control
  --
  -- Periodically (every C_POLL_INTERVAL cycles) issues up to C_N_READS
  -- single-beat AXI4 Full read transactions to the GM port memory region
  -- in the global gPTP AXI memory.
  --
  -- New-data detection: each SM writes a 4-bit sequence counter into the
  -- status word for its region.  This FSM caches the last-seen value and
  -- only re-reads (and pulses r_sync_new) when the counter changes.
  -- Initialised to x"F" so that any valid counter value (0-15) is detected
  -- as new on the first poll after reset.
  --
  -- Sync register reads are skipped entirely when sync_status shows no new
  -- data, saving bandwidth on the AXI crossbar.
  -- ===========================================================================
  proc_poll_axi : process(clk)
    variable v_pdelay_seq  : unsigned(3 downto 0);
    variable v_sync_seq    : unsigned(3 downto 0);
    variable v_rx_ts       : t_extended_timestamp;
    variable v_orig_ts     : t_timestamp;
    variable v_cf          : t_correction_field;
    variable v_mpd         : t_uscaled_ns;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        r_poll_state      <= P_IDLE;
        r_poll_ctr        <= (others => '0');
        r_read_idx        <= 0;
        r_ar_valid        <= '0';
        r_ar_addr         <= (others => '0');
        r_sync_new        <= '0';
        r_pdelay_seq_prev <= (others => '1');  -- x"F": forces detection on first poll
        r_sync_seq_prev   <= (others => '1');
        r_pdelay_latched  <= '0';
        r_nrr             <= (others => '0');
        r_mpd             <= (others => '0');
        r_rx_ts           <= C_EXTENDED_TIMESTAMP_ZERO;
        r_precise_orig_ts <= C_TIMESTAMP_ZERO;
        r_corr_field      <= (others => '0');
        for i in 0 to C_N_READS-1 loop
          r_mem_data(i)   <= (others => '0');
        end loop;
      else
        r_sync_new <= '0';  -- default: pulse is low; only raised in P_PROCESS

        case r_poll_state is

          -- ------------------------------------------------------------------
          when P_IDLE =>
            r_ar_valid <= '0';
            if r_poll_ctr = to_unsigned(C_POLL_INTERVAL - 1, 31) then
              r_poll_ctr   <= (others => '0');
              r_read_idx   <= 0;
              r_poll_state <= P_SEND_AR;
            else
              r_poll_ctr <= r_poll_ctr + 1;
            end if;

          -- ------------------------------------------------------------------
          -- Assert the AXI read address for r_read_idx.
          -- Stay in this state until arready is seen.
          -- ------------------------------------------------------------------
          when P_SEND_AR =>
            r_ar_valid <= '1';
            r_ar_addr  <= C_GM_BASE +
                          to_unsigned(C_ADDR_OFFSETS(r_read_idx), AXI_ADDR_WIDTH);
            if m_axi_arready = '1' then
              r_ar_valid   <= '0';
              r_poll_state <= P_WAIT_R;
            end if;

          -- ------------------------------------------------------------------
          -- Wait for AXI read data; latch into r_mem_data(r_read_idx).
          -- ------------------------------------------------------------------
          when P_WAIT_R =>
            if m_axi_rvalid = '1' then
              -- AXI SLVERR / DECERR are non-fatal for a demo; data is used
              -- only if the SW-level sequence counter indicates it is fresh.
              r_mem_data(r_read_idx) <= m_axi_rdata;
              r_poll_state           <= P_ADVANCE;
            end if;

          -- ------------------------------------------------------------------
          -- Decide whether to read the next register or move to P_PROCESS.
          -- After the Sync status register (index C_IDX_SYNC_STATUS) we check
          -- for new data; if none, skip the remaining Sync registers entirely.
          -- ------------------------------------------------------------------
          when P_ADVANCE =>
            if r_read_idx = C_IDX_SYNC_STATUS then
              v_sync_seq := unsigned(r_mem_data(C_IDX_SYNC_STATUS)(7 downto 4));
              if r_mem_data(C_IDX_SYNC_STATUS)(0) = '1' and
                 v_sync_seq /= r_sync_seq_prev then
                -- New Sync data: continue reading Sync registers
                r_read_idx   <= r_read_idx + 1;
                r_poll_state <= P_SEND_AR;
              else
                -- No new Sync data: skip to processing (PDelay may still be new)
                r_poll_state <= P_PROCESS;
              end if;
            elsif r_read_idx = C_N_READS - 1 then
              r_poll_state <= P_PROCESS;
            else
              r_read_idx   <= r_read_idx + 1;
              r_poll_state <= P_SEND_AR;
            end if;

          -- ------------------------------------------------------------------
          -- P_PROCESS: decode all latched words, update registered data, and
          -- issue r_sync_new if a fresh Sync/Follow_Up pair is available.
          -- This state executes in exactly one clock cycle.
          -- ------------------------------------------------------------------
          when P_PROCESS =>
            -- ----------------------------------------------------------------
            -- PDelay data: update if the sequence counter changed
            -- ----------------------------------------------------------------
            v_pdelay_seq := unsigned(r_mem_data(C_IDX_PDELAY_STATUS)(7 downto 4));
            if r_mem_data(C_IDX_PDELAY_STATUS)(0) = '1' and
               v_pdelay_seq /= r_pdelay_seq_prev then
              r_nrr  <= signed(r_mem_data(C_IDX_NRR));
              v_mpd  := unsigned(r_mem_data(C_IDX_MPD_HI)(15 downto 0)) &
                        unsigned(r_mem_data(C_IDX_MPD_MID))              &
                        unsigned(r_mem_data(C_IDX_MPD_LO));
              r_mpd             <= v_mpd;
              r_pdelay_latched  <= '1';
              r_pdelay_seq_prev <= v_pdelay_seq;
            end if;

            -- ----------------------------------------------------------------
            -- Sync data: update and pulse r_sync_new if sequence counter changed
            -- ----------------------------------------------------------------
            v_sync_seq := unsigned(r_mem_data(C_IDX_SYNC_STATUS)(7 downto 4));
            if r_mem_data(C_IDX_SYNC_STATUS)(0) = '1' and
               v_sync_seq /= r_sync_seq_prev then

              v_rx_ts.seconds     := (others => '0');
              v_rx_ts.seconds(31 downto 0)  :=
                unsigned(r_mem_data(C_IDX_SYNC_TS_SEC_LO));
              v_rx_ts.seconds(47 downto 32) :=
                unsigned(r_mem_data(C_IDX_SYNC_TS_SEC_HI)(15 downto 0));
              v_rx_ts.nanoseconds :=
                unsigned(r_mem_data(C_IDX_SYNC_TS_NS));
              v_rx_ts.frac_ns     :=
                unsigned(r_mem_data(C_IDX_SYNC_TS_FRAC)(15 downto 0));

              v_orig_ts.seconds   := (others => '0');
              v_orig_ts.seconds(31 downto 0)  :=
                unsigned(r_mem_data(C_IDX_ORIG_SEC_LO));
              v_orig_ts.seconds(47 downto 32) :=
                unsigned(r_mem_data(C_IDX_ORIG_SEC_HI)(15 downto 0));
              v_orig_ts.nanoseconds :=
                unsigned(r_mem_data(C_IDX_ORIG_NS));

              v_cf(31 downto 0)  := signed(r_mem_data(C_IDX_CF_LO));
              v_cf(63 downto 32) := signed(r_mem_data(C_IDX_CF_HI));

              r_rx_ts           <= v_rx_ts;
              r_precise_orig_ts <= v_orig_ts;
              r_corr_field      <= v_cf;
              r_sync_seq_prev   <= v_sync_seq;
              r_sync_new        <= '1';  -- one-cycle pulse consumed by proc_servo
            end if;

            r_poll_state <= P_IDLE;

          -- ------------------------------------------------------------------
          when P_OTHERS | others =>
            r_ar_valid   <= '0';
            r_poll_state <= P_IDLE;

        end case;
      end if;
    end if;
  end process proc_poll_axi;

  -- ===========================================================================
  -- proc_servo : ClockSlaveSync  (IEEE 802.1AS-2020 Section 10.2.7)
  --
  -- Triggered by the one-cycle r_sync_new pulse from proc_poll_axi, which
  -- guarantees r_rx_ts, r_precise_orig_ts, r_corr_field, r_mpd, and r_nrr
  -- are all stable before this process reads them (they were registered in
  -- the same cycle that r_sync_new was set, so they are valid one cycle later
  -- when this process acts on r_sync_new = '1').
  --
  -- Algorithm (IEEE 802.1AS-2020 Annex B):
  --
  --   offsetFromMaster =   syncReceiptLocalTime
  --                      - preciseOriginTimestamp
  --                      - followUpCorrectionField
  --                      - meanPathDelay
  --
  --   All quantities held in units of 2^-16 ns for unified arithmetic.
  --
  --   If |offset| > PHASE_STEP_THRESHOLD_NS, a one-shot phase step is issued
  --   to proc_local_clock and the integrator is reset (fast acquisition).
  --
  --   Otherwise the PI servo updates r_freq_adj:
  --     P term       = -(offset >> KP_SHIFT)
  --     I term       = -(offset >> KI_SHIFT)  (accumulated each sync period)
  --     r_freq_adj   = P term + integrator
  --
  -- r_phase_step_valid is asserted for exactly one clock cycle (the default
  -- assignment '0' fires every cycle; the override to '1' only fires when
  -- r_sync_new = '1' AND offset exceeds the threshold).
  -- ===========================================================================
  proc_servo : process(clk)
    variable v_local_sub    : unsigned(47 downto 0);  -- sub-second of local rx time
    variable v_orig_sub     : unsigned(47 downto 0);  -- sub-second of GM origin time
    variable v_sub_offset   : signed(63 downto 0);    -- uncorrected sub-second offset
    variable v_sec_diff     : signed(48 downto 0);    -- seconds(local) - seconds(GM)
    variable v_total_offset : signed(63 downto 0);    -- offsetFromMaster in 2^-16 ns
    variable v_p_term       : signed(63 downto 0);    -- proportional servo term
    variable v_new_integ    : signed(63 downto 0);    -- updated integrator value
    variable v_freq_sum     : signed(63 downto 0);    -- P + I before saturation
    variable v_step_ns      : signed(63 downto 0);    -- target ns for phase step
    variable v_step_sec     : unsigned(47 downto 0);  -- target seconds for phase step
  begin
    if rising_edge(clk) then
      if rst = '1' then
        r_integrator      <= (others => '0');
        r_offset          <= (others => '0');
        r_offset_valid    <= '0';
        r_locked          <= '0';
        r_locked_count    <= (others => '0');
        r_freq_adj        <= (others => '0');
        r_phase_step_valid <= '0';
        r_phase_step_ts   <= C_EXTENDED_TIMESTAMP_ZERO;
      else
        r_phase_step_valid <= '0';  -- default: no phase step this cycle

        -- Wait for both PDelay result (r_pdelay_latched) and a new Sync event
        if r_sync_new = '1' and r_pdelay_latched = '1' then

          -- ----------------------------------------------------------------
          -- Step 1: compute sub-second offset in 2^-16 ns units
          -- f_sub_second_scaled returns nanoseconds*2^16 + frac_ns  (48-bit)
          -- ----------------------------------------------------------------
          v_local_sub := f_sub_second_scaled(r_rx_ts);
          v_orig_sub  := resize(r_precise_orig_ts.nanoseconds, 48) sll 16;

          -- Simulation check: ensure meanPathDelay fits in 64 bits (Rule N7)
          assert r_mpd(79 downto 64) = x"0000"
            report "slave_clock: meanPathDelay upper 16 bits non-zero; " &
                   "value exceeds 2^64-1 in 2^-16 ns units"
            severity warning;

          v_sub_offset :=   signed(resize(v_local_sub, 64))
                          - signed(resize(v_orig_sub,  64))
                          - r_corr_field
                          - signed(r_mpd(63 downto 0));

          -- ----------------------------------------------------------------
          -- Step 2: account for seconds-field difference
          -- Handles boundary crossing (local and GM on opposite sides of a
          -- second boundary) without wide multiplication.
          -- ----------------------------------------------------------------
          v_sec_diff := signed(resize(r_rx_ts.seconds,           49)) -
                        signed(resize(r_precise_orig_ts.seconds, 49));

          if v_sec_diff = 0 then
            v_total_offset := v_sub_offset;

          elsif v_sec_diff = 1 then
            -- Local clock is one second ahead: positive contribution
            v_total_offset := resize(C_NS_PER_SEC_SCALED, 64) + v_sub_offset;

          elsif v_sec_diff = -1 then
            v_total_offset := -resize(C_NS_PER_SEC_SCALED, 64) + v_sub_offset;

          else
            -- ----------------------------------------------------------------
            -- Offset > 1 second: perform an immediate phase step.
            -- Target = preciseOriginTimestamp
            --          + integer_ns(correctionField)
            --          + integer_ns(meanPathDelay)
            -- ----------------------------------------------------------------
            v_step_ns :=   signed(resize(r_precise_orig_ts.nanoseconds, 64))
                         + shift_right(r_corr_field, 16)
                         + signed(resize(shift_right(r_mpd, 16), 64));

            -- Resolve target seconds accounting for the ns over/underflow
            if v_step_ns >= to_signed(C_NS_PER_SEC, 64) then
              v_step_sec := r_precise_orig_ts.seconds + 1;
              v_step_ns  := v_step_ns - to_signed(C_NS_PER_SEC, 64);
            elsif v_step_ns < 0 then
              v_step_sec := r_precise_orig_ts.seconds - 1;
              v_step_ns  := v_step_ns + to_signed(C_NS_PER_SEC, 64);
            else
              v_step_sec := r_precise_orig_ts.seconds;
            end if;

            r_phase_step_ts.seconds     <= v_step_sec;
            r_phase_step_ts.nanoseconds <= unsigned(v_step_ns(31 downto 0));
            r_phase_step_ts.frac_ns     <= (others => '0');
            r_phase_step_valid          <= '1';
            r_integrator                <= (others => '0');
            v_total_offset              := (others => '0');
          end if;

          r_offset       <= v_total_offset;
          r_offset_valid <= '1';

          -- ----------------------------------------------------------------
          -- Phase step for sub-second large offset (startup / disturbance)
          -- ----------------------------------------------------------------
          if v_total_offset > C_STEP_THRESH or v_total_offset < -C_STEP_THRESH then
            -- Target = same formula as above; v_sec_diff is 0/+1/-1 here
            v_step_ns :=   signed(resize(r_precise_orig_ts.nanoseconds, 64))
                         + shift_right(r_corr_field, 16)
                         + signed(resize(shift_right(r_mpd, 16), 64));

            if v_step_ns >= to_signed(C_NS_PER_SEC, 64) then
              if v_sec_diff = -1 then
                v_step_sec := r_precise_orig_ts.seconds;
              else
                v_step_sec := r_precise_orig_ts.seconds + 1;
              end if;
              v_step_ns := v_step_ns - to_signed(C_NS_PER_SEC, 64);
            elsif v_step_ns < 0 then
              if v_sec_diff = 1 then
                v_step_sec := r_precise_orig_ts.seconds;
              else
                v_step_sec := r_precise_orig_ts.seconds - 1;
              end if;
              v_step_ns := v_step_ns + to_signed(C_NS_PER_SEC, 64);
            else
              if v_sec_diff = 0 then
                v_step_sec := r_precise_orig_ts.seconds;
              elsif v_sec_diff = 1 then
                v_step_sec := r_precise_orig_ts.seconds + 1;
              else
                v_step_sec := r_precise_orig_ts.seconds - 1;
              end if;
            end if;

            r_phase_step_ts.seconds     <= v_step_sec;
            r_phase_step_ts.nanoseconds <= unsigned(v_step_ns(31 downto 0));
            r_phase_step_ts.frac_ns     <= (others => '0');
            r_phase_step_valid          <= '1';
            r_integrator                <= (others => '0');

          else
            -- ----------------------------------------------------------------
            -- PI servo: frequency-only correction
            --
            -- Negative feedback: if offset > 0 the local clock is ahead of GM,
            -- so freq_adj must be negative (slow down the local clock).
            --
            -- r_freq_adj units: 2^-32 ns/cycle
            -- freq_adj = P + I  where P = -(offset >> KP_SHIFT)
            --                         I accumulates -(offset >> KI_SHIFT)
            -- ----------------------------------------------------------------
            v_p_term    := -shift_right(v_total_offset, KP_SHIFT);
            v_new_integ := r_integrator - shift_right(v_total_offset, KI_SHIFT);
            r_integrator <= v_new_integ;
            v_freq_sum  := v_p_term + v_new_integ;

            -- Saturate to signed 32-bit range before assigning
            if v_freq_sum > to_signed( 2147483647, 64) then
              r_freq_adj <= to_signed( 2147483647, 32);
            elsif v_freq_sum < to_signed(-2147483648, 64) then
              r_freq_adj <= to_signed(-2147483648, 32);
            else
              r_freq_adj <= v_freq_sum(31 downto 0);
            end if;

            -- Locked detection: 8 consecutive sync periods within 100 ns
            if v_total_offset > -C_LOCK_THRESH and
               v_total_offset <  C_LOCK_THRESH then
              if r_locked_count < 15 then
                r_locked_count <= r_locked_count + 1;
              end if;
              if r_locked_count >= 7 then
                r_locked <= '1';
              end if;
            else
              r_locked_count <= (others => '0');
              r_locked       <= '0';
            end if;
          end if;

        end if;  -- r_sync_new and r_pdelay_latched
      end if;
    end if;
  end process proc_servo;

  -- ===========================================================================
  -- proc_master_sync : ClockMasterSync  (IEEE 802.1AS-2020 Section 10.2.8)
  --
  -- Generates one-cycle trigger pulses for the master-facing port controller
  -- at the configured syncInterval and announceInterval rates.
  --
  -- Triggers are suppressed until the servo has converged (r_locked = '1'),
  -- ensuring the endpoint receives only time-synchronized Sync messages.
  -- ===========================================================================
  proc_master_sync : process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        r_sync_ctr  <= (others => '0');
        r_annc_ctr  <= (others => '0');
        r_sync_trig <= '0';
        r_annc_trig <= '0';
      else
        r_sync_trig <= '0';  -- default: pulse low
        r_annc_trig <= '0';

        -- Sync interval counter
        if r_sync_ctr = to_unsigned(C_SYNC_INTERVAL - 1, 31) then
          r_sync_ctr <= (others => '0');
          if r_locked = '1' then
            r_sync_trig <= '1';
          end if;
        else
          r_sync_ctr <= r_sync_ctr + 1;
        end if;

        -- Announce interval counter
        if r_annc_ctr = to_unsigned(C_ANNC_INTERVAL - 1, 31) then
          r_annc_ctr <= (others => '0');
          if r_locked = '1' then
            r_annc_trig <= '1';
          end if;
        else
          r_annc_ctr <= r_annc_ctr + 1;
        end if;

      end if;
    end if;
  end process proc_master_sync;

end architecture rtl;
