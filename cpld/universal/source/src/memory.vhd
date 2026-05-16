-- --------------------------------------------------------------------
-- VSpider universal firmware
-- ZX Spectrum Pentagon with 512KB RAM
-- Divmm and ZController
-- (c) 2026 Andy Karpov
-- --------------------------------------------------------------------
-- Handles:
--   - ZX Spectrum 128k / Pentagon RAM paging (up to 512kB via RAM_EXT)
--   - ROM bank selection (GLUK / ESXDOS / DiagROM / classic basics)
--   - DivMMC memory mapping (ESXDOS ROM + 128kB scratch RAM)
--   - Video DMA bus arbitration (CPU stalled during pixel/attr fetch)
-- --------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity memory is
port (
    CLK14              : in std_logic;          -- 14 MHz master clock
    CLK7               : in std_logic;          -- 7 MHz (CLK14 / 2)
    HCNT0              : in std_logic;          -- horizontal counter LSB (video timing)
    BUS_N_ROMCS        : in std_logic;          -- '0' = expansion bus not blocking ROM

    -- Z80 CPU bus
    A                  : in std_logic_vector(15 downto 0);
    D                  : in std_logic_vector(7 downto 0);
    N_MREQ             : in std_logic;
    N_IORQ             : in std_logic;
    N_WR               : in std_logic;
    N_RD               : in std_logic;
    N_M1               : in std_logic;

    -- RAM read data back to CPU (latched from MD)
    DO                 : out std_logic_vector(7 downto 0);
    N_OE               : out std_logic;         -- '0' = drive DO onto CPU data bus

    -- SRAM interface
    MA                 : out std_logic_vector(18 downto 0);
    MD                 : inout std_logic_vector(7 downto 0);
    N_MRD              : out std_logic;
    N_MWR              : out std_logic;

    -- 128k paging
    RAM_BANK           : in std_logic_vector(2 downto 0); -- from port_7ffd[2:0]
    RAM_EXT            : in std_logic_vector(1 downto 0) := "00"; -- from port_dffd[1:0]

    -- DivMMC signals
    DIVMMC_EN          : in std_logic;          -- DivMMC hardware enabled
    AUTOMAP            : in std_logic;          -- DivMMC automap active
    REG_E3             : in std_logic_vector(7 downto 0); -- DivMMC port #E3 register
    ROM_SW             : out std_logic;         -- ROM A16 (bank select bit 2)
    TEST               : in std_logic;          -- '1' = activate DiagROM

    -- TR-DOS ROM flag (ZController mode)
    TRDOS              : in std_logic;

    -- Video DMA
    VA                 : in std_logic_vector(13 downto 0); -- video address from ULA
    VID_PAGE           : in std_logic := '0';  -- video bank: '0'=bank5, '1'=bank7

    VBUS_MODE_O        : out std_logic;         -- '1' = video DMA owns bus
    VID_RD_O           : out std_logic;         -- alternates bitmap / attribute fetch

    -- ROM bank
    ROM_BANK           : in std_logic := '0';  -- from port_7ffd[4]: 0=128 BASIC, 1=48 BASIC
    ROM_A14            : out std_logic;
    ROM_A15            : out std_logic;
    N_ROMCS            : out std_logic;

    DIVMMC_MODE        : in std_logic           -- '0'=ZController, '1'=DivMMC
);
end memory;

architecture RTL of memory is

    -- RAM read latch (captures MD during CPU cycle)
    signal buf_md      : std_logic_vector(7 downto 0) := "11111111";
    signal is_buf_wr   : std_logic := '0'; -- falling edge latches MD → buf_md

    -- Address decode
    signal is_rom      : std_logic := '0'; -- CPU addressing 0x0000-0x3FFF
    signal is_ram      : std_logic := '0'; -- CPU addressing RAM (not ROM)

    -- DivMMC memory regions
    -- is_romDIVMMC: ESXDOS ROM mapped to 0x0000-0x1FFF (when automap or CONMEM active)
    -- is_ramDIVMMC: DivMMC scratch RAM mapped to 0x2000-0x3FFF
    signal is_romDIVMMC: std_logic := '0';
    signal is_ramDIVMMC: std_logic := '0';

    -- Selected ROM and RAM page numbers
    signal rom_page    : std_logic_vector(2 downto 0) := "000";
    signal ram_page    : std_logic_vector(4 downto 0) := "00000";

    -- Video DMA bus arbitration
    signal vbus_req    : std_logic := '1'; -- '0' = CPU needs the bus
    signal vbus_mode   : std_logic := '1'; -- '1' = video DMA cycle
    signal vbus_rdy    : std_logic := '1'; -- '1' = video DMA slot available
    signal vid_rd      : std_logic := '0'; -- alternates: '0'=bitmap, '1'=attribute
    signal vbus_ack    : std_logic := '1';

begin

    -- ----------------------------------------------------------------
    -- DivMMC memory region decode
    -- ESXDOS ROM covers 0x0000-0x1FFF (lower 8kB of ROM window).
    -- DivMMC scratch RAM covers 0x2000-0x3FFF (upper 8kB of ROM window).
    -- Mapping is active when automap is set OR CONMEM bit (REG_E3[7]) is set.
    -- ----------------------------------------------------------------
    is_romDIVMMC <= '1' when DIVMMC_EN = '1' and N_MREQ = '0'
                         and (AUTOMAP = '1' or REG_E3(7) = '1')
                         and A(15 downto 13) = "000" else '0';

    is_ramDIVMMC <= '1' when DIVMMC_EN = '1' and N_MREQ = '0'
                         and (AUTOMAP = '1' or REG_E3(7) = '1')
                         and A(15 downto 13) = "001" else '0';

    -- Standard Spectrum memory decode
    is_rom <= '1' when N_MREQ = '0' and A(15 downto 14) = "00" else '0';
    is_ram <= '1' when N_MREQ = '0' and is_rom = '0' else '0';

    -- ----------------------------------------------------------------
    -- ROM bank selection
    -- ROM layout (3-bit page index → flash/EPROM address A16:A14):
    --   000 - GLUK reset service ROM
    --   001 - TR-DOS (boot ROM for ZController mode)
    --   010 - 128k BASIC (Pentagon version)
    --   011 - 48k  BASIC (Pentagon version)
    --   100 - ESXDOS (DivMMC mode)
    --   101 - DiagROM (activated by TEST input / SW(1)='0')
    --   110 - 128k BASIC (classic Spectrum)
    --   111 - 48k  BASIC (classic Spectrum)
    -- ----------------------------------------------------------------
    rom_page <=
        "101"              when TEST = '1'          else -- DiagROM overrides everything
        '0' & (not TRDOS) & ROM_BANK
                           when DIVMMC_MODE = '0'   else -- ZC mode: GLUK/TRDOS/128/48
        "100"              when is_romDIVMMC = '1'  else -- DivMMC automap: ESXDOS
        "11" & ROM_BANK;                                 -- DivMMC normal: classic 128/48

    ROM_A14 <= rom_page(0);
    ROM_A15 <= rom_page(1);
    ROM_SW  <= rom_page(2);

    -- Assert N_ROMCS when CPU is reading from the ROM region and no
    -- expansion device is blocking it (BUS_N_ROMCS='0' = not blocked).
    N_ROMCS <= '0' when (is_rom = '1' or is_romDIVMMC = '1')
                    and is_ram = '0' and is_ramDIVMMC = '0'
                    and N_RD = '0' and BUS_N_ROMCS = '0'
               else '1';

    -- ----------------------------------------------------------------
    -- Video DMA bus arbitration
    -- vbus_req='0' when CPU is actively using the bus (MREQ or IORQ with RD/WR).
    -- vbus_rdy='0' indicates a video DMA slot is available (CLK7='0' or HCNT0='0').
    -- vbus_mode: '1'=video owns bus, '0'=CPU owns bus.
    -- ----------------------------------------------------------------
    vbus_req <= '0' when (N_MREQ = '0' or N_IORQ = '0')
                     and (N_WR = '0' or N_RD = '0') else '1';
    vbus_rdy <= '0' when CLK7 = '0' or HCNT0 = '0' else '1';

    VBUS_MODE_O <= vbus_mode;
    VID_RD_O    <= vid_rd;

    -- SRAM read enable:
    --   - During video DMA: when vbus_rdy slot is open
    --   - During CPU read: when CPU is reading from RAM
    N_MRD <= '0' when (vbus_mode = '1' and vbus_rdy = '0')
                  or  (vbus_mode = '0' and N_RD = '0' and N_MREQ = '0'
                       and (is_ram = '1' or is_ramDIVMMC = '1'))
             else '1';

    -- SRAM write enable: CPU write to RAM, gated to first half of CPU cycle (HCNT0='0')
    N_MWR <= '0' when vbus_mode = '0'
                  and (is_ram = '1' or is_ramDIVMMC = '1')
                  and N_WR = '0' and HCNT0 = '0'
             else '1';

    -- Latch MD into buf_md on falling edge of is_buf_wr (HCNT0 going low in CPU mode).
    -- This captures the SRAM output before the address changes.
    is_buf_wr <= '1' when vbus_mode = '0' and HCNT0 = '0' else '0';

    DO   <= buf_md;
    N_OE <= '0' when (is_ram = '1' or is_ramDIVMMC = '1') and N_RD = '0' else '1';

    -- ----------------------------------------------------------------
    -- RAM page mapping
    -- Spectrum memory map:
    --   0x0000-0x3FFF : ROM (or DivMMC ROM/RAM when mapped)
    --   0x4000-0x7FFF : fixed bank 5 (video RAM)
    --   0x8000-0xBFFF : fixed bank 2
    --   0xC000-0xFFFF : paged bank (RAM_BANK + RAM_EXT extension)
    --
    -- ram_page is a 5-bit SRAM page number (each page = 16kB):
    --   MA[18:14] selects the 16kB page
    --   MA[13:0]  selects the byte within the page
    -- ----------------------------------------------------------------

    ram_page <=
        "00" & RAM_BANK(2 downto 0)     when is_ramDIVMMC = '1'          else -- 0x2000 DivMMC scratch RAM page
        "00" & "000"                    when A(15) = '0' and A(14) = '0' else -- 0x0000: bank 0 (ROM window)
        "00" & "101"                    when A(15) = '0' and A(14) = '1' else -- 0x4000: bank 5 (fixed)
        "00" & "010"                    when A(15) = '1' and A(14) = '0' else -- 0x8000: bank 2 (fixed)
        RAM_EXT & RAM_BANK(2 downto 0);                                        -- 0xC000: paged bank

    -- ----------------------------------------------------------------
    -- SRAM address (MA) generation
    --
    -- MA[13:0]: byte address within 16kB page
    --   - DivMMC RAM: REG_E3[0] extends the page address (bit 13 override)
    --   - Spectrum CPU: direct from A[13:0]
    --   - Video DMA: from ULA video address VA[13:0]
    --
    -- MA[18:14]: 16kB page select
    --   - DivMMC RAM region: placed at SRAM offset 0x18000 (pages 12+)
    --     REG_E3[3:1] selects which of 8 DivMMC pages (128kB total)
    --   - Spectrum CPU: from ram_page
    --   - Video DMA: bank 5 (VID_PAGE='0') or bank 7 (VID_PAGE='1')
    -- ----------------------------------------------------------------
    MA(13 downto 0) <=
        REG_E3(0) & A(12 downto 0) when vbus_mode = '0' and is_ramDIVMMC = '1' else
        A(13 downto 0)             when vbus_mode = '0'                         else
        VA;                         -- video DMA

    MA(18 downto 14) <=
        "10" & REG_E3(3 downto 1)  when is_ramDIVMMC = '1' and vbus_mode = '0' else
        ram_page(4 downto 0)        when vbus_mode = '0'                         else
        "001" & VID_PAGE & '1'      when vbus_mode = '1'                         else
        "00000";

    -- ----------------------------------------------------------------
    -- SRAM data bus driver
    -- Drive MD from CPU data bus during write cycles only.
    -- ----------------------------------------------------------------
    MD <= D when vbus_mode = '0'
               and (is_ram = '1' or is_ramDIVMMC = '1' or (N_IORQ = '0' and N_M1 = '1'))
               and N_WR = '0'
          else (others => 'Z');

    -- ----------------------------------------------------------------
    -- RAM read latch
    -- Captures MD on the falling edge of is_buf_wr (end of SRAM read setup).
    -- Using falling-edge sensitivity on is_buf_wr creates a transparent latch;
    -- synthesis tools may warn — this is intentional for timing closure.
    -- ----------------------------------------------------------------
    process(is_buf_wr)
    begin
        if falling_edge(is_buf_wr) then
            buf_md <= MD;
        end if;
    end process;

    -- ----------------------------------------------------------------
    -- Video DMA bus arbitration process
    -- Runs on every rising edge of CLK14 at the HCNT0='1'/CLK7='0' boundary.
    -- If the CPU is idle (vbus_req='1'), the video DMA takes the bus;
    -- otherwise the CPU cycle completes and DMA is deferred.
    -- vid_rd toggles each DMA cycle to alternate bitmap/attribute fetches.
    -- ----------------------------------------------------------------
    process(CLK14)
    begin
        if rising_edge(CLK14) then
            if HCNT0 = '1' and CLK7 = '0' then
                if vbus_req = '0' and vbus_ack = '1' then
                    -- CPU needs the bus; grant it
                    vbus_mode <= '0';
                else
                    -- Video DMA gets the bus; toggle bitmap/attr
                    vbus_mode <= '1';
                    vid_rd <= not vid_rd;
                end if;
                vbus_ack <= vbus_req;
            end if;
        end if;
    end process;

end RTL;