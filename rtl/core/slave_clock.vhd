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
  ---------------------------------------------------------------------------
  type t_poll_state is (
    P_IDLE,     -- waiting for poll interval to expire
    P_SEND_AR,  -- driving AXI AR channel
    P_WAIT_R,   -- waiting for AXI R channel response
    P_ADVANCE,  -- decide next read index or finish
    P_PROCESS,  -- decode latched words; pulse r_sync_new if new data
    P_OTHERS    -- mandatory catch-all per Rule N3
  );

  attribute FSM_ENCODING : string;

  ---------------------------------------------------------------------------
  -- AXI read register index constants
  ---------------------------------------------------------------------------
  constant C_N_READS              : natural := 15;

  constant C_IDX_PDELAY_STATUS    : natural :=  0;
  constant C_IDX_NRR              : natural :=  1;
  constant C_IDX_MPD_LO           : natural :=  2;
  constant C_IDX_MPD_MID          : natural :=  3;
  constant C_IDX_MPD_HI           : natural :=  4;
  constant C_IDX_SYNC_STATUS      : natural :=  5;
  constant C_IDX_SYNC_TS_SEC_LO   : natural :=  6;
  constant C_IDX_SYNC_TS_SEC_HI   : natural :=  7;
  constant C_IDX_SYNC_TS_NS       : natural :=  8;
  constant C_IDX_SYNC_TS_FRAC     : natural :=  9;
  constant C_IDX_ORIG_SEC_LO      : natural := 10;
  constant C_IDX_ORIG_SEC_HI      : natural := 11;
  constant C_IDX_ORIG_NS          : natural := 12;
  constant C_IDX_CF_LO            : natural := 13;
  constant C_IDX_CF_HI            : natural := 14;

  type t_offset_table is array(0 to C_N_READS-1) of natural;
  constant C_ADDR_OFFSETS : t_offset_table := (
    C_OFF_PDELAY_STATUS,       C_OFF_NEIGHBOUR_RATE_RATIO,
    C_OFF_MEAN_PATH_DELAY_LO,  C_OFF_MEAN_PATH_DELAY_MID, C_OFF_MEAN_PATH_DELAY_HI,
    C_OFF_SYNC_STATUS,
    C_OFF_SYNC_TS_SEC_LO,      C_OFF_SYNC_TS_SEC_HI,
    C_OFF_SYNC_TS_NS,          C_OFF_SYNC_TS_FRAC,
    C_OFF_PRECISE_ORIG_SEC_LO, C_OFF_PRECISE_ORIG_SEC_HI, C_OFF_PRECISE_ORIG_NS,
    C_OFF_CORR_FIELD_LO,       C_OFF_CORR_FIELD_HI
  );

  type t_mem_data_array is array(0 to C_N_READS-1) of
    std_logic_vector(AXI_DATA_WIDTH-1 downto 0);

  ---------------------------------------------------------------------------
  -- Derived constants
  ---------------------------------------------------------------------------
  constant C_GM_BASE : unsigned(AXI_ADDR_WIDTH-1 downto 0) :=
    resize(PORT_MEM_BASE, AXI_ADDR_WIDTH) +
    to_unsigned(GM_PORT_INDEX * C_PORT_MEM_SIZE, AXI_ADDR_WIDTH);

  -- LocalClock nominal increment: CLK_PERIOD_NS * 2^32
  -- Phase accumulator layout: [63:32] = integer ns, [31:0] = sub-ns fraction
  constant C_NOM_INC : unsigned(63 downto 0) :=
    to_unsigned(CLK_PERIOD_NS, 32) & to_unsigned(0, 32);

  constant C_POLL_INTERVAL : natural :=
    C_NS_PER_SEC * (2**SYNC_LOG_MSG_INTERVAL) / CLK_PERIOD_NS / 2;

  constant C_SYNC_INTERVAL : natural :=
    C_NS_PER_SEC * (2**SYNC_LOG_MSG_INTERVAL) / CLK_PERIOD_NS;

  constant C_ANNC_INTERVAL : natural :=
    C_NS_PER_SEC * (2**ANNC_LOG_MSG_INTERVAL) / CLK_PERIOD_NS;

  constant C_STEP_THRESH : signed(63 downto 0) :=
    to_signed(PHASE_STEP_THRESHOLD_NS * 65536, 64);

  constant C_LOCK_THRESH : signed(63 downto 0) :=
    to_signed(100 * 65536, 64);

  ---------------------------------------------------------------------------
  -- LocalClock registers  (proc_local_clock)
  ---------------------------------------------------------------------------
  signal r_phase_acc        : unsigned(63 downto 0);  -- [63:32]=ns, [31:0]=sub-ns
  signal r_seconds          : unsigned(47 downto 0);

  -- One-cycle phase-step request: driven by proc_servo, read by proc_local_clock
  signal r_phase_step_valid : std_logic;
  signal r_phase_step_ts    : t_extended_timestamp;

  -- Frequency adjustment from PI servo (2^-32 ns/cycle; ~0.029 ppb LSB at 125 MHz)
  signal r_freq_adj         : signed(31 downto 0);

  ---------------------------------------------------------------------------
  -- LocalClock combinational next-state (concurrent assignments)
  ---------------------------------------------------------------------------
  signal w_clk_inc     : unsigned(63 downto 0);  -- C_NOM_INC adjusted by r_freq_adj
  signal w_clk_next    : unsigned(63 downto 0);  -- r_phase_acc + w_clk_inc
  signal w_clk_sec_ovf : std_logic;              -- nanosecond field >= NS_PER_SEC

  ---------------------------------------------------------------------------
  -- AXI read master / poll FSM registers  (proc_poll_axi)
  ---------------------------------------------------------------------------
  signal r_poll_state       : t_poll_state;
  attribute FSM_ENCODING of r_poll_state : signal is "ONE_HOT";

  signal r_poll_ctr         : unsigned(30 downto 0);
  signal r_read_idx         : natural range 0 to C_N_READS;
  signal r_mem_data         : t_mem_data_array;
  signal r_ar_valid         : std_logic;
  signal r_ar_addr          : unsigned(AXI_ADDR_WIDTH-1 downto 0);

  -- Latched PDelay results
  signal r_pdelay_seq_prev  : unsigned(3 downto 0);
  signal r_nrr              : t_rate_ratio;
  signal r_mpd              : t_uscaled_ns;
  signal r_pdelay_latched   : std_logic;

  -- Latched Sync / Follow_Up results
  signal r_sync_seq_prev    : unsigned(3 downto 0);
  signal r_rx_ts            : t_extended_timestamp;
  signal r_precise_orig_ts  : t_timestamp;
  signal r_corr_field       : t_correction_field;

  -- One-cycle pulse to proc_servo (driven exclusively by proc_poll_axi)
  signal r_sync_new         : std_logic;

  ---------------------------------------------------------------------------
  -- Offset calculation combinational signals (concurrent assignments)
  -- All quantities in units of 2^-16 ns unless noted.
  ---------------------------------------------------------------------------
  signal w_local_sub    : unsigned(47 downto 0);  -- local sub-second component
  signal w_orig_sub     : unsigned(47 downto 0);  -- GM origin sub-second component
  signal w_sec_diff     : signed(48 downto 0);    -- local seconds - GM seconds
  signal w_sub_offset   : signed(63 downto 0);    -- offset before seconds correction

  -- Driven by proc_offset_comb (conditional on w_sec_diff)
  signal w_total_offset : signed(63 downto 0);    -- complete offsetFromMaster
  signal w_large_step   : std_logic;              -- |sec_diff| > 1; need big step

  -- Phase step target: GM time + corrections (combinational)
  signal w_step_ns_raw  : signed(63 downto 0);    -- target ns before overflow check
  signal w_step_sec     : unsigned(47 downto 0);  -- target seconds
  signal w_step_ns      : unsigned(31 downto 0);  -- target nanoseconds

  -- Asserted when a phase step should be issued instead of PI servo update
  signal w_need_step    : std_logic;

  ---------------------------------------------------------------------------
  -- PI servo combinational signals (concurrent assignments)
  ---------------------------------------------------------------------------
  signal w_p_term       : signed(63 downto 0);    -- proportional term
  signal w_new_integ    : signed(63 downto 0);    -- updated integrator value
  signal w_freq_sum     : signed(63 downto 0);    -- P + I (pre-saturation)
  signal w_freq_adj_sat : signed(31 downto 0);    -- saturated to 32-bit

  ---------------------------------------------------------------------------
  -- PI servo registers  (proc_servo)
  ---------------------------------------------------------------------------
  signal r_integrator   : signed(63 downto 0);
  signal r_offset       : t_offset_scaled_ns;
  signal r_offset_valid : std_logic;
  signal r_locked       : std_logic;
  signal r_locked_count : unsigned(3 downto 0);

  ---------------------------------------------------------------------------
  -- ClockMasterSync registers  (proc_master_sync)
  ---------------------------------------------------------------------------
  signal r_sync_ctr  : unsigned(30 downto 0);
  signal r_annc_ctr  : unsigned(30 downto 0);
  signal r_sync_trig : std_logic;
  signal r_annc_trig : std_logic;

begin

  -- =========================================================================
  -- Fixed AXI channel outputs
  -- =========================================================================
  m_axi_arid    <= (others => '0');
  m_axi_arlen   <= (others => '0');   -- single-beat
  m_axi_arsize  <= "010";             -- 4 bytes
  m_axi_arburst <= "01";              -- INCR
  m_axi_arvalid <= r_ar_valid;
  m_axi_araddr  <= std_logic_vector(r_ar_addr);
  m_axi_rready  <= '1';

  -- =========================================================================
  -- LocalClock output (combinational)
  -- =========================================================================
  local_time.seconds     <= r_seconds;
  local_time.nanoseconds <= r_phase_acc(63 downto 32);
  local_time.frac_ns     <= r_phase_acc(31 downto 16);  -- upper 16 bits of sub-ns

  -- =========================================================================
  -- Status / diagnostic outputs
  -- =========================================================================
  locked           <= r_locked;
  offset_valid     <= r_offset_valid;
  offset_scaled_ns <= r_offset;
  local_time_valid <= r_locked;
  sync_trigger     <= r_sync_trig;
  announce_trigger <= r_annc_trig;

  -- =========================================================================
  -- LocalClock next-state (concurrent combinational)
  -- Separating the combinational arithmetic from the clocked register keeps
  -- proc_local_clock a pure register with no embedded logic.
  -- =========================================================================
  w_clk_inc <= C_NOM_INC + resize(unsigned(r_freq_adj), 64)
                 when r_freq_adj >= 0 else
               C_NOM_INC - resize(unsigned(-r_freq_adj), 64);

  w_clk_next    <= r_phase_acc + w_clk_inc;
  w_clk_sec_ovf <= '1' when w_clk_next(63 downto 32) >= to_unsigned(C_NS_PER_SEC, 32)
                       else '0';

  -- =========================================================================
  -- Offset arithmetic (concurrent combinational)
  -- =========================================================================

  -- Sub-second components in 2^-16 ns units
  w_local_sub  <= f_sub_second_scaled(r_rx_ts);
  w_orig_sub   <= resize(r_precise_orig_ts.nanoseconds, 48) sll 16;

  -- Sub-second offset before seconds-field correction
  w_sub_offset <= signed(resize(w_local_sub, 64))
                - signed(resize(w_orig_sub, 64))
                - r_corr_field
                - signed(r_mpd(63 downto 0));

  -- Seconds difference (signed, covers boundary crossings)
  w_sec_diff <= signed(resize(r_rx_ts.seconds,           49)) -
                signed(resize(r_precise_orig_ts.seconds, 49));

  -- Phase step target: preciseOriginTimestamp + int_ns(correctionField)
  --                                           + int_ns(meanPathDelay)
  -- shift_right by 16 converts from 2^-16 ns to integer ns
  w_step_ns_raw <= signed(resize(r_precise_orig_ts.nanoseconds, 64))
                 + shift_right(r_corr_field, 16)
                 + signed(resize(shift_right(r_mpd, 16), 64));

  -- PI servo terms (always computed; gated by r_sync_new in proc_servo)
  w_p_term    <= -shift_right(w_total_offset, KP_SHIFT);
  w_new_integ <= r_integrator - shift_right(w_total_offset, KI_SHIFT);
  w_freq_sum  <= w_p_term + w_new_integ;

  w_freq_adj_sat <= to_signed( 2147483647, 32) when w_freq_sum > to_signed( 2147483647, 64) else
                    to_signed(-2147483648, 32) when w_freq_sum < to_signed(-2147483648, 64) else
                    w_freq_sum(31 downto 0);

  w_need_step <= '1' when (w_large_step    = '1'       or
                            w_total_offset > C_STEP_THRESH or
                            w_total_offset < -C_STEP_THRESH) else '0';

  -- =========================================================================
  -- proc_offset_comb : conditional offset and step-target logic
  -- Combinational process; no clocked state, no variables.
  -- =========================================================================
  proc_offset_comb : process(all)
  begin
    -- Total offset including seconds-field contribution
    w_large_step   <= '0';
    w_total_offset <= (others => '0');  -- default (overridden for |sec_diff| <= 1)

    if w_sec_diff = 0 then
      w_total_offset <= w_sub_offset;
    elsif w_sec_diff = 1 then
      w_total_offset <= resize(C_NS_PER_SEC_SCALED, 64) + w_sub_offset;
    elsif w_sec_diff = -1 then
      w_total_offset <= -resize(C_NS_PER_SEC_SCALED, 64) + w_sub_offset;
    else
      w_large_step <= '1';  -- |offset| > 1 s; proc_servo will issue a phase step
    end if;

    -- Phase step target: resolve nanosecond overflow/underflow
    if w_step_ns_raw >= to_signed(C_NS_PER_SEC, 64) then
      w_step_sec <= r_precise_orig_ts.seconds + 1;
      w_step_ns  <= unsigned(w_step_ns_raw(31 downto 0)) - to_unsigned(C_NS_PER_SEC, 32);
    elsif w_step_ns_raw < 0 then
      w_step_sec <= r_precise_orig_ts.seconds - 1;
      w_step_ns  <= unsigned(w_step_ns_raw(31 downto 0)) + to_unsigned(C_NS_PER_SEC, 32);
    else
      w_step_sec <= r_precise_orig_ts.seconds;
      w_step_ns  <= unsigned(w_step_ns_raw(31 downto 0));
    end if;
  end process proc_offset_comb;

  -- =========================================================================
  -- proc_local_clock : LocalClock  (IEEE 802.1AS-2020 Section 10.2.4)
  -- Pure register process; all combinational logic is in concurrent
  -- assignments above (w_clk_inc, w_clk_next, w_clk_sec_ovf).
  -- =========================================================================
  proc_local_clock : process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        r_phase_acc <= (others => '0');
        r_seconds   <= (others => '0');
      else
        if r_phase_step_valid = '1' then
          -- Phase step: load directly from servo-supplied target time.
          -- frac_ns becomes the MSBs of the sub-ns field; lower 16 bits zeroed.
          r_phase_acc <= r_phase_step_ts.nanoseconds &
                         r_phase_step_ts.frac_ns     &
                         to_unsigned(0, 16);
          r_seconds   <= r_phase_step_ts.seconds;
        elsif w_clk_sec_ovf = '1' then
          r_phase_acc <= (w_clk_next(63 downto 32) - to_unsigned(C_NS_PER_SEC, 32)) &
                          w_clk_next(31 downto 0);
          r_seconds   <= r_seconds + 1;
        else
          r_phase_acc <= w_clk_next;
        end if;
      end if;
    end if;
  end process proc_local_clock;

  -- =========================================================================
  -- proc_poll_axi : AXI read master + poll control
  --
  -- Polls the GM port's AXI memory region every C_POLL_INTERVAL cycles.
  -- Issues single-beat AXI4 Full reads (ARLEN = 0) for each of C_N_READS
  -- 32-bit registers, then decodes them in P_PROCESS.
  --
  -- New-data detection: 4-bit sequence counters are cached in
  -- r_pdelay_seq_prev / r_sync_seq_prev (initialised to x"F" so that any
  -- valid counter value triggers a first-poll update).
  --
  -- Sync register reads are skipped when sync_status shows no new data.
  -- =========================================================================
  proc_poll_axi : process(clk)
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
        r_sync_new <= '0';  -- default low; raised for one cycle in P_PROCESS

        case r_poll_state is

          when P_IDLE =>
            r_ar_valid <= '0';
            if r_poll_ctr = to_unsigned(C_POLL_INTERVAL - 1, 31) then
              r_poll_ctr   <= (others => '0');
              r_read_idx   <= 0;
              r_poll_state <= P_SEND_AR;
            else
              r_poll_ctr <= r_poll_ctr + 1;
            end if;

          when P_SEND_AR =>
            r_ar_valid <= '1';
            r_ar_addr  <= C_GM_BASE +
                          to_unsigned(C_ADDR_OFFSETS(r_read_idx), AXI_ADDR_WIDTH);
            if m_axi_arready = '1' then
              r_ar_valid   <= '0';
              r_poll_state <= P_WAIT_R;
            end if;

          when P_WAIT_R =>
            if m_axi_rvalid = '1' then
              r_mem_data(r_read_idx) <= m_axi_rdata;
              r_poll_state           <= P_ADVANCE;
            end if;

          when P_ADVANCE =>
            if r_read_idx = C_IDX_SYNC_STATUS then
              -- If sync data is fresh, continue reading; otherwise skip to P_PROCESS
              if r_mem_data(C_IDX_SYNC_STATUS)(0) = '1' and
                 unsigned(r_mem_data(C_IDX_SYNC_STATUS)(7 downto 4)) /= r_sync_seq_prev
              then
                r_read_idx   <= r_read_idx + 1;
                r_poll_state <= P_SEND_AR;
              else
                r_poll_state <= P_PROCESS;
              end if;
            elsif r_read_idx = C_N_READS - 1 then
              r_poll_state <= P_PROCESS;
            else
              r_read_idx   <= r_read_idx + 1;
              r_poll_state <= P_SEND_AR;
            end if;

          when P_PROCESS =>
            -- PDelay: latch if sequence counter changed
            if r_mem_data(C_IDX_PDELAY_STATUS)(0) = '1' and
               unsigned(r_mem_data(C_IDX_PDELAY_STATUS)(7 downto 4)) /= r_pdelay_seq_prev
            then
              r_nrr                     <= signed(r_mem_data(C_IDX_NRR));
              r_mpd(31 downto  0)       <= unsigned(r_mem_data(C_IDX_MPD_LO));
              r_mpd(63 downto 32)       <= unsigned(r_mem_data(C_IDX_MPD_MID));
              r_mpd(79 downto 64)       <= unsigned(r_mem_data(C_IDX_MPD_HI)(15 downto 0));
              r_pdelay_latched          <= '1';
              r_pdelay_seq_prev         <=
                unsigned(r_mem_data(C_IDX_PDELAY_STATUS)(7 downto 4));
            end if;

            -- Sync: latch and pulse r_sync_new if sequence counter changed
            if r_mem_data(C_IDX_SYNC_STATUS)(0) = '1' and
               unsigned(r_mem_data(C_IDX_SYNC_STATUS)(7 downto 4)) /= r_sync_seq_prev
            then
              r_rx_ts.seconds(31 downto  0) <=
                unsigned(r_mem_data(C_IDX_SYNC_TS_SEC_LO));
              r_rx_ts.seconds(47 downto 32) <=
                unsigned(r_mem_data(C_IDX_SYNC_TS_SEC_HI)(15 downto 0));
              r_rx_ts.nanoseconds <=
                unsigned(r_mem_data(C_IDX_SYNC_TS_NS));
              r_rx_ts.frac_ns <=
                unsigned(r_mem_data(C_IDX_SYNC_TS_FRAC)(15 downto 0));

              r_precise_orig_ts.seconds(31 downto  0) <=
                unsigned(r_mem_data(C_IDX_ORIG_SEC_LO));
              r_precise_orig_ts.seconds(47 downto 32) <=
                unsigned(r_mem_data(C_IDX_ORIG_SEC_HI)(15 downto 0));
              r_precise_orig_ts.nanoseconds <=
                unsigned(r_mem_data(C_IDX_ORIG_NS));

              r_corr_field(31 downto  0) <= signed(r_mem_data(C_IDX_CF_LO));
              r_corr_field(63 downto 32) <= signed(r_mem_data(C_IDX_CF_HI));

              r_sync_seq_prev <=
                unsigned(r_mem_data(C_IDX_SYNC_STATUS)(7 downto 4));
              r_sync_new <= '1';  -- one-cycle pulse consumed by proc_servo
            end if;

            r_poll_state <= P_IDLE;

          when P_OTHERS | others =>
            r_ar_valid   <= '0';
            r_poll_state <= P_IDLE;

        end case;
      end if;
    end if;
  end process proc_poll_axi;

  -- =========================================================================
  -- proc_servo : ClockSlaveSync  (IEEE 802.1AS-2020 Section 10.2.7)
  --
  -- Pure register process.  All arithmetic is pre-computed in concurrent
  -- signal assignments and proc_offset_comb above.
  --
  -- The offsetFromMaster calculation follows the normative specification in
  -- Section 10.2.7.2.  The PI servo algorithm (KP_SHIFT / KI_SHIFT) follows
  -- the guidance in Annex B (informative) of IEEE 802.1AS-2020; the standard
  -- does not mandate a specific servo implementation.
  --
  -- Triggered by r_sync_new (one-cycle pulse from proc_poll_axi).  Requires
  -- r_pdelay_latched = '1' to ensure meanPathDelay is valid first.
  --
  -- r_phase_step_valid is asserted for exactly one clock cycle (default '0'
  -- fires every cycle; the override to '1' only fires when both r_sync_new
  -- and w_need_step are asserted).
  -- =========================================================================
  proc_servo : process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        r_integrator       <= (others => '0');
        r_offset           <= (others => '0');
        r_offset_valid     <= '0';
        r_locked           <= '0';
        r_locked_count     <= (others => '0');
        r_freq_adj         <= (others => '0');
        r_phase_step_valid <= '0';
        r_phase_step_ts    <= C_EXTENDED_TIMESTAMP_ZERO;
      else
        r_phase_step_valid <= '0';  -- default: no phase step

        if r_sync_new = '1' and r_pdelay_latched = '1' then

          -- Simulation invariant: r_mpd upper 16 bits must be zero for
          -- realistic path delays (< 2^48 in 2^-16 ns units ~= 4 hours)
          assert r_mpd(79 downto 64) = x"0000"
            report "slave_clock: meanPathDelay upper 16 bits non-zero"
            severity warning;

          r_offset       <= w_total_offset;
          r_offset_valid <= '1';

          if w_need_step = '1' then
            -- Large offset or startup: one-shot phase correction.
            -- Integrator is reset to avoid an integrator-windup jump
            -- when normal servo operation resumes.
            r_phase_step_ts.seconds     <= w_step_sec;
            r_phase_step_ts.nanoseconds <= w_step_ns;
            r_phase_step_ts.frac_ns     <= (others => '0');
            r_phase_step_valid          <= '1';
            r_integrator                <= (others => '0');
          else
            -- Normal operation: update frequency via PI servo
            r_freq_adj   <= w_freq_adj_sat;
            r_integrator <= w_new_integ;

            -- Locked indicator: 8 consecutive sync periods within 100 ns
            if w_total_offset > -C_LOCK_THRESH and
               w_total_offset <  C_LOCK_THRESH then
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

        end if;
      end if;
    end if;
  end process proc_servo;

  -- =========================================================================
  -- proc_master_sync : ClockMasterSync  (IEEE 802.1AS-2020 Section 10.2.8)
  --
  -- Generates one-cycle trigger pulses for the master-facing port controller
  -- at syncInterval and announceInterval rates.
  -- Suppressed until r_locked = '1' so the endpoint receives only
  -- time-synchronized Sync messages.
  -- =========================================================================
  proc_master_sync : process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        r_sync_ctr  <= (others => '0');
        r_annc_ctr  <= (others => '0');
        r_sync_trig <= '0';
        r_annc_trig <= '0';
      else
        r_sync_trig <= '0';
        r_annc_trig <= '0';

        if r_sync_ctr = to_unsigned(C_SYNC_INTERVAL - 1, 31) then
          r_sync_ctr <= (others => '0');
          r_sync_trig <= r_locked;  -- suppress until converged
        else
          r_sync_ctr <= r_sync_ctr + 1;
        end if;

        if r_annc_ctr = to_unsigned(C_ANNC_INTERVAL - 1, 31) then
          r_annc_ctr <= (others => '0');
          r_annc_trig <= r_locked;
        else
          r_annc_ctr <= r_annc_ctr + 1;
        end if;

      end if;
    end if;
  end process proc_master_sync;

end architecture rtl;
