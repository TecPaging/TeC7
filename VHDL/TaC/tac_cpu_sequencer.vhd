--
-- TeC7 VHDL Source Code
--    Tokuyama kousen Educational Computer Ver.7
--
-- Copyright (C) 2002-2021 by
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
-- TaC/tac_cpu_sequencer.vhd : TaC CPU Sequencer VHDL Source Code
--
-- 2021.04.12           : 新規作成
--

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.std_logic_unsigned.all;

entity TAC_CPU_SEQUENCER is
  port (
  P_CLK         : in std_logic;
  P_RESET       : in std_logic;
  P_STOP        : in std_logic;
  P_INTR        : in std_logic;
  P_OP1         : in std_logic_vector(4 downto 0);
  P_OP2         : in std_logic_vector(2 downto 0);
  P_RD          : in std_logic_vector(3 downto 0);   -- 命令の Rd
  P_UPDATE_PC   : out std_logic_vector(2 downto 0);  -- PC の更新
  P_UPDATE_SP   : out std_logic_vector(1 downto 0);  -- SP の更新
  P_LOAD_IR     : out std_logic;                     -- IR のロード
  P_LOAD_DR     : out std_logic;                     -- DR のロード
  P_LOAD_FLAG   : out std_logic;                     -- FLAG のロード
  P_LOAD_TMP    : out std_logic;                     -- TMP のロード
  P_LOAD_GR     : out std_logic;                     -- 汎用レジスタのロード
  P_SELECT_A    : out std_logic_vector(2 downto 0);  -- アドレス出力の選択
  P_SELECT_D    : out std_logic_vector(2 downto 0);  -- データ出力の選択
  P_SELECT_W    : out std_logic_vector(1 downto 0);  -- DR への入力の選択
  P_SELECT_B    : out std_logic;                     -- ALU B への入力の選択
  P_ALU_START   : out std_logic;
  P_BUSY        : in std_logic;
  P_FLAG_V      : in std_logic;
  P_FLAG_C      : in std_logic;
  P_FLAG_Z      : in std_logic;
  P_FLAG_S      : in std_logic;
  P_MR          : out std_logic;                     -- Memory Request
  P_IR          : out std_logic;                     -- I/O Request
  P_RW          : out std_logic                      -- Read/Write
  --TODO
  );
end TAC_CPU_SEQUENCER;
  
architecture RTL of TAC_CPU_SEQUENCER is

-- ステート
constant STATE_FETCH : std_logic_vector(4 downto 0) := "00000";
constant STATE_WAIT  : std_logic_vector(4 downto 0) := "00001";
constant STATE_INTR1 : std_logic_vector(4 downto 0) := "00010";
constant STATE_INTR2 : std_logic_vector(4 downto 0) := "00011";
constant STATE_INTR3 : std_logic_vector(4 downto 0) := "00100";
constant STATE_INTR4 : std_logic_vector(4 downto 0) := "00101";
constant STATE_DEC1  : std_logic_vector(4 downto 0) := "00110";
constant STATE_DEC2  : std_logic_vector(4 downto 0) := "00111";
constant STATE_ALU1  : std_logic_vector(4 downto 0) := "01000";
constant STATE_ALU2  : std_logic_vector(4 downto 0) := "01001";
constant STATE_ALU3  : std_logic_vector(4 downto 0) := "01010";
constant STATE_ST1   : std_logic_vector(4 downto 0) := "01011";
constant STATE_ST2   : std_logic_vector(4 downto 0) := "01100";
constant STATE_PUSH  : std_logic_vector(4 downto 0) := "01101";
constant STATE_POP   : std_logic_vector(4 downto 0) := "01110";
constant STATE_CALL  : std_logic_vector(4 downto 0) := "01111";
constant STATE_RET   : std_logic_vector(4 downto 0) := "10000";
constant STATE_RETI1 : std_logic_vector(4 downto 0) := "10001";
constant STATE_RETI2 : std_logic_vector(4 downto 0) := "10010";
constant STATE_RETI3 : std_logic_vector(4 downto 0) := "10011";
constant STATE_IN1   : std_logic_vector(4 downto 0) := "10100";
constant STATE_IN2   : std_logic_vector(4 downto 0) := "11000";
constant STATE_CON   : std_logic_vector(4 downto 0) := "11111";

signal   I_STATE     : std_logic_vector(4 downto 0);

signal   I_IS_INDR   : std_logic; -- アドレッシングモードがFP相対か（バイト）レジスタインダイレクト
signal   I_IS_SHORT  : std_logic; -- アドレッシングモードがレジスタレジスタかショートイミディエイト
signal   I_IS_ALU    : std_logic; -- LD~SHRL (ST以外)
signal   I_JMP_GO    : std_logic; -- JMP, CALL が成立するとき
signal   I_IS_DIV    : std_logic; -- DIV, MOD

begin
  
  -- TODO
  -- - MMU待ちをどうやって処理するか
  
  -- LD, ADD, SUB, CMP, AND, OR, XOR, ADDS, MUL, DIV, MOD, MULL, DIVL, SHLA, SHLL, SHRA, SHRL
  I_IS_ALU    <= '1' when P_OP1 /= "00000" and P_OP1 /= "00010" and P_OP1(4 downto 2) <= "100" else '0';
  I_IS_INDR   <= '1' when P_OP2 = "011" or P_OP2(2 downto 1) = "11" else '0';
  I_IS_SHORT  <= '1' when P_OP2(2 downto 1) = "10" else '0';
  I_IS_DIV    <= '1' when P_OP1(4 downto 1) = "0101" else '0';
  I_JMP_GO    <=
    '1' when P_OP1 = "10100" and (
            (P_RD = "0000" and P_FLAG_Z = '1')                          -- JZ
        or  (P_RD = "0001" and P_FLAG_C = '1')                          -- JC
        or  (P_RD = "0010" and P_FLAG_S = '1')                          -- JM
        or  (P_RD = "0011" and P_FLAG_V = '1')                          -- JO
        or  (P_RD = "0100" and P_FLAG_Z = '0' and P_FLAG_S = P_FLAG_V)  -- JGT
        or  (P_RD = "0101" and P_FLAG_S = P_FLAG_V)                     -- JGE
        or  (P_RD = "0110" and (P_FLAG_Z = '1' or P_FLAG_S /= P_FLAG_V))-- JLE
        or  (P_RD = "0111" and P_FLAG_S /= P_FLAG_V)                    -- JLT
        or  (P_RD = "1000" and P_FLAG_Z = '0')                          -- JNZ
        or  (P_RD = "1001" and P_FLAG_C = '0')                          -- JNC
        or  (P_RD = "1010" and P_FLAG_S = '0')                          -- JNS
        or  (P_RD = "1011" and P_FLAG_V = '0')                          -- JNV
        or  (P_RD = "1100" and P_FLAG_Z = '0' and P_FLAG_C = '0')       -- JHI
        or  (P_RD = "1110" and (P_FLAG_Z = '1' or P_FLAG_C = '1'))      -- JLO
        or  P_RD = "1111")                                              -- JMP
      or (P_OP1 = "10101" and P_RD = "0000") else                       -- CALL
    '0';
  
  -- ステートマシンはステートの遷移のみを書く
  process (P_CLK, P_RESET)
  begin
    if (P_RESET='0') then
      I_STATE <= STATE_FETCH;
      P_STOP  <= '0';
      P_INTR  <= '0';
    elsif (P_CLK'event and P_CLK='1') then
      case I_STATE is
        when STATE_FETCH =>
          I_STATE <=
            STATE_DEC1  when P_STOP = '0' and P_INTR = '0' else
            STATE_DEC2  when P_STOP = '0' and P_INTR = '1' else
            STATE_CON;
        when STATE_WAIT =>
          I_STATE <= STATE_FETCH when P_INTR = '0' else STATE_WAIT;
        when STATE_INTR1 =>
          I_STATE <= STATE_INTR2;
        when STATE_INTR2 =>
          I_STATE <= STATE_INTR3;
        when STATE_INTR3 =>
          I_STATE <= STATE_INTR4;
        when STATE_DEC1 =>
          if (P_BUSY='0') then
            I_STATE <=
              STATE_ALU1  when P_OP2 = "010" else
              STATE_ALU2  when I_IS_INDR and I_IS_ALU else
              STATE_ALU3  when I_IS_SHORT and I_IS_DIV else
              STATE_DEC2  when P_OP2(2 downto 1) = "00" else
              STATE_ST2   when I_IS_INDR and P_OP1 = "00010" else
              STATE_PUSH  when P_OP1 = "11000" and P_OP2(2) = '0' else
              STATE_POP   when P_OP1 = "11000" and P_OP2(2) = '1' else
              STATE_RET   when P_OP1 = "11010" and P_OP2(2) = '0' else
              STATE_RETI1 when P_OP1 = "11010" and P_OP2(2) = '1' else
              STATE_FETCH;
          end if;
        when STATE_DEC2 =>
          if (P_BUSY='0') then
            I_STATE <=
              STATE_ALU1  when I_IS_ALU else
              STATE_ST1   when P_OP1 = "00010" else
              STATE_CALL  when P_OP1 = "10101" else
              STATE_FETCH;
          end if;
        when STATE_RETI1 =>
          if (P_BUSY='0') then
            I_STATE <= STATE_RETI2;
          end if;
        when STATE_RETI2 =>
          I_STATE <= STATE_RETI3;
        when others =>
          I_STATE <= STATE_FETCH;
      end case;
    end if;
  end process;
  
  -- 信号に出力する内容をステートによって決める
  
  P_UPDATE_PC <=
    -- PC += 2
    "100" when I_STATE = STATE_DEC1 and (P_OP1 = "00000" or P_OP1 = "11111"
                or (I_IS_INDR and P_OP1(4 downto 1) = "1011")
                or (I_IS_SHORT and I_IS_ALU)) or I_STATE = STATE_ST2
            or I_STATE = STATE_ALU2 or I_STATE = STATE_ALU3
            or I_STATE = STATE_PUSH or I_STATE = STATE_POP else
    -- PC += 4
    "101" when I_STATE = STATE_DEC2 and (P_OP1(4 downto 1) = "1011"
                or (P_OP1 = "10110" and not I_JMP_GO))
            or I_STATE = STATE_ALU1 or I_STATE = STATE_ST1 else
    -- PC <- Din
    "110" when I_STATE = STATE_INTR4 or I_STATE = STATE_RETI2
            or I_STATE = STATE_RET else
    -- PC <- EA
    "111" when I_STATE = STATE_DEC2 and (
            (P_OP1 = "10100" and I_JMP_GO) or P_OP1 = "10101") else
    "000";
  
  P_UPDATE_SP <=
    -- SP += 2
    "01"  when I_STATE = STATE_POP or I_STATE = STATE_RET
            or I_STATE = STATE_RETI2 or I_STATE = STATE_RETI3 else
    -- SP -= 1
    "10"  when I_STATE = STATE_INTR1 or I_STATE = STATE_INTR2
            or I_STATE = STATE_CALL  or I_STATE = STATE_PUSH else
    "00";
  
  P_LOAD_IR <= '1' when I_STATE = STATE_FETCH and P_INTR = '0' and P_STOP = '0'
          else '0';

  P_LOAD_DR <=
    '1' when (I_STATE = STATE_FETCH and P_STOP = '0' and P_INTR = '0')
          or (I_STATE = STATE_DEC1 and ((P_OP2 >= "000" and P_OP2 <= "011")
            or (I_IS_INDR and (I_IS_ALU or P_OP1 = "10110"))
            or (P_OP1 = "11000" and P_OP2(2) = '1')
            or (P_OP1 = "11010" and P_OP2(2) = '0'))) else
    '0';
  
  -- ADD, SUB, ..., SHRL ではフラグが変化する
  P_LOAD_FLAG <= '1' when P_OP1 >= "00011" and P_OP1 <= "10011" else '0';
  
  P_LOAD_TMP <= '1' when I_STATE = STATE_FETCH and P_INTR = '1' else '0';
  
  P_LOAD_GR <=
    '1' when (I_STATE = STATE_DEC1 and I_IS_SHORT and I_IS_ALU)
          or I_STATE = STATE_ALU2 or I_STATE = STATE_ALU3
          or I_STATE = STATE_IN1 or I_STATE = STATE_IN2
          or I_STATE = STATE_RETI3 else
    '0';
  
  P_SELECT_A <=
    "001" when I_STATE = STATE_DEC1 and (P_OP2 = "000" or P_OP2 = "010") else
    "010" when (I_STATE = STATE_DEC1 and I_IS_INDR)
            or (I_STATE = STATE_DEC2 and (
              I_IS_ALU or P_OP1 = "00010" or P_OP1(4 downto 1) = "1011")) else
    "100" when (I_STATE = STATE_DEC1 and ((P_OP1 = "11000" and P_OP2(2) = '1')
              or P_OP1 = "11010"))
            or I_STATE = STATE_RET or I_STATE = STATE_RETI2 else
    "101" when I_STATE = STATE_RETI1 else
    "110" when I_STATE = STATE_INTR1 or I_STATE = STATE_INTR2
            or (I_STATE = STATE_DEC1 and P_OP1 = "11000" and P_OP2(2) = '0')
            or (I_STATE = STATE_DEC2 and P_OP1 = "10101") else
    "000";
  
  P_SELECT_D <=
    "010" when I_STATE = STATE_DEC2 and P_OP1 = "10101" else
    "100" when (I_STATE = STATE_DEC1 and (
            (I_IS_INDR and (P_OP1 = "00010" or P_OP1 = "10111"))
              or (P_OP1 = "11000" and P_OP2(2) = '0')))
            or (I_STATE = STATE_DEC2 and P_OP1 = "10111") else
    "111" when I_STATE = STATE_INTR2 else
    "000";
  
  P_SELECT_W <=
    "01" when I_STATE = STATE_FETCH and P_INTR = '0' and P_STOP = '0' else
    "00";
  
  P_SELECT_B <=
    '1' when I_STATE = STATE_IN1 or I_STATE = STATE_IN2
          or I_STATE = STATE_POP or I_STATE = STATE_RETI3 else
    '0';
  
  P_ALU_START <=
    '1' when (I_STATE = STATE_DEC1 and (
          P_OP2 = "010" or (I_IS_INDR and I_IS_ALU)
            or (I_IS_SHORT and I_IS_DIV)))
          or (I_STATE = STATE_DEC2 and I_IS_ALU) else
    '0';

  P_MR <=
    '1' when (I_STATE = STATE_FETCH and P_INTR = '0' and P_STOP = '0')
          or I_STATE = STATE_INTR1 or I_STATE = STATE_INTR2
          or I_STATE = STATE_INTR4
          or (I_STATE = STATE_DEC1 and P_OP1 /= "00000" and P_OP1 /= "11111"
            and P_OP2 /= "100" and P_OP2 /= "101"
            and (P_OP2 /= "111" or P_OP2(4 downto 1) /= "1011"))
          or (I_STATE = STATE_DEC2 and P_OP1 /= "10100"
            and P_OP1(4 downto 1) /= "1011")
          or I_STATE = STATE_RET
          or I_STATE = STATE_RETI1 or I_STATE = STATE_RETI2 else
    '0';

  P_IR <=
    '1' when (I_STATE = STATE_DEC1 and I_IS_INDR and P_OP1(4 downto 1)="1011")
          or (I_STATE = STATE_DEC2 and P_OP1(4 downto 1) = "1011") else
    '0';
  
  P_RW <=
    '1' when I_STATE = STATE_INTR1 or I_STATE = STATE_INTR2
          or (I_STATE = STATE_DEC1 and (
            (I_IS_INDR and (P_OP1 = "00010" or P_OP1 = "10111"))
              or (P_OP1 = "11000" and P_OP2(2) = '0')))
          or (I_STATE = STATE_DEC2 and (
            P_OP1 = "00010" or P_OP1 = "10111" or P_OP1 = "10101")) else
    '0';
            
end RTL;
                