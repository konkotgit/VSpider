-- --------------------------------------------------------------------
-- VSpider universal firmware
-- ZX Spectrum Pentagon with 512KB RAM
-- Divmm and ZController
-- (c) 2026 Andy Karpov
-- --------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity vspider_top is
port(
    -- Clock
    CLK14               : in std_logic;

    -- CPU signals
    CLK_CPU             : out std_logic := '1';
    N_RESET             : in std_logic;
    N_INT               : out std_logic := '1';
    N_RD                : in std_logic;
    N_WR                : in std_logic;
    N_IORQ              : in std_logic;
    N_MREQ              : in std_logic;
    N_M1                : in std_logic;
    A                   : in std_logic_vector(15 downto 0);
    D                   : inout std_logic_vector(7 downto 0) := "ZZZZZZZZ";
    N_NMI               : out std_logic := 'Z';
    
    -- RAM 
    MA                  : out std_logic_vector(18 downto 0);
    MD                  : inout std_logic_vector(7 downto 0) := "ZZZZZZZZ";
    N_MRD               : out std_logic := '1';
    N_MWR               : out std_logic := '1';
    
    -- ROM
    N_ROMCS             : out std_logic := '1';
    ROM_A14             : out std_logic := '0';
    ROM_A15             : out std_logic := '0';
    ROM_SW              : out std_logic := '0'; -- ROM A16
    
    -- ZX BUS signals
    BUS_N_IORQGE        : in std_logic  := '0';
    BUS_N_ROMCS         : in std_logic  := '0';
    CLK_BUS             : out std_logic := '1';

    -- Video
    VIDEO_CSYNC         : out std_logic;
    VIDEO_R             : out std_logic := '0';
    VIDEO_G             : out std_logic := '0';
    VIDEO_B             : out std_logic := '0';
    VIDEO_I             : out std_logic := '0';

    -- Interfaces 
    TAPE_IN             : in std_logic;
    TAPE_OUT            : out std_logic := '1';
    BEEPER              : out std_logic := '1';

    -- AY
    CLK_AY              : out std_logic;
    AY_BC1              : out std_logic;
    AY_BDIR             : out std_logic;
    AY_A8_1             : out std_logic := '0'; 
    AY_A8_2             : out std_logic := '1'; 

    -- SD card
    SD_CLK              : out std_logic := '0';
    SD_DI               : out std_logic;
    SD_DO               : in std_logic;
    SD_N_CS             : out std_logic := '1';
    
    -- Keyboard
    KB                  : in std_logic_vector(4 downto 0) := "11111";

    -- Config switch
    SW                  : in std_logic_vector(2 downto 0) := "111";

    -- kempston joy port
    KEMPSTON_CS_N       : out std_logic := '1';

    -- something special on the ZX Edge slot
    DRD                 : out std_logic := '0'; -- Y
    DWR                 : out std_logic := '0'; -- U
    MTR                 : out std_logic := '0'; -- V

    -- Magic button
    BTN_NMI             : in std_logic := '1'
);
end vspider_top;

architecture rtl of vspider_top is

    signal clk_7        : std_logic := '0';
    signal clkcpu       : std_logic := '1';
    signal attr_r       : std_logic_vector(7 downto 0);
    signal rgb          : std_logic_vector(2 downto 0);
    signal i            : std_logic;
    signal vid_a        : std_logic_vector(13 downto 0);
    signal hcnt0        : std_logic;
    signal hcnt1        : std_logic;    
    signal border_attr  : std_logic_vector(2 downto 0) := "000";
    signal port_7ffd    : std_logic_vector(7 downto 0); -- D0-D2 - RAM page from address #C000
                                                        -- D3 - video RAM page: 0 - bank5, 1 - bank7 
                                                        -- D4 - ROM page A14: 0 - basic 128, 1 - basic48
                                                        -- D5 - 48k RAM lock, 1 - locked, 0 - extended memory enabled
                                                        -- D6 - not used
                                                        -- D7 - not used
    signal port_dffd    : std_logic_vector(7 downto 0);
    signal fd_port      : std_logic;
    signal fd_sel       : std_logic;
                                                                      
    signal ram_do       : std_logic_vector(7 downto 0);
    signal ram_oe_n     : std_logic := '1';
    
    signal bdir         : std_logic;
    signal bc1          : std_logic;
	 signal ssg          : std_logic;
        
    signal vbus_mode    : std_logic := '0';
    signal vid_rd       : std_logic := '0';
    
    signal hsync        : std_logic := '1';
    signal vsync        : std_logic := '1';

    signal sound_out    : std_logic := '0';
    signal mic          : std_logic := '0';
    
    signal port_read    : std_logic := '0';
    signal port_write   : std_logic := '0';
    
    signal trdos         : std_logic :='0'; 
	 
	-- Z-Controller
	signal zc_do_bus		: std_logic_vector(7 downto 0);
	signal zc_spi_start	: std_logic;
	signal zc_wr_en		: std_logic;
	signal port77_wr		: std_logic;

	signal zc_cs_n			: std_logic;
	signal zc_sclk			: std_logic;
	signal zc_mosi			: std_logic;
	signal zc_miso			: std_logic;

	--- DivMMC
	signal divmmc_en		: std_logic;
	signal automap			: std_logic;
	signal port_e3_reg   : std_logic_vector(7 downto 0);
	signal mapterm 		: std_logic;
	signal map3DXX 		: std_logic; 
	signal map1F00 		: std_logic;
	signal mapcond 		: std_logic;
	signal divmmc_mode : std_logic;
	--signal divmmc_en   : std_logic;
	signal internal_io_en : std_logic;
begin

	BEEPER <= sound_out;

	N_NMI <= '0' when BTN_NMI = '0' else 'Z';

	 
	-- SW(0) = wybór trybu pracy (DivMMC vs ZController)
	divmmc_mode <= SW(0);

	-- SW(2) = enable/disable DivMMC
	divmmc_en <= divmmc_mode and SW(2);

	internal_io_en <= '1' when
		divmmc_mode = '0' or
		divmmc_en   = '1'
	else '0';
			
	-- SD
	SD_N_CS	<= zc_cs_n;
	SD_CLK 	<= zc_sclk;
	SD_DI 	<= zc_mosi;	
	 
	 -- TurboSound
	process(CLK14, N_RESET)
	begin
		if (N_RESET = '0') then
			ssg <= '0';
		elsif (CLK14'event and CLK14 = '1') then
			if (D(7 downto 1) = "1111111" and bdir = '1' and bc1 = '1') then
				ssg <= D(0);
			end if;
		end if;
	end process;	 

	bdir	<= '1' when (N_M1 = '1' and N_IORQ = '0' and N_WR = '0'  and A(15) = '1' and A(1) = '0') else '0';
	bc1	<= '1' when (N_M1 = '1' and N_IORQ = '0' and A(15) = '1' and A(14) = '1' and A(1) = '0') else '0';	 
	AY_BC1 <= bc1;
	AY_BDIR <= bdir;
	AY_A8_1 <= ssg;
	AY_A8_2 <= not(ssg);
	 
	-- kempston joy
	KEMPSTON_CS_N <= '0' when port_read = '1' and A(7 downto 0) = X"1F" and trdos = '0' else '1'; -- Joystick, port #1F
	
	-- CPU clock 
	process( N_RESET, clk14, clk_7, hcnt0 )
		begin
		if clk14'event and clk14 = '1' then
			if clk_7 = '1' then
				clkcpu <= hcnt0;
			end if;
		end if;
	end process;
    
	CLK_CPU <= clkcpu;
	CLK_BUS <= not(clkcpu);
	CLK_AY    <= hcnt1;
    
	TAPE_OUT <= mic;
    
	port_write <= '1' when N_IORQ = '0' and N_WR = '0' and N_M1 = '1' else '0'; -- and vbus_mode = '0' else '0';
	port_read <= '1' when N_IORQ = '0' and N_RD = '0' and N_M1 = '1' and BUS_N_IORQGE = '0' else '0';
    
    -- read ports by CPU
	D(7 downto 0) <= 
		ram_do when ram_oe_n = '0' else -- #memory
		'1' & TAPE_IN & '1' & kb(4 downto 0) when port_read = '1' and A(0) = '0' else -- #FE - keyboard 
		zc_do_bus when internal_io_en = '1' and port_read = '1' and (A(7 downto 0) = x"57" or (A(7 downto 0) = x"EB" and divmmc_en = '1')) else -- ZC / DivMMC
		"11111100" when internal_io_en = '1' and port_read = '1' and A(7 downto 0) = x"77" else -- ZC Status port
		port_7ffd when port_read = '1' and A = x"7FFD" else -- #7FFD
		port_dffd when port_read = '1' and A = x"DFFD" else -- #DFFD
		attr_r when port_read = '1' and A(7 downto 0) = x"FF" and trdos = '0' else -- #FF
		"ZZZZZZZZ";
	
    -- clocks
	process (clk14)
		begin 
			if (clk14'event and clk14 = '1') then 
				clk_7 <= not(clk_7);
			end if;
	end process;
	 
	-- #FD port correction
	-- IN A, (#FD) - read a value from a hardware port 
	-- OUT (#FD), A - writes the value of the second operand into the port given by the first operand.
	fd_sel <= '0' when D(7 downto 4) = "1101" and D(2 downto 0) = "011" else '1'; 
	process(fd_sel, N_RESET, N_M1)
		begin
			if N_RESET='0' then
				fd_port <= '1';
			elsif rising_edge(N_M1) then 
				fd_port <= fd_sel;
		end if;
	end process;
    
	-- ports, write by CPU
	process( clk14, clk_7, N_RESET, A, D, port_write, port_7ffd, N_M1, N_MREQ )
	begin
		if N_RESET = '0' then
			port_7ffd <= "00000000";
			port_dffd <= "00000000";
			sound_out <= '0';
			port_e3_reg(5 downto 0) <= (others => '0');
			port_e3_reg(7) <= '0';
		elsif clk14'event and clk14 = '1' then 
			if port_write = '1' then
				-- xxE3
				if (A(7 downto 0) = X"E3" and divmmc_en = '1') then	
					port_e3_reg <= D(7) & (port_e3_reg(6) or D(6)) & D(5 downto 0);
				end if;					
				-- port #FD  
				if A(15)='0' and A(1) = '0' and port_7ffd(5) = '0' then -- short decoding #FD                    
					port_7ffd <= D;
				end if;
				-- port #DFFD
				if A = x"DFFD" and fd_port = '1' then
					port_dffd <= D;
				end if;
				-- port #FE
				if A(0) = '0' then
					border_attr <= D(2 downto 0); -- border attr
					mic <= D(3); -- MIC
					sound_out <= D(4); -- BEEPER
				end if;
			end if;
		end if;
	end process;

	-- Z-controller + DIVMMC spi 
	zc_spi_start <= '1' when (A(7 downto 0) = X"57" or (A(7 downto 0) = X"EB" and divmmc_en = '1')) and N_IORQ='0' and N_M1='1' else '0';
	zc_wr_en <= '1' when (A(7 downto 0) = X"57" or (A(7 downto 0) = X"EB" and divmmc_en = '1')) and N_IORQ='0' and N_M1='1' and N_WR='0' else '0';
	port77_wr <= '1' when (A(7 downto 0) = X"77" or (A(7 downto 0) = X"E7" and divmmc_en = '1')) and N_IORQ='0' and N_M1='1' and N_WR='0' else '0';

	process (port77_wr, N_RESET, CLK14)
	begin
		if N_RESET='0' then
			zc_cs_n <= '1';
		elsif CLK14'event and CLK14='1' then
			--- DIVMMC uses 0 bit to control zc_cs_n, instead of 1 bit ZController. 
			--- Lets check port number and select correct bit
			if port77_wr='1' then
				if A(7 downto 0) = X"E7" then
					zc_cs_n <= D(0);
				else
					zc_cs_n <= D(1);
				end if;
			end if;
		end if;
	end process;

	U_ZC_SPI: entity work.zc_spi     -- SD
	port map(
		DI				=> D,
		START			=> zc_spi_start,
		WR_EN			=> zc_wr_en,
		CLC     		=> CLK14,
		MISO    		=> SD_DO,
		DO				=> zc_do_bus,
		SCK     		=> zc_sclk,
		MOSI    		=> zc_mosi
	);
	
	------------------------ divmmc-----------------------------
	-- Engineer:   Mario Prato

	process (N_RESET, divmmc_en, A)
	begin
		if N_RESET = '0' or divmmc_en = '0' then 
			mapterm <= '0';
			map3DXX <= '0';
			map1F00 <= '1';
		else
			 if A(15 downto 0) = x"0000"   or 
				A(15 downto 0) = x"0008"   or 
				A(15 downto 0) = x"0038"   or 
				A(15 downto 0) = x"0066"   or 
				A(15 downto 0) = x"04c6"   or 
				A(15 downto 0) = x"0562" then 
					mapterm <= '1';
			else 
				mapterm <= '0';
			end if;	

			-- mappa 3D00 - 3DFF
			if A(15 downto 8) = "00111101" then 
				map3DXX <= '1'; 
			else 
				map3DXX <= '0';
			end if; 

			-- 1ff8 - 1fff
			if A(15 downto 3) =   "0001111111111" then 
				map1F00 <= '0';
			else 
				map1F00 <= '1';
			end if; 
		end if;
	end process;

	process(N_RESET, divmmc_en, N_MREQ, N_M1, mapcond, mapterm, map3DXX, map1F00, automap)
	begin
		if N_RESET = '0' or divmmc_en = '0' then 
			mapcond <= '0';
			automap <= '0';
		elsif falling_edge(N_MREQ) then
				if N_M1 = '0' then
					 mapcond <= (mapterm or map3DXX or (mapcond and map1F00)) and divmmc_en;
					 automap <= (mapcond or map3DXX) and divmmc_en;
			  end if;
		end if;	  
	end process; 
    
    -- trdos flag (not in divmmc mode)
	  process(clk14, N_RESET, N_M1, N_MREQ)
	  begin 
			if N_RESET = '0' then 
				 if (divmmc_mode = '0') then 
					  trdos <= '1'; -- 1 - boot into service rom, 0 - boot into 128 menu
				 else 
					  trdos <= '0';
				 end if;
			elsif clk14'event and clk14 = '1' then 
				 if divmmc_en = '0' and N_M1 = '0' and N_MREQ = '0' and A(15 downto 8) = X"3D" and port_7ffd(4) = '1' then 
					  trdos <= '1';
				 elsif divmmc_en = '0' and N_M1 = '0' and N_MREQ = '0' and A(15 downto 14) /= "00" then 
					  trdos <= '0'; 
				 end if;
			end if;
	  end process;

    -- memory manager
    U1: entity work.memory 
    port map ( 
        CLK14 => CLK14,
        CLK7  => CLK_7,
        HCNT0 => hcnt0,        
        BUS_N_ROMCS => BUS_N_ROMCS,
        
        -- cpu signals
        A => A,
        D => D,
        N_MREQ => N_MREQ,
        N_IORQ => N_IORQ,
        N_WR => N_WR,
        N_RD => N_RD,
        N_M1 => N_M1,

        -- ram 
        MA => MA,
        MD => MD,
        N_MRD => N_MRD,
        N_MWR => N_MWR,
        
        -- ram out to cpu
        DO => ram_do,
        N_OE => ram_oe_n,
        
        -- ram pages
        RAM_BANK => port_7ffd(2 downto 0),
		  RAM_EXT => port_dffd(1 downto 0),

        -- DIVMMC signals
        DIVMMC_EN => divmmc_en,
        AUTOMAP   => automap,
        REG_E3    => port_e3_reg,

        -- video
        VA => vid_a,
        VID_PAGE => port_7ffd(3),

        -- video bus control signals
        VBUS_MODE_O => vbus_mode, -- video bus mode: 0 - ram, 1 - vram
        VID_RD_O => vid_rd, -- read bitmap or attribute from video memory
        
        -- TRDOS 
        TRDOS => trdos,
        
        -- rom
        ROM_BANK => port_7ffd(4),
        ROM_A14 => ROM_A14,
        ROM_A15 => ROM_A15,
        N_ROMCS => N_ROMCS,     
        ROM_SW  => ROM_SW,
        TEST    => not SW(1),
		  DIVMMC_MODE => divmmc_mode
    );
    
    -- video module
    U5: entity work.video 
    port map (
        CLK => CLK14,
        ENA7 => CLK_7,
        BORDER => border_attr,
        DI => MD,
        INT => N_INT,
        ATTR_O => attr_r, 
        A => vid_a,
        BLANK => open,
        RGB => rgb,
        I => i,
        HSYNC => hsync,
        VSYNC => vsync,
        VBUS_MODE => vbus_mode,
        VID_RD => vid_rd,
        HCNT0 => hcnt0,
        HCNT1 => hcnt1
    );
    
    VIDEO_R <= rgb(2);
    VIDEO_G <= rgb(1);
    VIDEO_B <= rgb(0);
    VIDEO_I <= i;
    VIDEO_CSYNC <= not (vsync xor hsync);
    
end; 