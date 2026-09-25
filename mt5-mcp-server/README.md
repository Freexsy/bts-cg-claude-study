# MetaTrader 5 MCP server

`mt5_mcp_server.py` is an MCP server that lets Claude Desktop read and trade a MetaTrader 5 account.
It runs on the Windows PC where the MetaTrader 5 terminal is installed. It connects to the terminal with
the official `MetaTrader5` Python package.

Claude only acts when you send it a message. It does not watch the market on its own. For continuous
automated trading, use an Expert Advisor.

## Tools

| Tool | What it does |
|---|---|
| `get_account_info` | Balance, equity, free margin, leverage, demo or real, and the safety limits |
| `get_price` | Bid, ask, spread and trading specifications of a symbol |
| `get_candles` | The latest candles of a symbol (M1 to MN1, up to 500) |
| `get_positions` | Open positions with SL, TP and floating profit |
| `get_trade_history` | Trades closed during the last N days, with wins, losses and net result |
| `calculate_lot_size` | The lot size that risks a given % of the balance at a given stop loss |
| `open_position` | Opens a market position (stop loss required) |
| `modify_position` | Changes the SL/TP of an open position |
| `close_position` | Closes an open position |

The three trading tools are marked as destructive, so Claude Desktop asks for your approval before each call.

## Safety limits

The server enforces these limits on every order and refuses the order when a limit is not met.

| Limit | Default | Environment variable |
|---|---|---|
| Trade demo accounts only | on | `MT5_ALLOW_REAL_ACCOUNT` (`true` to allow real accounts) |
| Max lots per order | 0.10 | `MT5_MAX_LOTS` |
| Max open positions (whole account) | 3 | `MT5_MAX_OPEN_POSITIONS` |
| Max risk per trade (% of balance, at the SL) | 1.0 | `MT5_MAX_RISK_PERCENT` |
| Stop loss required, on the correct side, and it can't be moved beyond the max risk | always | |

Other settings:
- `MT5_MAGIC`: the magic number of Claude's orders, 404000 by default.
- `MT5_DEVIATION_POINTS`: the maximum slippage in points, 20 by default.
- `MT5_TERMINAL_PATH`: the path to `terminal64.exe`, if several terminals are installed.
- `MT5_LOG_FILE`: the path of the log file.

Every order and every refusal is written to `mt5_mcp_actions.log`, next to the script.

## Installation (Windows)

1. Install **Python 3.10 to 3.14 (64-bit)** from python.org. You don't need the *Add python.exe to PATH* option, because
   step 5 uses the full path to Python.
2. Copy this folder to `C:\mt5-mcp-server`.
3. Open a command prompt and install the dependencies. The `py` launcher comes with every python.org install:
   ```
   py -m pip install -r C:\mt5-mcp-server\requirements.txt
   ```
   If `py` is not found, use `python` instead of `py`.
4. Print the full path to Python:
   ```
   py -c "import sys; print(sys.executable)"
   ```
5. Install **Claude Desktop** and sign in. Open **Settings → Developer → Edit Config**, and copy the content of
   `claude_desktop_config.example.json` into `claude_desktop_config.json`. Replace the `command` value with
   the path from step 4, and write every `\` as `\\`. If the file already has an `mcpServers` section, add
   the `metatrader5` entry to it.
6. Open MetaTrader 5, log in to a **demo** account and enable **Algo Trading**.
7. Quit Claude Desktop completely (including the tray icon), then start it again. The `metatrader5` tools
   now appear in the tools menu of a new conversation.

Try: *"Show me my MetaTrader account and the EURUSD price."*

If `pip` says that no version of `MetaTrader5` matches, your Python is too recent for the MetaTrader5
package. Install Python 3.12 or 3.13 as well, and use `py -3.12` or `py -3.13` instead of `py` in steps 3 and 4.

## Testing

- **Without MetaTrader:** the `MetaTrader5` package only works on Windows. The server was smoke-tested end to end
  over stdio against a fake `MetaTrader5` module. That test covered the tool list, the read tools, and opening,
  modifying and closing a position. It also covered each refusal: lots above the limit, a missing stop loss, a
  stop loss on the wrong side, risk above the limit, and a real account.
- **With MetaTrader:** verified from Claude Desktop on a MetaQuotes-Demo account (Python 3.14, MetaTrader5 5.0.6180):
  reading the account, then opening, modifying and closing a 0.01 lot EURUSD position.
