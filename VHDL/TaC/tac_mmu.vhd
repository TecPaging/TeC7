--
-- TeC7 VHDL Source Code
--    Tokuyama kousen Educational Computer Ver.7
--
-- Copyright (C) 2011-2022 by
--                      Dept. of Computer Science and Electronic Engineering,
--                      Tokuyama College of Technology, JAPAN
--
--   Free Software Foundation  GNU 
-- 
-- ()
-- 
--
--   
-- 
-- 
-- 
--
--

--
-- TaC/tac_mmu.vhd : TaC Memory Management Unit Source Code
--
-- 2022.08.25           : P_MR_MEM21
--                      : TLB12
-- 2022.03.21           : 
-- 2021.12.09           : 
-- 2019.12.19           : CPU
-- 2019.07.30           : 
-- 2019.01.22           : 
--

library IEEE;
use IEEE.std_logic_1164.ALL;
use IEEE.std_logic_unsigned.ALL;

entity TAC_MMU is
  Port ( P_CLK      : in  std_logic;
         P_RESET    : in  std_logic;
         P_EN       : in  std_logic;                     -- i/o enable
         P_IOR      : in  std_logic;                     -- i/o read
         P_IOW      : in  std_logic;                     -- i/o write

         P_LI       : in  std_logic;                     -- inst. fetch(exec)
         P_PR       : in  std_logic;                     -- Privilege mode
         P_WAIT     : out std_logic;                     -- Wait Request
         P_VIO_INT  : out std_logic;                     -- MemVio/BadAdr excp.
         P_TLB_INT  : out std_logic;                     -- TLB miss exception

         -- from cpu
         P_ADDR     : in  std_logic_vector(15 downto 0); -- Virtual address
         P_MR       : in  std_logic;                     -- Memory Request
         P_RW       : in  std_logic;                     -- read/write
         P_BT       : in  std_logic;                     -- byte access
         P_DIN      : in  std_logic_vector(15 downto 0); -- data from cpu
         P_DOUT     : out std_logic_vector(15 downto 0); -- data to cpu

         -- to memory
         P_ADDR_MEM : out std_logic_vector(15 downto 0); -- Physical address
         P_MR_MEM   : out std_logic;                     -- Memory Request
         P_RW_MEM   : out std_logic;                     -- read/write
         P_BT_MEM   : out std_logic;                     -- byte access
         P_BANK_MEM : out std_logic;                     -- ipl bank
         P_DOUT_MEM : out std_logic_vector(15 downto 0); -- to memory
         P_DIN_MEM  : in  std_logic_vector(15 downto 0)  -- from memory
       );
end TAC_MMU;

architecture Behavioral of TAC_MMU is
-- FF
signal mapPage : std_logic;                             -- activate mapping
signal mmuStat : std_logic_vector(2 downto 0);          -- mmu status

-- CPU
signal page    : std_logic_vector(7 downto 0);          -- page no
signal offs    : std_logic_vector(7 downto 0);          -- in page offset
signal memWrt  : std_logic;                             -- memory write
signal insFet  : std_logic;                             -- instruction fetch
signal bytAdr  : std_logic;                             -- byte addressing

-- TLB
-- 
--|<------ 8 ---->|<-- 5 -->|<-3->|<------ 8 ---->|
--+---------------+-+-+-+-+-+-----+---------------+
--|       PAGE    |V|*|*|R|D|R/W/X|      FRAME    |
--+---------------+-+-+-+-+-+-----+---------------+
-- 3 2 1 0 9 8 7 6 5 4 3 2 1 0 9 8 7 6 5 4 3 2 1 0
--PAGE:, V:Valid, *:, R:Reference, D:Dirty,
--R/W/X:Read/Write/eXecute, FRAME:
subtype TlbField is std_logic_vector(23 downto 0);
type TlbArray is array(0 to 7) of TlbField;             -- array of 24bit * 8

signal TLB     : TlbArray;                              -- TLB
signal entry   : std_logic_vector(11 downto 0);         -- target TLB entry
signal index   : std_logic_vector(3 downto 0);          -- index of TLB entry
signal tlbFull : std_logic;                             -- TLB full
signal empIdx  : std_logic_vector(2 downto 0);          -- index of empty entry
signal pageFlt : std_logic;                             -- detect page fault

-- 
signal tlbMiss : std_logic;                             -- TLB miss
signal memVio  : std_logic;                             -- Memory Violation
signal badAdr  : std_logic;                             -- Bad Address

-- i/o
signal enMmu   : std_logic;                             -- Enable MMU
signal fltPage : std_logic_vector(7 downto 0);          -- Page happend fault
signal fltRsn  : std_logic_vector(1 downto 0);          -- reason of fault
signal fltAdr  : std_logic_vector(15 downto 0);         -- address of fault
signal pageTbl : std_logic_vector(7 downto 0);          -- page table register

begin
  -- TLB
  P_WAIT <= '1' when (mmuStat="000" and P_MR) or
                     (mmuStat="001" and tlbMiss='1') or
                     (mmuStat="010") or
                     (mmuStat="011") or
                     (mmuStat="100") or
                     (mmuStat="101" and pageFlt='0')
                else '0';

  -- page_fault
  process(P_CLK, P_RESET)
  begin
    if (P_RESET='0') then
      pageFlt <= '0';
    elsif (P_CLK'event and P_CLK='1') then
      if(mmuStat="100") then
        pageFlt <= not P_DIN_MEM(15);  -- fetchentryV
      else
        pageFlt <= '0';
      end if;
    end if;
  end process;

  process(P_CLK, P_RESET)  --mmuStat
  begin
    if (P_RESET='0') then
      mmuStat <= "000";
    elsif (P_CLK'event and P_CLK='1') then
      if (mmuStat="000" and P_MR='1') then
        mmuStat <= "001";
      elsif (mmuStat="001") then
        if (tlbMiss='1') then
          mmuStat <= "010";
        else
          mmuStat <= "000";
        end if;
      elsif (mmuStat="010") then
        if (tlbFull='0') then
          mmuStat <= "100";
        else 
          mmuStat <= "011";
        end if;
      elsif (mmuStat="011") then
        mmuStat <= "100";
        --pageTbl[pNum] <= TLB[rnd]
      elsif (mmuStat="100") then
        mmuStat <= "101";
        -- TLB[aki] <= pNum & PageTable[pNum]
      else -- if (mmuStat="101") then
        if (pageFlt='1') then
          mmuStat <= "000";
        else
          mmuStat <= "001";
          -- PageTable.R <= 0
        end if;
      end if;
    end if;
  end process;

  process(P_CLK, P_RESET)  -- mapPage
  begin
    if (P_RESET='0') then
      mapPage <= '0';
    elsif (P_CLK'event and P_CLK='1') then
      if (mmuStat="000" and P_MR='1') then
        mapPage <= (not P_PR) and enMmu;
      else
        mapPage <= '0';
      end if;
    end if;
  end process;

  -- MMU
  -- (CPUTLB)
  process(P_CLK)
  begin
    if (P_CLK'event and P_CLK='1') then
      page    <= P_ADDR(15 downto 8);
      offs    <= P_ADDR(7  downto 0);
      memWrt  <= P_RW;
      insFet  <= P_LI;
      bytAdr  <= P_BT;
      P_DOUT_MEM <= P_DIN;
    end if;
  end process;

  P_BT_MEM <= bytAdr;
  P_RW_MEM <= memWrt;
  P_ADDR_MEM(7 downto 0) <= offs;

  -- TLB 
  tlbFull <= TLB(0)(15) and TLB(1)(15) and TLB(2)(15) and TLB(3)(15) and 
             TLB(4)(15) and TLB(5)(15) and TLB(6)(15) and TLB(7)(15);
  
  process(TLB)
  begin
    if (TLB(0)(15)='0') then
      empIdx <= "000";
    elsif (TLB(1)(15)='0') then
      empIdx <= "001";
    elsif (TLB(2)(15)='0') then
      empIdx <= "010";
    elsif (TLB(3)(15)='0') then
      empIdx <= "011";
    elsif (TLB(4)(15)='0') then
      empIdx <= "100";
    elsif (TLB(5)(15)='0') then
      empIdx <= "101";
    elsif (TLB(6)(15)='0') then
      empIdx <= "110";
    else
      empIdx <= "111";
    end if;
  end process;

  process(page, TLB)
  begin
    if    (page & '1'=TLB(0)(23 downto 15)) then
      index <= X"0";
      entry <= TLB(0)(11 downto 0);
    elsif (page & '1'=TLB(1)(23 downto 15)) then
      index <= X"1";
      entry <= TLB(1)(11 downto 0);
    elsif (page & '1'=TLB(2)(23 downto 15)) then
      index <= X"2";
      entry <= TLB(2)(11 downto 0);
    elsif (page & '1'=TLB(3)(23 downto 15)) then
      index <= X"3";
      entry <= TLB(3)(11 downto 0);
    elsif (page & '1'=TLB(4)(23 downto 15)) then
      index <= X"4";
      entry <= TLB(4)(11 downto 0);
    elsif (page & '1'=TLB(5)(23 downto 15)) then
      index <= X"5";
      entry <= TLB(5)(11 downto 0);
    elsif (page & '1'=TLB(6)(23 downto 15)) then
      index <= X"6";
      entry <= TLB(6)(11 downto 0);
    elsif (page & '1'=TLB(7)(23 downto 15)) then
      index <= X"7";
      entry <= TLB(7)(11 downto 0);
    else
      index <= "1XXX";
      entry <= (others => 'X');
    end if;
  end process;

  -- 
  P_ADDR_MEM(15 downto 8) <= entry(7 downto 0) when (mapPage='1') else page;

  -- TLB (MMU)
  tlbMiss <= mapPage and index(3);

  -- (MMU)
  memVio  <= mapPage and (not index(3)) and                      -- TLB hit
           (((not memWrt) and (not entry(10))) or                -- read
            ((    memWrt) and (not entry( 9))) or                -- write
            ((    insFet) and (not (entry(10) and entry(8)))));  -- fetch

  -- (MMU)
  badAdr  <= memReq and offs(0) and (not bytAdr);

  -- 
  -- P_MR_MEM <= memReq and not (tlbMiss or badAdr or memVio);

  --   
  --     
  --     
  P_MR_MEM <= not tlbMiss when (mmuStat="001");

  -- CPU
  P_VIO_INT <= badAdr or memVio;            -- 
  P_TLB_INT <= tlbMiss;                     -- CPU

  --I/O
  process(P_CLK,P_RESET)
  begin
    if (P_RESET='0') then
      P_BANK_MEM <= '0';                                -- IPL ROM
      enMmu <= '0';                                     -- MMU Enable
    elsif (P_CLK'event and P_CLK='1') then
      if(P_EN='1' and P_IOW='1') then                   -- IO[80h - A9h]
        if(P_ADDR(5 downto 4)="10") then                --   Axh
          if(P_ADDR(3 downto 1)="000") then             --    A0h or A1h
            P_BANK_MEM <= P_DIN(0);
          elsif(P_ADDR(3 downto 1)="001") then          --    A2h or A3h
            enMmu <= P_DIN(0);
          end if;
        end if;
		end if;
    end if;
  end process;

  --TLB
  process(P_CLK)
  begin
    if (P_CLK'event and P_CLK='1') then
      if(mapPage='1' and index(3)='0') then          -- TLB Hit
        TLB(conv_integer(index(2 downto 0)))(11) <=     -- D bit
          entry(11) or memWrt;
        TLB(conv_integer(index(2 downto 0)))(12) <='1'; -- R bit
      end if;
    end if;
  end process;

  --TLB miss 
  process(P_CLK)
  begin
    if(P_CLK'event and P_CLK='1') then
      if(tlbMiss='1') then                              -- TLB miss 
        fltPage <= page;                                --   
      end if;
    end if;
  end process;

  --
  process(P_CLK, P_RESET)
  begin
    if(P_RESET='0') then
      fltRsn <= "00";
    elsif(P_CLK'event and P_CLK='1') then
      if(badAdr='1' or memVio='1') then                 -- 
        fltRsn <= fltRsn or (badAdr & memVio);          --   
        fltAdr <= page & offs;                          --   
      elsif(P_EN='1' and P_IOR='1' and
            P_ADDR(5 downto 1)="10010") then            -- IO[A4h - A5h]
        fltRsn <= "00";                                 --   
      end if;
    end if;
  end process;

  -- CPU 
  P_DOUT <=
      P_DIN_MEM when (P_IOR='0') else                     -- 
      "00000000" & TLB(conv_integer(P_ADDR(4 downto 2)))(23 downto 16)
        when (P_ADDR(5)='0' and P_ADDR(1)='0') else       -- 80h,84h,...,9Ch
      TLB(conv_integer(P_ADDR(4 downto 2)))(15 downto 0)
        when (P_ADDR(5)='0') else                         -- 82h,86h,...,9Eh
      fltAdr when (P_ADDR(2)='0') else                    -- A2h Adr
      "00000000000000" & fltRsn when (P_ADDR(1)='0') else -- A4h 
      "00000000" & fltPage;                               -- A6h TLBmiss

end Behavioral;
