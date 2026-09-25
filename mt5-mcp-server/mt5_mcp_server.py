"""MCP server that lets Claude read and trade a MetaTrader 5 account.

It runs on the Windows PC where the MetaTrader 5 terminal is installed and exposes a small set of
tools to Claude Desktop over stdio. Trading is locked to demo accounts by default, and every order
is checked against hard limits (lot size, risk, number of positions, mandatory stop loss) before
it is sent. Every order and every refusal is written to mt5_mcp_actions.log.
"""

from __future__ import annotations

import atexit
import datetime as dt
import logging
import math
import os
from pathlib import Path
from typing import Any, Literal, NoReturn

import MetaTrader5 as mt5
from mcp.server.mcpserver import MCPServer
from mcp.server.mcpserver.exceptions import ToolError
from mcp.types import ToolAnnotations

# ── Safety limits: override them in the "env" block of claude_desktop_config.json ──
ALLOW_REAL_ACCOUNT = os.environ.get("MT5_ALLOW_REAL_ACCOUNT", "false").strip().lower() == "true"
MAX_LOTS = float(os.environ.get("MT5_MAX_LOTS", "0.10"))
MAX_OPEN_POSITIONS = int(os.environ.get("MT5_MAX_OPEN_POSITIONS", "3"))
MAX_RISK_PERCENT = float(os.environ.get("MT5_MAX_RISK_PERCENT", "1.0"))
MAGIC_NUMBER = int(os.environ.get("MT5_MAGIC", "404000"))
DEVIATION_POINTS = int(os.environ.get("MT5_DEVIATION_POINTS", "20"))
TERMINAL_PATH = os.environ.get("MT5_TERMINAL_PATH") or None
LOG_FILE = Path(os.environ.get("MT5_LOG_FILE") or Path(__file__).with_name("mt5_mcp_actions.log"))

# stdout carries the MCP protocol, so logs go to a file only
logging.basicConfig(filename=LOG_FILE, level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("mt5-mcp")

TIMEFRAMES = {
    "M1": mt5.TIMEFRAME_M1,
    "M5": mt5.TIMEFRAME_M5,
    "M15": mt5.TIMEFRAME_M15,
    "M30": mt5.TIMEFRAME_M30,
    "H1": mt5.TIMEFRAME_H1,
    "H4": mt5.TIMEFRAME_H4,
    "D1": mt5.TIMEFRAME_D1,
    "W1": mt5.TIMEFRAME_W1,
    "MN1": mt5.TIMEFRAME_MN1,
}
Timeframe = Literal["M1", "M5", "M15", "M30", "H1", "H4", "D1", "W1", "MN1"]
Side = Literal["buy", "sell"]
PendingType = Literal["buy_limit", "sell_limit", "buy_stop", "sell_stop"]
PENDING_TYPES = {
    "buy_limit": mt5.ORDER_TYPE_BUY_LIMIT,
    "sell_limit": mt5.ORDER_TYPE_SELL_LIMIT,
    "buy_stop": mt5.ORDER_TYPE_BUY_STOP,
    "sell_stop": mt5.ORDER_TYPE_SELL_STOP,
}
PENDING_NAMES = {code: name for name, code in PENDING_TYPES.items()}
RETCODE_INVALID_FILL = 10030   # the broker does not accept this filling type
EXPIRATION_SPECIFIED_FLAG = 4  # symbol_info().expiration_mode bit: expiry at a given time allowed

INSTRUCTIONS = """\
Tools to read and trade the MetaTrader 5 account open on the user's computer.
- Before proposing a trade, call get_account_info and get_price, and size the position with
  calculate_lot_size instead of computing lots yourself.
- For technical analysis, use get_indicators instead of estimating indicators from raw candles.
- Before calling any trading tool (open_position, place_pending_order, modify_position,
  close_position, cancel_pending_order), show the user the exact order (symbol, side, lots, entry,
  stop loss, take profit, money at risk) and wait for an explicit yes.
- The server enforces safety limits (demo account only unless allowed, max lots, max risk per trade,
  max open positions and pending orders, mandatory stop loss). Never try to work around a refusal;
  explain it instead.
- Candle and price times are in the broker's server time.
- Be honest about uncertainty: no analysis guarantees a profit.
"""

server = MCPServer("metatrader5", instructions=INSTRUCTIONS)

READ_ONLY = ToolAnnotations(readOnlyHint=True, openWorldHint=True)
TRADING = ToolAnnotations(readOnlyHint=False, destructiveHint=True, idempotentHint=False, openWorldHint=True)


# ── Helpers ─────────────────────────────────────────────────────────


def _refuse(message: str) -> NoReturn:
    log.warning("REFUSED %s", message)
    raise ToolError(message)


def _connect() -> None:
    """Connects to the running terminal once; later calls reuse the connection."""
    if mt5.terminal_info() is not None:
        return
    connected = mt5.initialize(path=TERMINAL_PATH) if TERMINAL_PATH else mt5.initialize()
    if not connected:
        raise ToolError(
            f"Cannot connect to MetaTrader 5 ({mt5.last_error()}). "
            "Check that the terminal is open and logged in to an account."
        )


def _account() -> Any:
    _connect()
    account = mt5.account_info()
    if account is None:
        raise ToolError(f"Cannot read the account ({mt5.last_error()}). Is the terminal logged in?")
    return account


def _is_demo(account: Any) -> bool:
    return account.trade_mode == mt5.ACCOUNT_TRADE_MODE_DEMO


def _trading_account() -> Any:
    """Returns the account if this server may trade on it, otherwise refuses."""
    account = _account()
    if not _is_demo(account) and not ALLOW_REAL_ACCOUNT:
        _refuse("This is a REAL account. This server only trades demo accounts (MT5_ALLOW_REAL_ACCOUNT is not 'true').")
    terminal = mt5.terminal_info()
    if terminal is not None and not terminal.trade_allowed:
        _refuse("Algo Trading is disabled in the MetaTrader 5 terminal (toolbar button 'Algo Trading').")
    return account


def _symbol(symbol: str) -> Any:
    _connect()
    info = mt5.symbol_info(symbol)
    if info is None:
        raise ToolError(f"Unknown symbol '{symbol}'. Use the exact name shown in the Market Watch window.")
    if not info.visible and not mt5.symbol_select(symbol, True):
        raise ToolError(f"Cannot add {symbol} to the Market Watch window.")
    return info


def _tick(symbol: str) -> Any:
    tick = mt5.symbol_info_tick(symbol)
    if tick is None or tick.bid <= 0 or tick.ask <= 0:
        raise ToolError(f"No current price for {symbol}. The market may be closed.")
    return tick


def _position(ticket: int) -> Any:
    _connect()
    positions = mt5.positions_get(ticket=ticket)
    if not positions:
        raise ToolError(f"No open position with ticket {ticket}.")
    return positions[0]


def _pip_size(info: Any) -> float:
    return info.point * 10 if info.digits in (3, 5) else info.point


def _server_time(timestamp: int) -> str:
    # MetaTrader returns the broker's server time as Unix seconds
    return dt.datetime.fromtimestamp(timestamp, dt.timezone.utc).strftime("%Y-%m-%d %H:%M")


def _filling_type(info: Any) -> int:
    # symbol_info().filling_mode is a bit mask: 1 = fill or kill allowed, 2 = immediate or cancel allowed
    if info.filling_mode & 1:
        return mt5.ORDER_FILLING_FOK
    if info.filling_mode & 2:
        return mt5.ORDER_FILLING_IOC
    return mt5.ORDER_FILLING_RETURN


def _normalize_volume(info: Any, volume: float) -> float:
    """Rounds a volume down to the symbol's volume step."""
    step = info.volume_step
    digits = max(0, -math.floor(math.log10(step))) if step < 1 else 0
    return round(math.floor(volume / step + 1e-9) * step, digits)


def _order_type(side: Side) -> int:
    return mt5.ORDER_TYPE_BUY if side == "buy" else mt5.ORDER_TYPE_SELL


def _loss_at_stop(side: Side, symbol: str, volume: float, price: float, stop_loss: float) -> float:
    """Money lost, in the account currency, if the price moves from price to stop_loss."""
    profit = mt5.order_calc_profit(_order_type(side), symbol, volume, price, stop_loss)
    if profit is None:
        raise ToolError(f"Cannot calculate the risk of this trade ({mt5.last_error()}).")
    return -profit


def _check_levels(side: Side, info: Any, price: float, stop_loss: float, take_profit: float,
                  reference: str = "current price") -> None:
    """Checks that SL and TP are on the correct side of price and far enough from it."""
    if stop_loss <= 0:
        _refuse("A stop loss is required on every position.")
    if side == "buy" and stop_loss >= price:
        _refuse(f"For a buy, the stop loss must be below the {reference} ({price}).")
    if side == "sell" and stop_loss <= price:
        _refuse(f"For a sell, the stop loss must be above the {reference} ({price}).")
    if take_profit and side == "buy" and take_profit <= price:
        _refuse(f"For a buy, the take profit must be above the {reference} ({price}).")
    if take_profit and side == "sell" and take_profit >= price:
        _refuse(f"For a sell, the take profit must be below the {reference} ({price}).")

    min_distance = info.trade_stops_level * info.point
    if abs(price - stop_loss) < min_distance or (take_profit and abs(take_profit - price) < min_distance):
        _refuse(f"Stop loss and take profit must be at least {info.trade_stops_level} points from the {reference}.")


def _check_new_order(info: Any, symbol: str, side: Side, volume: float) -> float:
    """Checks the symbol, the volume and the number of open trades; returns the normalised volume."""
    allowed_modes = {mt5.SYMBOL_TRADE_MODE_FULL,
                     mt5.SYMBOL_TRADE_MODE_LONGONLY if side == "buy" else mt5.SYMBOL_TRADE_MODE_SHORTONLY}
    if info.trade_mode not in allowed_modes:
        _refuse(f"{side} trades are not allowed on {symbol} right now.")

    volume = _normalize_volume(info, volume)
    if volume < info.volume_min:
        _refuse(f"Volume below the minimum of {info.volume_min} lots for {symbol}.")
    if volume > MAX_LOTS:
        _refuse(f"{volume} lots is above the limit of {MAX_LOTS} lots per order.")

    open_trades = mt5.positions_total() + mt5.orders_total()
    if open_trades >= MAX_OPEN_POSITIONS:
        _refuse(f"{open_trades} positions and pending orders are already open; the limit is {MAX_OPEN_POSITIONS}.")
    return volume


def _check_risk(account: Any, side: Side, symbol: str, volume: float, entry: float, stop_loss: float) -> tuple[float, float]:
    """Refuses a trade that would lose more than the max risk at its stop loss."""
    risk_money = _loss_at_stop(side, symbol, volume, entry, stop_loss)
    risk_percent = risk_money / account.balance * 100
    if risk_percent > MAX_RISK_PERCENT + 1e-9:
        _refuse(f"This trade risks {risk_money:.2f} {account.currency} ({risk_percent:.2f} % of the balance), "
                f"above the limit of {MAX_RISK_PERCENT} %. Use calculate_lot_size to size it.")
    return risk_money, risk_percent


def _send(request: dict[str, Any], action: str) -> Any:
    result = mt5.order_send(request)
    if (result is not None and result.retcode == RETCODE_INVALID_FILL
            and request.get("type_filling") != mt5.ORDER_FILLING_RETURN):
        # some brokers only accept the "return" filling type, notably for pending orders
        request = {**request, "type_filling": mt5.ORDER_FILLING_RETURN}
        result = mt5.order_send(request)
    if result is None:
        raise ToolError(f"{action}: order not sent ({mt5.last_error()}).")
    if result.retcode != mt5.TRADE_RETCODE_DONE:
        log.warning("%s REJECTED retcode %s %s request %s", action, result.retcode, result.comment, request)
        raise ToolError(f"{action}: rejected by the broker (code {result.retcode}: {result.comment}).")
    return result


def _position_dict(position: Any) -> dict[str, Any]:
    return {
        "ticket": position.ticket,
        "symbol": position.symbol,
        "side": "buy" if position.type == mt5.POSITION_TYPE_BUY else "sell",
        "volume": position.volume,
        "open_price": position.price_open,
        "current_price": position.price_current,
        "stop_loss": position.sl,
        "take_profit": position.tp,
        "profit": position.profit,
        "swap": position.swap,
        "opened": _server_time(position.time),
        "opened_by_claude": position.magic == MAGIC_NUMBER,
        "comment": position.comment,
    }


def _order_dict(order: Any) -> dict[str, Any]:
    return {
        "ticket": order.ticket,
        "symbol": order.symbol,
        "type": PENDING_NAMES.get(order.type, str(order.type)),
        "volume": order.volume_current,
        "price": order.price_open,
        "stop_loss": order.sl,
        "take_profit": order.tp,
        "placed": _server_time(order.time_setup),
        "expires": _server_time(order.time_expiration) if order.time_expiration else "when cancelled",
        "placed_by_claude": order.magic == MAGIC_NUMBER,
        "comment": order.comment,
    }


# ── Indicators (computed on closed candles, oldest first) ───────────


def _ema(values: list[float], period: int) -> list[float]:
    """Exponential moving average seeded with the simple average of the first `period` values.
    The result starts at index period - 1 of `values`."""
    if len(values) < period:
        return []
    alpha = 2 / (period + 1)
    result = [sum(values[:period]) / period]
    for value in values[period:]:
        result.append(alpha * value + (1 - alpha) * result[-1])
    return result


def _rsi(closes: list[float], period: int = 14) -> float | None:
    """Relative Strength Index with Wilder's smoothing."""
    if len(closes) <= period:
        return None
    changes = [closes[i] - closes[i - 1] for i in range(1, len(closes))]
    avg_gain = sum(max(c, 0.0) for c in changes[:period]) / period
    avg_loss = sum(max(-c, 0.0) for c in changes[:period]) / period
    for change in changes[period:]:
        avg_gain = (avg_gain * (period - 1) + max(change, 0.0)) / period
        avg_loss = (avg_loss * (period - 1) + max(-change, 0.0)) / period
    if avg_loss == 0:
        return 100.0
    return 100 - 100 / (1 + avg_gain / avg_loss)


def _atr(highs: list[float], lows: list[float], closes: list[float], period: int = 14) -> float | None:
    """Average True Range with Wilder's smoothing."""
    if len(closes) <= period:
        return None
    ranges = [max(highs[i] - lows[i], abs(highs[i] - closes[i - 1]), abs(lows[i] - closes[i - 1]))
              for i in range(1, len(closes))]
    atr = sum(ranges[:period]) / period
    for true_range in ranges[period:]:
        atr = (atr * (period - 1) + true_range) / period
    return atr


def _bollinger(closes: list[float], period: int = 20, width: float = 2.0) -> tuple[float, float, float]:
    window = closes[-period:]
    middle = sum(window) / period
    deviation = math.sqrt(sum((c - middle) ** 2 for c in window) / period)
    return middle + width * deviation, middle, middle - width * deviation


# ── Read-only tools ─────────────────────────────────────────────────


@server.tool(annotations=READ_ONLY)
def get_account_info() -> dict[str, Any]:
    """Balance, equity, free margin, leverage and currency of the account, whether it is a demo
    account, and the safety limits this server enforces on every order."""
    account = _account()
    return {
        "login": account.login,
        "server": account.server,
        "type": "demo" if _is_demo(account) else "REAL",
        "currency": account.currency,
        "balance": account.balance,
        "equity": account.equity,
        "margin": account.margin,
        "free_margin": account.margin_free,
        "leverage": account.leverage,
        "open_positions": mt5.positions_total(),
        "pending_orders": mt5.orders_total(),
        "safety_limits": {
            "real_account_trading_allowed": ALLOW_REAL_ACCOUNT,
            "max_lots_per_order": MAX_LOTS,
            "max_open_positions_and_pending_orders": MAX_OPEN_POSITIONS,
            "max_risk_percent_per_trade": MAX_RISK_PERCENT,
            "stop_loss_required": True,
        },
    }


@server.tool(annotations=READ_ONLY)
def get_price(symbol: str) -> dict[str, Any]:
    """Current bid and ask price, spread and trading specifications of a symbol, e.g. "EURUSD"."""
    info = _symbol(symbol)
    tick = _tick(symbol)
    pip = _pip_size(info)
    return {
        "symbol": symbol,
        "bid": tick.bid,
        "ask": tick.ask,
        "spread_pips": round((tick.ask - tick.bid) / pip, 1),
        "pip_size": pip,
        "digits": info.digits,
        "min_lots": info.volume_min,
        "lot_step": info.volume_step,
        "min_stop_distance_points": info.trade_stops_level,
        "server_time": _server_time(tick.time),
    }


@server.tool(annotations=READ_ONLY)
def get_candles(symbol: str, timeframe: Timeframe = "H1", count: int = 100) -> dict[str, Any]:
    """Most recent candles of a symbol, oldest first; the last one is still forming.
    count is capped at 500."""
    _symbol(symbol)
    count = max(1, min(int(count), 500))
    rates = mt5.copy_rates_from_pos(symbol, TIMEFRAMES[timeframe], 0, count)
    if rates is None or len(rates) == 0:
        raise ToolError(f"No candles for {symbol} {timeframe} ({mt5.last_error()}).")
    candles = [
        {
            "time": _server_time(int(rate["time"])),
            "open": float(rate["open"]),
            "high": float(rate["high"]),
            "low": float(rate["low"]),
            "close": float(rate["close"]),
            "tick_volume": int(rate["tick_volume"]),
        }
        for rate in rates
    ]
    return {"symbol": symbol, "timeframe": timeframe, "time_zone": "broker server time", "candles": candles}


@server.tool(annotations=READ_ONLY)
def get_indicators(symbol: str, timeframe: Timeframe = "H1") -> dict[str, Any]:
    """Common indicators on the last CLOSED candle of a symbol: EMA 20/50/200, RSI 14, ATR 14,
    MACD 12/26/9, Bollinger Bands 20/2, and the highest high / lowest low of the last 20 candles.
    Use these values instead of estimating indicators from raw candles."""
    info = _symbol(symbol)
    # start at 1 to skip the candle that is still forming
    rates = mt5.copy_rates_from_pos(symbol, TIMEFRAMES[timeframe], 1, 600)
    if rates is None or len(rates) < 210:
        raise ToolError(f"Not enough history for {symbol} {timeframe}: 210 closed candles are needed.")

    closes = [float(r["close"]) for r in rates]
    highs = [float(r["high"]) for r in rates]
    lows = [float(r["low"]) for r in rates]
    digits = info.digits

    macd_line = [fast - slow for fast, slow in zip(_ema(closes, 12)[14:], _ema(closes, 26))]
    macd_signal = _ema(macd_line, 9)
    upper, middle, lower = _bollinger(closes)
    atr = _atr(highs, lows, closes)
    rsi = _rsi(closes)

    return {
        "symbol": symbol,
        "timeframe": timeframe,
        "candle_time": _server_time(int(rates[-1]["time"])),
        "close": closes[-1],
        "ema_20": round(_ema(closes, 20)[-1], digits),
        "ema_50": round(_ema(closes, 50)[-1], digits),
        "ema_200": round(_ema(closes, 200)[-1], digits),
        "rsi_14": round(rsi, 1) if rsi is not None else None,
        "atr_14": round(atr, digits) if atr is not None else None,
        "atr_14_pips": round(atr / _pip_size(info), 1) if atr is not None else None,
        "macd_12_26_9": {
            "line": round(macd_line[-1], digits + 2),
            "signal": round(macd_signal[-1], digits + 2),
            "histogram": round(macd_line[-1] - macd_signal[-1], digits + 2),
        },
        "bollinger_20_2": {
            "upper": round(upper, digits),
            "middle": round(middle, digits),
            "lower": round(lower, digits),
        },
        "highest_high_20": max(highs[-20:]),
        "lowest_low_20": min(lows[-20:]),
        "time_zone": "broker server time",
    }


@server.tool(annotations=READ_ONLY)
def get_pending_orders(symbol: str | None = None) -> dict[str, Any]:
    """Pending orders (limit and stop orders not filled yet), optionally for one symbol only."""
    _connect()
    orders = mt5.orders_get(symbol=symbol) if symbol else mt5.orders_get()
    if orders is None:
        raise ToolError(f"Cannot read the pending orders ({mt5.last_error()}).")
    return {"count": len(orders), "orders": [_order_dict(o) for o in orders]}


@server.tool(annotations=READ_ONLY)
def get_positions(symbol: str | None = None) -> dict[str, Any]:
    """Open positions, optionally for one symbol only, with their stop loss, take profit and
    floating profit."""
    _connect()
    positions = mt5.positions_get(symbol=symbol) if symbol else mt5.positions_get()
    if positions is None:
        raise ToolError(f"Cannot read the open positions ({mt5.last_error()}).")
    return {"count": len(positions), "positions": [_position_dict(p) for p in positions]}


@server.tool(annotations=READ_ONLY)
def get_trade_history(days: int = 7) -> dict[str, Any]:
    """Trades closed during the last N days (1 to 90), with their result, to review past decisions.
    Returns at most the 50 most recent trades."""
    _connect()
    days = max(1, min(int(days), 90))
    # server time can be ahead of local time: widen the window by one day on each side
    date_to = dt.datetime.now() + dt.timedelta(days=1)
    date_from = date_to - dt.timedelta(days=days + 1)
    deals = mt5.history_deals_get(date_from, date_to)
    if deals is None:
        raise ToolError(f"Cannot read the trade history ({mt5.last_error()}).")

    closed = [d for d in deals if d.entry in (mt5.DEAL_ENTRY_OUT, mt5.DEAL_ENTRY_OUT_BY)]
    results = [d.profit + d.commission + d.swap for d in closed]
    trades = [
        {
            "closed": _server_time(d.time),
            "symbol": d.symbol,
            # the closing deal goes the other way: a sell closes a buy position
            "position_side": "buy" if d.type == mt5.DEAL_TYPE_SELL else "sell",
            "volume": d.volume,
            "close_price": d.price,
            "result": round(r, 2),
            "opened_by_claude": d.magic == MAGIC_NUMBER,
        }
        for d, r in zip(closed, results)
    ][-50:]
    return {
        "days": days,
        "closed_trades": len(closed),
        "wins": sum(1 for r in results if r > 0),
        "losses": sum(1 for r in results if r < 0),
        "net_result": round(sum(results), 2),
        "trades": trades,
    }


@server.tool(annotations=READ_ONLY)
def calculate_lot_size(
    symbol: str, side: Side, stop_loss: float, risk_percent: float = 1.0, entry_price: float = 0.0
) -> dict[str, Any]:
    """Lot size so that hitting stop_loss from the entry loses risk_percent of the balance.
    entry_price 0 = the current price (market order); set it to the order price for a pending order.
    The risk is capped by this server's max risk per trade and the lots by its max lots per order."""
    account = _account()
    info = _symbol(symbol)
    if entry_price > 0:
        price = round(entry_price, info.digits)
        _check_levels(side, info, price, stop_loss, 0.0, "entry price")
    else:
        tick = _tick(symbol)
        price = tick.ask if side == "buy" else tick.bid
        _check_levels(side, info, price, stop_loss, 0.0)

    loss_per_lot = _loss_at_stop(side, symbol, 1.0, price, stop_loss)
    if loss_per_lot <= 0:
        raise ToolError("Cannot calculate the risk of this stop loss.")

    risk_percent = min(max(risk_percent, 0.0), MAX_RISK_PERCENT)
    wanted = account.balance * risk_percent / 100 / loss_per_lot
    lots = _normalize_volume(info, min(wanted, MAX_LOTS, info.volume_max))
    result: dict[str, Any] = {
        "symbol": symbol,
        "side": side,
        "entry_price": price,
        "stop_loss": stop_loss,
        "stop_distance_pips": round(abs(price - stop_loss) / _pip_size(info), 1),
        "currency": account.currency,
        "capped_by_max_lots": wanted > MAX_LOTS,
    }
    if lots < info.volume_min:
        result.update(lots=0.0, note=f"Even the minimum of {info.volume_min} lots risks more than "
                                     f"{risk_percent} % with this stop loss. Use a closer stop or skip the trade.")
        return result

    risk_money = loss_per_lot * lots
    result.update(lots=lots, risk_money=round(risk_money, 2), risk_percent=round(risk_money / account.balance * 100, 2))
    return result


# ── Trading tools ───────────────────────────────────────────────────


@server.tool(annotations=TRADING)
def open_position(
    symbol: str,
    side: Side,
    volume: float,
    stop_loss: float,
    take_profit: float = 0.0,
    comment: str = "Claude MCP",
) -> dict[str, Any]:
    """Opens a market position with a mandatory stop loss (take_profit 0 = none).
    Only call it after the user has explicitly approved this exact trade. Refused on real accounts,
    above the lot, risk or open position limits, or with an invalid stop loss or take profit."""
    account = _trading_account()
    info = _symbol(symbol)
    volume = _check_new_order(info, symbol, side, volume)

    tick = _tick(symbol)
    price = tick.ask if side == "buy" else tick.bid
    stop_loss = round(stop_loss, info.digits)
    take_profit = round(take_profit, info.digits) if take_profit else 0.0
    _check_levels(side, info, price, stop_loss, take_profit)
    risk_money, risk_percent = _check_risk(account, side, symbol, volume, price, stop_loss)

    result = _send(
        {
            "action": mt5.TRADE_ACTION_DEAL,
            "symbol": symbol,
            "volume": volume,
            "type": _order_type(side),
            "price": price,
            "sl": stop_loss,
            "tp": take_profit,
            "deviation": DEVIATION_POINTS,
            "magic": MAGIC_NUMBER,
            "comment": comment[:31],
            "type_time": mt5.ORDER_TIME_GTC,
            "type_filling": _filling_type(info),
        },
        "Open position",
    )
    log.info("OPEN %s %s %.2f lots @ %s SL %s TP %s risk %.2f %s (%.2f %%) ticket %s",
             side, symbol, volume, result.price, stop_loss, take_profit, risk_money, account.currency,
             risk_percent, result.order)
    return {
        "status": "opened",
        "ticket": result.order,
        "symbol": symbol,
        "side": side,
        "volume": result.volume,
        "price": result.price,
        "stop_loss": stop_loss,
        "take_profit": take_profit,
        "risk_money": round(risk_money, 2),
        "risk_percent": round(risk_percent, 2),
    }


@server.tool(annotations=TRADING)
def place_pending_order(
    symbol: str,
    order_type: PendingType,
    volume: float,
    price: float,
    stop_loss: float,
    take_profit: float = 0.0,
    expiration_hours: float = 0.0,
    comment: str = "Claude MCP",
) -> dict[str, Any]:
    """Places a pending order with a mandatory stop loss: buy_limit below the current price,
    sell_limit above it, buy_stop above it, sell_stop below it. take_profit 0 = none,
    expiration_hours 0 = until cancelled. Only call it after the user has explicitly approved this
    exact order. The same safety limits as open_position apply, with the risk measured from price."""
    account = _trading_account()
    info = _symbol(symbol)
    side: Side = "buy" if order_type.startswith("buy") else "sell"
    volume = _check_new_order(info, symbol, side, volume)

    tick = _tick(symbol)
    market = tick.ask if side == "buy" else tick.bid
    price = round(price, info.digits)
    must_be_below = order_type in ("buy_limit", "sell_stop")
    if (must_be_below and price >= market) or (not must_be_below and price <= market):
        _refuse(f"A {order_type} must be {'below' if must_be_below else 'above'} the current price ({market}).")
    if abs(price - market) < info.trade_stops_level * info.point:
        _refuse(f"The order price must be at least {info.trade_stops_level} points from the current price.")

    stop_loss = round(stop_loss, info.digits)
    take_profit = round(take_profit, info.digits) if take_profit else 0.0
    _check_levels(side, info, price, stop_loss, take_profit, "order price")
    risk_money, risk_percent = _check_risk(account, side, symbol, volume, price, stop_loss)

    request: dict[str, Any] = {
        "action": mt5.TRADE_ACTION_PENDING,
        "symbol": symbol,
        "volume": volume,
        "type": PENDING_TYPES[order_type],
        "price": price,
        "sl": stop_loss,
        "tp": take_profit,
        "deviation": DEVIATION_POINTS,
        "magic": MAGIC_NUMBER,
        "comment": comment[:31],
        "type_time": mt5.ORDER_TIME_GTC,
        "type_filling": _filling_type(info),
    }
    if expiration_hours > 0:
        if not info.expiration_mode & EXPIRATION_SPECIFIED_FLAG:
            _refuse(f"The broker does not accept an expiration time on {symbol}. "
                    "Use expiration_hours = 0 and cancel the order later.")
        request["type_time"] = mt5.ORDER_TIME_SPECIFIED
        request["expiration"] = int(tick.time + expiration_hours * 3600)

    result = _send(request, "Place pending order")
    log.info("PENDING %s %s %.2f lots @ %s SL %s TP %s risk %.2f %s (%.2f %%) ticket %s",
             order_type, symbol, volume, price, stop_loss, take_profit, risk_money, account.currency,
             risk_percent, result.order)
    return {
        "status": "placed",
        "ticket": result.order,
        "symbol": symbol,
        "type": order_type,
        "volume": volume,
        "price": price,
        "stop_loss": stop_loss,
        "take_profit": take_profit,
        "expires": _server_time(request["expiration"]) if "expiration" in request else "when cancelled",
        "risk_money": round(risk_money, 2),
        "risk_percent": round(risk_percent, 2),
    }


@server.tool(annotations=TRADING)
def cancel_pending_order(ticket: int) -> dict[str, Any]:
    """Cancels a pending order. Only call it after the user has explicitly approved it."""
    _trading_account()
    orders = mt5.orders_get(ticket=ticket)
    if not orders:
        raise ToolError(f"No pending order with ticket {ticket}.")
    _send({"action": mt5.TRADE_ACTION_REMOVE, "order": ticket}, "Cancel pending order")
    log.info("CANCEL pending order #%s %s", ticket, orders[0].symbol)
    return {"status": "cancelled", "ticket": ticket, "symbol": orders[0].symbol}


@server.tool(annotations=TRADING)
def modify_position(ticket: int, stop_loss: float, take_profit: float = 0.0) -> dict[str, Any]:
    """Changes the stop loss and take profit of an open position (take_profit 0 = none).
    The stop loss cannot be removed, and a new stop loss may not risk more than the max risk per trade.
    Only call it after the user has explicitly approved the change."""
    account = _trading_account()
    position = _position(ticket)
    info = _symbol(position.symbol)
    tick = _tick(position.symbol)
    side: Side = "buy" if position.type == mt5.POSITION_TYPE_BUY else "sell"
    price = tick.bid if side == "buy" else tick.ask  # the price that would close the position
    stop_loss = round(stop_loss, info.digits)
    take_profit = round(take_profit, info.digits) if take_profit else 0.0
    _check_levels(side, info, price, stop_loss, take_profit)

    risk_money = _loss_at_stop(side, position.symbol, position.volume, position.price_open, stop_loss)
    if risk_money / account.balance * 100 > MAX_RISK_PERCENT + 1e-9:
        _refuse(f"This stop loss would risk {risk_money:.2f} {account.currency} from the entry price, "
                f"above the limit of {MAX_RISK_PERCENT} % of the balance.")

    _send(
        {
            "action": mt5.TRADE_ACTION_SLTP,
            "position": ticket,
            "symbol": position.symbol,
            "sl": stop_loss,
            "tp": take_profit,
            "magic": MAGIC_NUMBER,
        },
        "Modify position",
    )
    log.info("MODIFY #%s %s SL %s -> %s TP %s -> %s", ticket, position.symbol, position.sl, stop_loss,
             position.tp, take_profit)
    return {"status": "modified", "ticket": ticket, "stop_loss": stop_loss, "take_profit": take_profit}


@server.tool(annotations=TRADING)
def close_position(ticket: int) -> dict[str, Any]:
    """Closes an open position at the market price.
    Only call it after the user has explicitly approved closing this position."""
    _trading_account()
    position = _position(ticket)
    info = _symbol(position.symbol)
    tick = _tick(position.symbol)
    is_buy = position.type == mt5.POSITION_TYPE_BUY

    result = _send(
        {
            "action": mt5.TRADE_ACTION_DEAL,
            "position": ticket,
            "symbol": position.symbol,
            "volume": position.volume,
            "type": mt5.ORDER_TYPE_SELL if is_buy else mt5.ORDER_TYPE_BUY,
            "price": tick.bid if is_buy else tick.ask,
            "deviation": DEVIATION_POINTS,
            "magic": MAGIC_NUMBER,
            "comment": "closed by Claude MCP",
            "type_time": mt5.ORDER_TIME_GTC,
            "type_filling": _filling_type(info),
        },
        "Close position",
    )
    log.info("CLOSE #%s %s %.2f lots @ %s floating profit before close %.2f", ticket, position.symbol,
             position.volume, result.price, position.profit)
    return {
        "status": "closed",
        "ticket": ticket,
        "symbol": position.symbol,
        "close_price": result.price,
        "profit_before_close": position.profit,
    }


def main() -> None:
    atexit.register(mt5.shutdown)
    log.info("server started: real account trading %s, max %.2f lots, max %d positions, max risk %.2f %%",
             "ALLOWED" if ALLOW_REAL_ACCOUNT else "blocked", MAX_LOTS, MAX_OPEN_POSITIONS, MAX_RISK_PERCENT)
    server.run()


if __name__ == "__main__":
    main()
