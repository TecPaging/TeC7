--
-- TeC7 VHDL Source Code
--    Tokuyama kousen Educational Computer Ver.7
--
-- Copyright (C) 2011-2023 by
--                      Dept. of Computer Science and Electronic Engineering,
--                      Tokuyama College of Technology, JAPAN
--
--   上記著作権者は，Free Software Foundation によって公開されている GNU 一般公
-- 衆利用許諾契約書バージョン２に記述されている条件を満たす場合に限り，本ソース
-- コード(本ソースコードを改変したものを含む．以下同様)を使用・複製・改変・再配
-- 布することを無償で許諾する．
--
--   本ソースコードは＊全くの無保証＊で提供されるものである。上記著作権者および
-- 関連機関・個人は本ソースコードに関して，その適用可能性も含めて，いかなる保証
-- も行わない．また，本ソースコードの利用により直接的または間接的に生じたいかな
-- る損害に関しても，その責任を負わない．
--
--

--
-- TaC/tac_mmu.vhd : TaC Memory Management Unit Source Code
--
-- 2023.12.27           : Page Table Walk を自動化したバージョン
-- 2022.08.25           : P_MR_MEMが2クロック期間1になるバグ訂正
--                      : TLBの検索結果を12ビットに限定するなど最適化
-- 2022.03.21           : 動作テスト完了
-- 2021.12.09           : ページング方式に変更開始
-- 2019.12.19           : CPU停止時（コンソール動作時）はアドレス変換禁止
-- 2019.07.30           : アドレスエラー追加
-- 2019.01.22           : 新しく追加
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
         P_PAG_INT  : out std_logic;                     -- Page Faule excp.

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
-- 動作中を表すFF
signal mapPage : std_logic;                             -- activate mapping
signal mmuStat : std_logic_vector(2 downto 0);          -- mmu status

-- CPUからの入力ラッチ
signal page    : std_logic_vector(7 downto 0);          -- page no
signal offs    : std_logic_vector(7 downto 0);          -- in page offset
signal data    : std_logic_vector(15 downto 0);         -- cpu data
signal memWrt  : std_logic;                             -- memory write
signal insFet  : std_logic;                             -- instruction fetch
signal bytAdr  : std_logic;                             -- byte addressing

-- TLB
-- エントリのビット構成
--|<------ 8 ---->|<-- 5 -->|<-3->|<------ 8 ---->|
--+---------------+-+-+-+-+-+-----+---------------+
--|       PAGE    |V|*|*|R|D|R/W/X|      FRAME    |
--+---------------+-+-+-+-+-+-----+---------------+
-- 3 2 1 0 9 8 7 6 5 4 3 2 1 0 9 8 7 6 5 4 3 2 1 0
--PAGE:ページ番号, V:Valid, *:未定義, R:Reference, D:Dirty,
--R/W/X:Read/Write/eXecute, FRAME:フレーム番号
subtype TlbField is std_logic_vector(23 downto 0);
type TlbArray is array(0 to 7) of TlbField;             -- array of 24bit * 8

signal TLB     : TlbArray;                              -- TLB
signal entry   : std_logic_vector(11 downto 0);         -- target TLB entry
signal index   : std_logic_vector(3 downto 0);          -- index of TLB entry
signal tmpIdx  : std_logic_vector(3 downto 0);          -- Cndidate for index
signal tlbFull : std_logic;                             -- TLB full
signal empIdx  : std_logic_vector(2 downto 0);          -- index of empty entry
signal pageFlt : std_logic;                             -- detect page fault
signal rndIdx  : std_logic_vector(2 downto 0);          -- random address of TLB
signal tlbMiss : std_logic;                             -- TLB miss

-- 例外
signal memVio  : std_logic;                             -- Memory Violation
signal badAdr  : std_logic;                             -- Bad Address

-- i/oレジスタ
signal enMmu   : std_logic;                             -- Enable MMU
signal fltPage : std_logic_vector(7 downto 0);          -- Page happend fault
signal fltRsn  : std_logic_vector(1 downto 0);          -- reason of fault
signal fltAdr  : std_logic_vector(15 downto 0);         -- address of fault
signal pageTbl : std_logic_vector(7 downto 0);          -- page table register

signal swapOutAdr : std_logic_vector(15 downto 1);      -- address to memory
signal swapInAdr  : std_logic_vector(15 downto 1);      -- 
signal targetFrm  : std_logic_vector(7 downto 0);       -- 
signal targetAdr  : std_logic_vector(15 downto 0);      -- 

begin
  -- MMUが動作中なので次のクロックではCPUは状態を変化させない
  P_WAIT <= '1' when (mmuStat="000" and P_MR='1') or
                     (mmuStat="001" and tlbMiss='1' and badAdr='0') or
                     (mmuStat="010") or
                     (mmuStat="011") or
                     (mmuStat="100") or
                     (mmuStat="101" and pageFlt='0')
                else '0';

  -- mmuStatの制御(MMUの状態)
  process(P_CLK, P_RESET)
  begin
    if (P_RESET='0') then
      mmuStat <= "000";
    elsif (P_CLK'event and P_CLK='1') then
      if (mmuStat="000") then
        if (P_MR='1') then
          mmuStat <= "001";
        end if;
      elsif (mmuStat="001") then
        if (tlbMiss='1' and badAdr='0') then
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
      elsif (mmuStat="100") then
        mmuStat <= "101";
      else -- if (mmuStat="101") then
        if (pageFlt='1') then
          mmuStat <= "000";
        else
          mmuStat <= "001";
        end if;
      end if;
    end if;
  end process;

  -- mapPage関連の処理(p->f変換が必要な時(mmuStat="001"の時)1になる)
  process(P_CLK, P_RESET)
  begin
    if (P_RESET='0') then
      mapPage <= '0';
    elsif (P_CLK'event and P_CLK='1') then
      -- 次のクロックでmmuStat="001"になる
      if ((mmuStat="000" and P_MR='1') or
          (mmuStat="101" and pageFlt='0')) then
        mapPage <= (not P_PR) and enMmu;
      else
        mapPage <= '0';
      end if;
    end if;
  end process;

  -- メモリアクセス関係の信号線はMMUの入り口でラッチする
  -- (CPU内のディレイに関係なくメモリが動作できるように)
  process(P_CLK)
  begin
    if (P_CLK'event and P_CLK='1') then
      page    <= P_ADDR(15 downto 8);
      offs    <= P_ADDR(7  downto 0);
      data    <= P_DIN;
      memWrt  <= P_RW;
      insFet  <= P_LI;
      bytAdr  <= P_BT;
    end if;
  end process;
  rndIdx  <= offs(3 downto 1);

  -- TLBのエントリが全て使用中
  tlbFull <= TLB(0)(15) and TLB(1)(15) and TLB(2)(15) and TLB(3)(15) and 
             TLB(4)(15) and TLB(5)(15) and TLB(6)(15) and TLB(7)(15);

  -- TLBの空きエントリのインデクス
  empIdx <= "000" when (TLB(0)(15)='0') else
            "001" when (TLB(1)(15)='0') else
            "010" when (TLB(2)(15)='0') else
            "011" when (TLB(3)(15)='0') else
            "100" when (TLB(4)(15)='0') else
            "101" when (TLB(5)(15)='0') else
            "110" when (TLB(6)(15)='0') else
            "111";

  -- TLBの検索
  tmpIdx <= "0000" when (P_ADDR(15 downto 8)&'1' = TLB(0)(23 downto 15)) else
            "0001" when (P_ADDR(15 downto 8)&'1' = TLB(1)(23 downto 15)) else
            "0010" when (P_ADDR(15 downto 8)&'1' = TLB(2)(23 downto 15)) else
            "0011" when (P_ADDR(15 downto 8)&'1' = TLB(3)(23 downto 15)) else
            "0100" when (P_ADDR(15 downto 8)&'1' = TLB(4)(23 downto 15)) else
            "0101" when (P_ADDR(15 downto 8)&'1' = TLB(5)(23 downto 15)) else
            "0110" when (P_ADDR(15 downto 8)&'1' = TLB(6)(23 downto 15)) else
            "0111" when (P_ADDR(15 downto 8)&'1' = TLB(7)(23 downto 15)) else
            "1000";

  -- TLBの検索結果を記憶(ここまでをmmuStat="000"の間に行う)
  process(P_CLK, P_RESET)
  begin
    if (P_CLK'event and P_CLK='1') then
      index <= tmpIdx;
      entry <= TLB(conv_integer(tmpIdx(2 downto 0)))(11 downto 0);
    end if;
  end process;

  -- TLB ミスの判定
  tlbMiss <= mapPage and index(3);

  -- TLB の自動的な更新
  process(P_CLK)
  begin
    if (P_CLK'event and P_CLK='1') then
      if(mapPage='1' and index(3)='0') then             -- TLB Hit
        TLB(conv_integer(index(2 downto 0)))(11) <=       -- D bit
          entry(11) or memWrt;
        TLB(conv_integer(index(2 downto 0)))(12) <='1';   -- R bit
      elsif(mmuStat="011") then                         -- エントリのswap-out
        TLB(conv_integer(rndIdx))(15) <= '0';             -- V bit
      elsif(mmuStat="100") then                         -- エントリのswap-in
        TLB(conv_integer(empIdx)) <= page & P_DIN_MEM;
      elsif(P_EN='1' and P_IOW='1' and                  -- ページテーブル
            P_ADDR(2 downto 1)="11") then               --   レジスタの書換え
        TLB(0)(15) <= '0';                                -- 全V bitを0にする
        TLB(1)(15) <= '0';
        TLB(2)(15) <= '0';
        TLB(3)(15) <= '0';
        TLB(4)(15) <= '0';
        TLB(5)(15) <= '0';
        TLB(6)(15) <= '0';
        TLB(7)(15) <= '0';
      end if;
    end if;
  end process;

  -- メモリへの出力
  swapOutAdr <= (pageTbl&"0000000") + TLB(conv_integer(rndIdx))(23 downto 16);
  swapInAdr  <= (pageTbl&"0000000") + page;
  targetFrm  <= entry(7 downto 0) when (mapPage='1') else page;
  targetAdr  <= targetFrm & offs;
  P_ADDR_MEM <= (swapOutAdr & '0') when mmuStat="011" else
                (swapInAdr  & '0') when mmuStat="100" else targetAdr;
  P_DOUT_MEM <= TLB(conv_integer(rndIdx))(15 downto 0) when mmuStat="011"
                else data;
  P_BT_MEM <= bytAdr when mmuStat="001" else '0';
  P_RW_MEM <= memWrt when mmuStat="001" else
              '1'    when mmuStat="011" else '0';

  -- 例外が発生していなければメモリをアクセスする
  -- P_MR_MEM <= '1'
  --   when (mmuStat="001" and tlbMiss='0' and badAdr='0' and memVio='0') else
  --   1' when (mmuStat="011" or mmuStat="100") else '0';
  --   タイミングが厳しい場合は
  --     アドレス違反やメモリ保護違反でメモリを破壊しても
  --     プロセスを打ち切ればよいので妥協することにする．
  P_MR_MEM <= '1' when (mmuStat="001" and tlbMiss='0') else
              '1' when (mmuStat="011" or mmuStat="100") else '0';

  -- メモリ関連の例外 --
  -- メモリ保護例外(mmuStat="001"でMMU動作時だけ)
  memVio  <= mapPage and (not index(3)) and                      -- TLB hit
           (((not memWrt) and (not entry(10))) or                --   read
            ((    memWrt) and (not entry( 9))) or                --   write
            ((    insFet) and (not (entry(10) and entry(8)))));  --   fetch

  -- 奇数アドレス例外(mmuStat="001"でMMUが動作していない時も)
  badAdr  <= (offs(0) and (not bytAdr)) when (mmuStat="001")
             else '0';

  -- メモリ関連例外の原因レジスタ
  process(P_CLK, P_RESET)
  begin
    if(P_RESET='0') then
      fltRsn <= "00";
    elsif(P_CLK'event and P_CLK='1') then
      if(badAdr='1' or memVio='1') then                 -- メモリ関連例外なら
        fltRsn <= fltRsn or (badAdr & memVio);          --   原因を記憶
      elsif(P_EN='1' and P_IOR='1' and
            P_ADDR(5 downto 1)="10010") then            -- IO[A4h - A5h]を
        fltRsn <= "00";                                 --   読み出したらクリア
      end if;
    end if;
  end process;

  -- 例外の原因アドレス
  process(P_CLK, P_RESET)
  begin
    if(P_RESET='0') then
      fltAdr <= "0000000000000000";
    elsif(P_CLK'event and P_CLK='1') then
      if(badAdr='1' or memVio='1' or pageFlt='1') then  -- メモリ関連例外なら
        fltAdr <= page & offs;                          --   原因アドレスを記憶
      end if;
    end if;
  end process;

  -- メモリ関係の例外を割込みコントローラに知らせる
  P_VIO_INT <= badAdr or memVio;

  -- Page Fault 関連 --
  -- page_fault例外
  process(P_CLK, P_RESET)
  begin
    if (P_RESET='0') then
      pageFlt <= '0';
    elsif (P_CLK'event and P_CLK='1') then
      if(mmuStat="100") then
        pageFlt <= not P_DIN_MEM(15);  -- fetchしたentryのVビット
      else
        pageFlt <= '0';
      end if;
    end if;
  end process;

  -- page_fault発生ページ
  process(P_CLK)
  begin
    if(P_CLK'event and P_CLK='1') then
      if(pageFlt='1') then                              -- Page Fault なら
        fltPage <= page;                                --   原因ページを記憶
      end if;
    end if;
  end process;

  -- page_fault を割り込みコントローラとCPUに接続
  P_PAG_INT <= pageFlt;

  --I/Oレジスタの書き換え
  process(P_CLK,P_RESET)
  begin
    if (P_RESET='0') then
      P_BANK_MEM <= '0';                                -- IPL ROM
      enMmu <= '0';                                     -- MMU Enable
    elsif (P_CLK'event and P_CLK='1') then
      if(P_EN='1' and P_IOW='1') then                   -- IO[A0h - A7h]
        if(P_ADDR(2 downto 1)="00") then                --    A0h or A1h
          P_BANK_MEM <= P_DIN(0);
        elsif(P_ADDR(2 downto 1)="01") then             --    A2h or A3h
          enMmu <= P_DIN(0);
        elsif(P_ADDR(2 downto 1)="11") then             --    A6h or A7h
          pageTbl <= P_DIN(7 downto 0);
        end if;
      end if;
	  end if;
  end process;

  -- CPU への出力
  P_DOUT <=
      P_DIN_MEM when (P_IOR='0') else                     -- 通常はメモリ
      fltAdr when (P_ADDR(2)='0') else                    -- A2h 割込み原因Adr
      "00000000000000" & fltRsn when (P_ADDR(1)='0') else -- A4h 割込み原因
      "00000000" & fltPage;                               -- A6h 不在ページ

end Behavioral;
