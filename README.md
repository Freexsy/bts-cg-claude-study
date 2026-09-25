# bts-cg-claude-study

## EMA Crossover EA (MetaTrader 5)

`MQL5/Experts/EMA_Crossover_EA.mq5` is a long-only Expert Advisor. Each time the
40 EMA crosses above the 200 EMA, it opens a buy position with a fixed lot size, stop loss and take profit.
Orders are sent with the standard library `CTrade` class.

### Strategy

- **Signal:** the fast EMA (default 40) closes above the slow EMA (default 200), and on the bar
  before it was at or below the slow EMA.
- **Confirmation:** the EA checks only closed bars, so a signal can't disappear later. The trade opens on
  the first tick of the bar after the crossover.
- **Order:** buy 0.5 lots, SL 20 pips below entry, TP 40 pips above entry (all adjustable).
- **Filters:** trading hours, trading days, optional maximum number of open positions.
- **Optional improvements** (all off by default, so the default settings trade the original strategy):
  - SL/TP as a multiple of the ATR instead of fixed pips
  - break-even and trailing stop
  - a trend filter that buys only when the slow EMA is rising
  - a cooldown: a minimum number of bars between two entries

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
| Signal filters | Only buy when the slow EMA is rising | false | Skips crossovers when the slow EMA is lower than it was N bars ago |
| | Slow EMA slope lookback | 10 | N, in bars |
| | Min bars between two entries | 0 | `0` = off. Skips signals that come too soon after the last entry |
| Trade management | Lot size | 0.5 | Rounded to the broker's volume step and limits |
| | SL/TP mode | Fixed pips | *Fixed pips* or *ATR multiple* |
| | Stop loss in pips | 20 | Fixed mode. `0` = no stop loss |
| | Take profit in pips | 40 | Fixed mode. `0` = no take profit |
| | ATR period | 14 | ATR mode. The ATR of the last closed bar is used |
| | Stop loss = ATR x | 1.5 | ATR mode. `0` = no stop loss |
| | Take profit = ATR x | 3.0 | ATR mode. `0` = no take profit |
| | Max open positions | 0 | `0` = unlimited (every crossover opens a trade) |
| | Points per pip | 0 | `0` = auto (10 points on 3/5-digit symbols, otherwise 1). Set it manually for gold, indices, etc. |
| | Magic number | 402000 | Identifies this EA's positions |
| | Max slippage (points) | 10 | |
| | Order comment | EMA Cross EA | |
| Break-even | Move SL to break-even | false | |
| | Profit that triggers break-even | 20 pips | |
| | Pips locked above entry | 2 pips | Covers spread and commission |
| Trailing stop | Use trailing stop | false | |
| | Profit that starts trailing | 25 pips | |
| | Distance between price and SL | 15 pips | |
| | Minimum SL improvement | 5 pips | Avoids modifying the order on every tick |
| Trading hours | Restrict trading to a time window | true | Turn off to trade 24h |
| | Start hour / minute | 08:00 | Broker server time |
| | End hour / minute | 20:00 | Exclusive. If the start is later than the end, the window crosses midnight (for example 22:00–04:00). The same start and end means the whole day. |
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
