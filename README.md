# bts-cg-claude-study

## EMA Crossover EA (MetaTrader 5)

`MQL5/Experts/EMA_Crossover_EA.mq5` is an EMA crossover Expert Advisor. Each time the
40 EMA crosses above the 200 EMA, it opens a buy position with a fixed lot size, stop loss and take profit.
Optionally it also sells when the 40 EMA crosses below the 200 EMA.
Orders are sent with the standard library `CTrade` class.

### Strategy

- **Signal:** the fast EMA (default 40) closes above the slow EMA (default 200), and on the bar
  before it was at or below the slow EMA. In *Sell only* or *Buy and sell* mode, the opposite
  crossover opens a sell.
- **Confirmation:** the EA checks only closed bars, so a signal can't disappear later. The trade opens on
  the first tick of the bar after the crossover.
- **Order:** buy 0.5 lots, SL 20 pips below entry, TP 40 pips above entry (all adjustable).
- **Filters:** trading hours, trading days, optional maximum number of open positions.
- **Optional improvements** (all off by default, so the default settings trade the original strategy):
  - SL/TP as a multiple of the ATR instead of fixed pips
  - lot size calculated from a fixed % of the balance risked per trade
  - break-even and trailing stop
  - a trend filter that buys only when the slow EMA is rising
  - a cooldown: a minimum number of bars between two entries
  - sell trades, and closing positions at the end of the trading session (no position held overnight)

### Installation

1. In MetaTrader 5, open **File → Open Data Folder**.
2. Copy `EMA_Crossover_EA.mq5` into `MQL5/Experts/`.
3. Open it in MetaEditor and press **Compile** (F7). You can also restart the terminal instead.
4. Drag **EMA_Crossover_EA** onto a chart and enable **Algo Trading**.

### Inputs

| Group | Input | Default | Description |
|---|---|---|---|
| Strategy | Signal timeframe | Current chart | Timeframe used to calculate the EMAs |
| | Fast EMA period | 40 | |
| | Slow EMA period | 200 | Must be greater than the fast period |
| | EMA applied price | Close | |
| | Trade direction | Buy only | *Buy only*, *Sell only* or *Buy and sell* |
| Signal filters | Trade only in the direction of the slow EMA slope | false | Buys only if the slow EMA is higher than N bars ago, sells only if it is lower |
| | Slow EMA slope lookback | 10 | N, in bars |
| | Min bars between two entries | 0 | `0` = off. Skips signals that come too soon after the last entry |
| Trade management | Lot size mode | Fixed lots | *Fixed lots* or *Risk % of balance* |
| | Lot size | 0.5 | Fixed mode. Rounded to the broker's volume step and limits |
| | Risk per trade | 1 % | Risk mode. The lot is sized so that hitting the SL loses this % of the balance. Needs a stop loss |
| | SL/TP mode | Fixed pips | *Fixed pips* or *ATR multiple* |
| | Stop loss in pips | 20 | Fixed mode. `0` = no stop loss |
| | Take profit in pips | 40 | Fixed mode. `0` = no take profit |
| | ATR period | 14 | ATR mode. The ATR of the last closed bar is used |
| | Stop loss = ATR x | 1.5 | ATR mode. `0` = no stop loss |
| | Take profit = ATR x | 3.0 | ATR mode. `0` = no take profit |
| | Max open positions | 0 | `0` = unlimited (every crossover opens a trade) |
| | Close opposite positions on a new signal | true | A bearish crossover closes the open buys, a bullish one the open sells (only when that signal is traded) |
| | Points per pip | 0 | `0` = auto (10 points on 3/5-digit symbols, otherwise 1). Set it manually for gold, indices, etc. |
| | Magic number | 402000 | Identifies this EA's positions |
| | Max slippage (points) | 10 | |
| | Order comment | EMA Cross EA | |
| Break-even | Move SL to break-even | false | |
| | Profit that triggers break-even | 1.0 x SL | As a multiple of the SL distance: 1.0 = when the profit equals the initial risk |
| | Pips locked in profit | 2 pips | Covers spread and commission |
| Trailing stop | Use trailing stop | false | |
| | Profit that starts trailing | 25 pips | |
| | Distance between price and SL | 15 pips | |
| | Minimum SL improvement | 5 pips | Avoids modifying the order on every tick |
| Trading hours | Restrict trading to a time window | true | Turn off to trade 24h |
| | Start hour / minute | 08:00 | Broker server time |
| | End hour / minute | 20:00 | Exclusive. If the start is later than the end, the window crosses midnight (for example 22:00–04:00). The same start and end means the whole day. |
| | Close open positions outside trading hours/days | false | Closes every position of the EA when the window ends, so no position is held overnight |
| Trading days | Monday … Sunday | Mon–Fri on | The day filter uses the server day when the signal happens |
| Display | Show info panel on chart | true | Shows EMA values, settings, status and open positions |

### Notes

- Trading hours use the **broker server time** (the time in Market Watch), not your local time.
- A crossover outside the trading window is skipped. The EA doesn't queue it for later.
- Before sending an order, the EA checks Algo Trading permissions, free margin and the broker's
  minimum stop distance. It retries temporary errors (requote, price changed) up to 3 times.
- On **netting** accounts, a new signal adds to the existing position and replaces its SL/TP.
  Set *Max open positions* to `1` to avoid this.
- On **H4 and higher**, the EA checks the signal only when a new bar opens. With a trading window
  such as 08:00–20:00, crossovers found at the 20:00, 00:00 and 04:00 bar opens are skipped.
  Turn the time filter off on these timeframes unless you really want this.
- In ATR mode the SL distance changes with volatility, so with a fixed lot size the money at risk
  per trade changes too.
- Test it in the Strategy Tester (Ctrl+R) or on a demo account before trading live.

### Short-term (intraday) setup

To trade short moves and be flat every evening:

| Input | Value |
|---|---|
| Timeframe (Strategy Tester *Settings* tab) | M15 |
| Trade direction | Buy and sell |
| Lot size mode / Risk per trade | Risk % of balance / 1 % |
| SL/TP mode | ATR multiple (1.5 / 3.0) |
| Restrict trading to a time window | true, 08:00–20:00 |
| Close open positions outside trading hours/days | true |

On M15 the ATR is small, so the SL is typically a few pips and the spread takes a larger share of each
trade. Check the results with *Every tick based on real ticks* modelling.

### Suggested test plan

Run each test on the same symbol, timeframe and period (for example EURUSD H4, 2020 to today),
with the trading hours filter off. Change **one** setting at a time and compare the results with the baseline.

1. **Baseline:** default settings.
2. **Break-even:** *Move SL to break-even* = true.
3. **ATR stops:** *SL/TP mode* = ATR multiple.
4. **Trend filter:** *Only buy when the slow EMA is rising* = true.
5. **Cooldown:** *Min bars between two entries* = 10.
6. Combine the options that helped, then check the result on other symbols (GBPUSD, USDJPY).
   Settings that only work on one symbol are probably fitted to noise.

With ATR stops, the SL distance changes from trade to trade. Use *Lot size mode* = Risk % of balance,
so that every trade risks the same amount of money.

## Session Breakout EA (MetaTrader 5)

`MQL5/Experts/Session_Breakout_EA.mq5` is an intraday breakout Expert Advisor. It never holds
a position overnight.

### Strategy

1. **Night range:** the EA measures the high and low of the quiet night (Asian) session, 02:00–09:00 server time.
2. **Orders at the London open:** at 09:00 it places a buy stop just above the range and a sell stop
   just below it. The stop loss is on the other side of the range, and the take profit is 1× the stop loss distance.
3. **One trade per day:** when one order is filled, the other one is deleted. Orders that are still
   unfilled at 13:00 are deleted.
4. **Flat every evening:** every position is closed at 21:00.
5. **Filters:** days with an abnormally small or large night range (relative to the daily ATR) and moments
   with a wide spread are skipped.
6. **Risk:** the lot size is calculated so that a stop loss costs 1 % of the balance.

The default times assume a broker whose server runs on GMT+2 in winter and GMT+3 in summer
(for example MetaQuotes-Demo). With that server time, 02:00–09:00 is 00:00–07:00 in London and 09:00 is the Frankfurt open.
If your broker uses another server time, shift all the times by the difference.

### Inputs

| Group | Input | Default | Description |
|---|---|---|---|
| Session times | Range start / end | 02:00 / 09:00 | Night range. Orders are placed at the range end |
| | Entry deadline | 13:00 | Unfilled orders are deleted |
| | Close all positions at | 21:00 | End of the trading day |
| Breakout | Trade direction | Buy and sell | |
| | Order distance beyond the range | 1 pip | |
| | Delete the other order once one is filled | true | One trade per day |
| | Daily ATR period | 14 | Used by the range filter |
| | Min / max range size | 0.1 / 1.0 × daily ATR | `0` = off |
| | Max spread to place the orders | 3 pips | `0` = off. The EA waits until the spread is lower |
| Risk management | Lot size mode | Risk % of balance | or *Fixed lots* |
| | Risk per trade | 1 % | |
| | Lot size | 0.1 | Fixed mode only |
| | Stop loss | 1.0 × range | 1.0 = other side of the range |
| | Take profit | 1.0 × stop loss | `0` = no take profit, exit at the close time |
| | Move SL to break-even | false | Triggered at 0.5 × the SL distance, locks 1 pip |
| Trading days | Monday … Friday | all on | |
| General | Points per pip, magic number (403000), slippage, comment, panel, range drawing | | |

### Test protocol

Keep the default settings and do not change them between tests.

1. EURUSD, 2020.01.01 → 2023.12.31, *Every tick based on real ticks*.
2. EURUSD, 2024.01.01 → today: a period the first test did not use.
3. GBPUSD, both periods.

The strategy is worth trading on a demo account only if the profit factor is above about 1.1 and the maximum
drawdown is below about 20 % in **every** test. If you change a setting to improve test 1, you must
confirm the change on test 2 without touching it again.

## EMA Crossover Strategy (TradingView)

`TradingView/EMA_Crossover_Strategy.pine` is a Pine Script v6 port of the EMA Crossover EA. You can use it to
backtest the idea in TradingView's Strategy Tester and see the signals on any chart.

**Install:** open a chart, open the **Pine Editor**, replace its content with the file, then click
**Save** and **Add to chart**. The results are in the **Strategy Tester** tab.

- The inputs match the MT5 EA: trade direction, fixed pips or ATR stops, fixed quantity or risk % of
  equity, and an optional session with close outside the session.
- On forex, quantities are in units: 50,000 = 0.5 lot.
- The strategy uses 30:1 margin, so it can simulate forex leverage.
- TradingView backtests have no spread. The default commission of 0.005 % per order stands in for about
  1 pip per round trip on EURUSD. Adjust it for other markets.
- A TradingView strategy does not place real orders. Automated trading needs alerts sent by
  webhook (paid plan) to a broker or a bridge.

## MetaTrader 5 MCP server (Claude Desktop)

`mt5-mcp-server/` contains an MCP server. With it, Claude Desktop can read a MetaTrader 5 account
(account, prices, candles, positions, history) and, after your approval, open, modify and close positions.
The server enforces safety limits: demo account only, max lots, max risk per trade, max open positions and a
mandatory stop loss. See `mt5-mcp-server/README.md` for the installation.
