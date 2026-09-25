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
| Trade management | Lot size | 0.5 | Rounded to the broker's volume step and limits |
| | Stop loss in pips | 20 | `0` = no stop loss |
| | Take profit in pips | 40 | `0` = no take profit |
| | Max open positions | 0 | `0` = unlimited (every crossover opens a trade) |
| | Points per pip | 0 | `0` = auto (10 points on 3/5-digit symbols, otherwise 1). Set it manually for gold, indices, etc. |
| | Magic number | 402000 | Identifies this EA's positions |
| | Max slippage (points) | 10 | |
| | Order comment | EMA Cross EA | |
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
- Test it in the Strategy Tester (Ctrl+R) or on a demo account before trading live.
