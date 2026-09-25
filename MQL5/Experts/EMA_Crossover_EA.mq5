//+------------------------------------------------------------------+
//|                                             EMA_Crossover_EA.mq5 |
//|                  Long-only EMA 40 / EMA 200 crossover strategy   |
//+------------------------------------------------------------------+
#property copyright   "bts-cg-claude-study"
#property version     "1.20"
#property description "Opens a long position every time the fast EMA (default 40) crosses above"
#property description "the slow EMA (default 200). Fixed or ATR based SL/TP, fixed or risk based lots,"
#property description "break-even, trailing stop, trend and cooldown filters, trading hours and days."
#property description "Orders are sent via CTrade."

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Enums                                                            |
//+------------------------------------------------------------------+
enum ENUM_STOP_MODE
  {
   STOP_MODE_PIPS = 0,   // Fixed pips
   STOP_MODE_ATR  = 1    // ATR multiple
  };

enum ENUM_LOT_MODE
  {
   LOT_MODE_FIXED = 0,   // Fixed lots
   LOT_MODE_RISK  = 1    // Risk % of balance
  };

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "Strategy"
input ENUM_TIMEFRAMES    InpTimeframe       = PERIOD_CURRENT;  // Signal timeframe
input int                InpFastEMAPeriod   = 40;              // Fast EMA period
input int                InpSlowEMAPeriod   = 200;             // Slow EMA period
input ENUM_APPLIED_PRICE InpAppliedPrice    = PRICE_CLOSE;     // EMA applied price

input group "Signal filters"
input bool               InpUseTrendFilter  = false;           // Only buy when the slow EMA is rising
input int                InpTrendSlopeBars  = 10;              // Slow EMA slope lookback (bars)
input int                InpCooldownBars    = 0;               // Min bars between two entries (0 = off)

input group "Trade management"
input ENUM_LOT_MODE      InpLotMode         = LOT_MODE_FIXED;  // Lot size mode
input double             InpLotSize         = 0.5;             // Lot size (fixed mode)
input double             InpRiskPercent     = 1.0;             // Risk per trade, % of balance (risk mode)
input ENUM_STOP_MODE     InpStopMode        = STOP_MODE_PIPS;  // SL/TP mode
input double             InpStopLossPips    = 20.0;            // Stop loss in pips (0 = no SL)
input double             InpTakeProfitPips  = 40.0;            // Take profit in pips (0 = no TP)
input int                InpATRPeriod       = 14;              // ATR period (ATR mode)
input double             InpATRStopMult     = 1.5;             // Stop loss = ATR x (ATR mode, 0 = no SL)
input double             InpATRTakeMult     = 3.0;             // Take profit = ATR x (ATR mode, 0 = no TP)
input int                InpMaxPositions    = 0;               // Max open positions (0 = unlimited)
input int                InpPointsPerPip    = 0;               // Points per pip (0 = auto-detect)
input ulong              InpMagicNumber     = 402000;          // Magic number
input uint               InpSlippagePoints  = 10;              // Max slippage (points)
input string             InpOrderComment    = "EMA Cross EA";  // Order comment

input group "Break-even"
input bool               InpUseBreakEven    = false;           // Move SL to break-even
input double             InpBreakEvenTriggerR = 1.0;           // Profit that triggers break-even (x SL distance)
input double             InpBreakEvenLock   = 2.0;             // Pips locked above entry price

input group "Trailing stop"
input bool               InpUseTrailingStop = false;           // Use trailing stop
input double             InpTrailingStart   = 25.0;            // Profit that starts trailing (pips)
input double             InpTrailingDistance = 15.0;           // Distance between price and SL (pips)
input double             InpTrailingStep    = 5.0;             // Minimum SL improvement (pips)

input group "Trading hours (broker server time)"
input bool               InpUseTradingHours = true;            // Restrict trading to a time window
input int                InpStartHour       = 8;               // Start hour (0-23)
input int                InpStartMinute     = 0;               // Start minute (0-59)
input int                InpEndHour         = 20;              // End hour (0-23), exclusive
input int                InpEndMinute       = 0;               // End minute (0-59)

input group "Trading days"
input bool               InpTradeMonday     = true;            // Trade on Monday
input bool               InpTradeTuesday    = true;            // Trade on Tuesday
input bool               InpTradeWednesday  = true;            // Trade on Wednesday
input bool               InpTradeThursday   = true;            // Trade on Thursday
input bool               InpTradeFriday     = true;            // Trade on Friday
input bool               InpTradeSaturday   = false;           // Trade on Saturday
input bool               InpTradeSunday     = false;           // Trade on Sunday

input group "Display"
input bool               InpShowPanel       = true;            // Show info panel on chart

//+------------------------------------------------------------------+
//| Constants                                                        |
//+------------------------------------------------------------------+
#define EA_NAME            "EMA Crossover EA"
#define MAX_SEND_ATTEMPTS  3      // attempts for transient errors (requote, price changed ...)
#define RETRY_DELAY_MS     300
#define PANEL_REFRESH_MS   1000
#define MODIFY_RETRY_SEC   10     // pause after a rejected SL modification

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
CTrade          g_trade;
ENUM_TIMEFRAMES g_timeframe      = PERIOD_CURRENT;
int             g_fastHandle     = INVALID_HANDLE;
int             g_slowHandle     = INVALID_HANDLE;
int             g_atrHandle      = INVALID_HANDLE;
datetime        g_lastBarTime    = 0;   // open time of the last processed signal bar
datetime        g_lastSignalTime = 0;   // close bar time of the last detected crossover
double          g_pipSize        = 0.0; // price distance of one pip
double          g_lotSize        = 0.0; // fixed lot size normalised to the symbol's volume rules

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(!ValidateInputs())
      return(INIT_PARAMETERS_INCORRECT);

   g_timeframe = (InpTimeframe == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)_Period : InpTimeframe;
   g_pipSize   = CalculatePipSize();

   if(InpLotMode == LOT_MODE_FIXED)
     {
      g_lotSize = NormalizeVolume(InpLotSize);
      if(g_lotSize <= 0.0)
        {
         PrintFormat("%s: lot size %.2f is not valid for %s", EA_NAME, InpLotSize, _Symbol);
         return(INIT_PARAMETERS_INCORRECT);
        }
      if(MathAbs(g_lotSize - InpLotSize) > 1e-8)
         PrintFormat("%s: lot size %.2f adjusted to %.2f to match the volume limits of %s",
                     EA_NAME, InpLotSize, g_lotSize, _Symbol);
     }

   g_fastHandle = iMA(_Symbol, g_timeframe, InpFastEMAPeriod, 0, MODE_EMA, InpAppliedPrice);
   g_slowHandle = iMA(_Symbol, g_timeframe, InpSlowEMAPeriod, 0, MODE_EMA, InpAppliedPrice);
   if(g_fastHandle == INVALID_HANDLE || g_slowHandle == INVALID_HANDLE)
     {
      PrintFormat("%s: failed to create EMA indicator handles (error %d)", EA_NAME, GetLastError());
      return(INIT_FAILED);
     }

   if(InpStopMode == STOP_MODE_ATR)
     {
      g_atrHandle = iATR(_Symbol, g_timeframe, InpATRPeriod);
      if(g_atrHandle == INVALID_HANDLE)
        {
         PrintFormat("%s: failed to create ATR indicator handle (error %d)", EA_NAME, GetLastError());
         return(INIT_FAILED);
        }
     }

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);

//--- do not act on a crossover that completed before the EA was attached
   g_lastBarTime = iTime(_Symbol, g_timeframe, 0);

   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING && InpMaxPositions != 1)
      PrintFormat("%s: netting account - a new signal adds to the existing position and replaces its SL/TP",
                  EA_NAME);

   PrintFormat("%s started on %s %s | EMA %d/%d | %s | %s | 1 pip = %s",
               EA_NAME, _Symbol, TimeframeToString(g_timeframe), InpFastEMAPeriod, InpSlowEMAPeriod,
               LotDescription(), StopsDescription(), DoubleToString(g_pipSize, _Digits));
   PrintFormat("%s: %s", EA_NAME, OptionsDescription());

   UpdatePanel(true);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_fastHandle != INVALID_HANDLE)
      IndicatorRelease(g_fastHandle);
   if(g_slowHandle != INVALID_HANDLE)
      IndicatorRelease(g_slowHandle);
   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);
   g_fastHandle = INVALID_HANDLE;
   g_slowHandle = INVALID_HANDLE;
   g_atrHandle  = INVALID_HANDLE;

   Comment("");
  }

//+------------------------------------------------------------------+
//| Expert tick                                                      |
//+------------------------------------------------------------------+
void OnTick()
  {
   ManageOpenPositions();
   CheckForSignal();
   UpdatePanel(false);
  }

//+------------------------------------------------------------------+
//| Evaluates the crossover once per new bar of the signal timeframe |
//+------------------------------------------------------------------+
void CheckForSignal()
  {
   datetime barTime = iTime(_Symbol, g_timeframe, 0);
   if(barTime == 0 || barTime == g_lastBarTime)
      return;

//--- make sure the slow EMA has enough history to be meaningful
   int minBars = InpSlowEMAPeriod + (InpUseTrendFilter ? InpTrendSlopeBars : 0) + 2;
   if(Bars(_Symbol, g_timeframe) < minBars)
      return;

   double fast[], slow[];
   if(!CopyEMAValues(1, 2, fast, slow))
      return;                       // indicator not ready yet - retry on the next tick

   g_lastBarTime = barTime;

//--- index 0 = last closed bar, index 1 = the bar before it
   bool crossedUp = (fast[1] <= slow[1] && fast[0] > slow[0]);
   if(!crossedUp)
      return;

   g_lastSignalTime = iTime(_Symbol, g_timeframe, 1);
   PrintFormat("%s: bullish crossover on bar %s (fast %s > slow %s)", EA_NAME,
               TimeToString(g_lastSignalTime), DoubleToString(fast[0], _Digits), DoubleToString(slow[0], _Digits));

   if(InpUseTrendFilter && !IsSlowEMARising())
     {
      PrintFormat("%s: signal skipped - slow EMA is not rising over the last %d bars", EA_NAME, InpTrendSlopeBars);
      return;
     }

   if(InpCooldownBars > 0)
     {
      int barsSinceEntry = BarsSinceLastEntry();
      if(barsSinceEntry >= 0 && barsSinceEntry < InpCooldownBars)
        {
         PrintFormat("%s: signal skipped - last entry was %d bar(s) ago, cooldown is %d bars", EA_NAME,
                     barsSinceEntry, InpCooldownBars);
         return;
        }
     }

   if(!IsTradingTimeAllowed(TimeCurrent()))
     {
      PrintFormat("%s: signal skipped - outside the configured trading hours/days", EA_NAME);
      return;
     }

   if(InpMaxPositions > 0 && CountOpenPositions() >= InpMaxPositions)
     {
      PrintFormat("%s: signal skipped - maximum of %d open position(s) reached", EA_NAME, InpMaxPositions);
      return;
     }

   if(!IsTradingPermitted())
      return;

   OpenLong();
  }

//+------------------------------------------------------------------+
//| Opens a long position with SL/TP using CTrade                    |
//+------------------------------------------------------------------+
bool OpenLong()
  {
   double slDistance = 0.0, tpDistance = 0.0;
   if(!GetStopDistances(slDistance, tpDistance))
      return(false);

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double lots = g_lotSize;
   if(InpLotMode == LOT_MODE_RISK)
     {
      lots = CalculateRiskLots(ask, slDistance);
      if(lots <= 0.0)
         return(false);
     }

   double margin = 0.0;
   if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, lots, ask, margin))
     {
      PrintFormat("%s: margin calculation failed (error %d)", EA_NAME, GetLastError());
      return(false);
     }
   if(margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE))
     {
      PrintFormat("%s: not enough free margin for %.2f lots (required %.2f, free %.2f)", EA_NAME,
                  lots, margin, AccountInfoDouble(ACCOUNT_MARGIN_FREE));
      return(false);
     }

   for(int attempt = 1; attempt <= MAX_SEND_ATTEMPTS; attempt++)
     {
      MqlTick tick;
      if(!SymbolInfoTick(_Symbol, tick))
        {
         PrintFormat("%s: failed to get current prices (error %d)", EA_NAME, GetLastError());
         return(false);
        }

      double price = tick.ask;
      double sl    = (slDistance > 0.0) ? NormalizePrice(price - slDistance) : 0.0;
      double tp    = (tpDistance > 0.0) ? NormalizePrice(price + tpDistance) : 0.0;

      if(!CheckStopsDistance(tick, sl, tp))
         return(false);

      bool sent    = g_trade.Buy(lots, _Symbol, price, sl, tp, InpOrderComment);
      uint retcode = g_trade.ResultRetcode();
      if(sent && (retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_DONE_PARTIAL || retcode == TRADE_RETCODE_PLACED))
        {
         PrintFormat("%s: BUY %.2f %s @ %s | SL %s | TP %s | order #%I64u", EA_NAME,
                     g_trade.ResultVolume(), _Symbol, DoubleToString(g_trade.ResultPrice(), _Digits),
                     DoubleToString(sl, _Digits), DoubleToString(tp, _Digits), g_trade.ResultOrder());
         return(true);
        }

      PrintFormat("%s: buy attempt %d/%d failed - retcode %u (%s), error %d", EA_NAME, attempt,
                  MAX_SEND_ATTEMPTS, retcode, g_trade.ResultRetcodeDescription(), GetLastError());

      if(!IsRetryableRetcode(retcode))
         break;
      Sleep(RETRY_DELAY_MS);
     }

   return(false);
  }

//+------------------------------------------------------------------+
//| Break-even and trailing stop for this EA's open positions        |
//+------------------------------------------------------------------+
void ManageOpenPositions()
  {
   if((!InpUseBreakEven && !InpUseTrailingStop) || PositionsTotal() == 0)
      return;

   static datetime retryAfter = 0;
   if(TimeCurrent() < retryAfter)
      return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick) || tick.bid <= 0.0)
      return;

   double minDistance    = MathMax((double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL), 1.0) * _Point;
   double freezeDistance = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL) * _Point;
   double minStep        = InpUseTrailingStop ? MathMax(InpTrailingStep * g_pipSize, _Point) : _Point;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol ||
         PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber ||
         PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY)
         continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      double profit    = tick.bid - openPrice;
      double newSL     = currentSL;

      //--- while the SL is still below entry, its distance is the initial risk of the trade
      if(InpUseBreakEven && currentSL > 0.0 && currentSL < openPrice &&
         profit >= InpBreakEvenTriggerR * (openPrice - currentSL))
         newSL = MathMax(newSL, NormalizePrice(openPrice + InpBreakEvenLock * g_pipSize));

      if(InpUseTrailingStop && profit >= InpTrailingStart * g_pipSize)
         newSL = MathMax(newSL, NormalizePrice(tick.bid - InpTrailingDistance * g_pipSize));

      //--- only move the stop up, by at least one step, and never inside the broker's stop/freeze levels
      if(newSL <= 0.0)
         continue;
      if(currentSL > 0.0 && newSL - currentSL < minStep - _Point / 2.0)
         continue;
      if(tick.bid - newSL < minDistance)
         continue;
      if(freezeDistance > 0.0 &&
         ((currentSL > 0.0 && tick.bid - currentSL <= freezeDistance) ||
          (currentTP > 0.0 && currentTP - tick.bid <= freezeDistance)))
         continue;

      if(g_trade.PositionModify(ticket, newSL, currentTP) && g_trade.ResultRetcode() == TRADE_RETCODE_DONE)
        {
         PrintFormat("%s: position #%I64u stop loss moved from %s to %s", EA_NAME, ticket,
                     DoubleToString(currentSL, _Digits), DoubleToString(newSL, _Digits));
        }
      else
        {
         PrintFormat("%s: failed to modify position #%I64u - retcode %u (%s), retrying in %d s", EA_NAME, ticket,
                     g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription(), MODIFY_RETRY_SEC);
         retryAfter = TimeCurrent() + MODIFY_RETRY_SEC;
         return;
        }
     }
  }

//+------------------------------------------------------------------+
//| SL/TP distances from the entry price (fixed pips or ATR based)   |
//+------------------------------------------------------------------+
bool GetStopDistances(double &slDistance, double &tpDistance)
  {
   if(InpStopMode == STOP_MODE_PIPS)
     {
      slDistance = InpStopLossPips * g_pipSize;
      tpDistance = InpTakeProfitPips * g_pipSize;
      return(true);
     }

   double atr[];
   if(CopyBuffer(g_atrHandle, 0, 1, 1, atr) != 1 || atr[0] <= 0.0)
     {
      PrintFormat("%s: ATR value not available (error %d) - trade skipped", EA_NAME, GetLastError());
      return(false);
     }
   slDistance = InpATRStopMult * atr[0];
   tpDistance = InpATRTakeMult * atr[0];
   return(true);
  }

//+------------------------------------------------------------------+
//| Lot size that loses InpRiskPercent of the balance at the SL      |
//+------------------------------------------------------------------+
double CalculateRiskLots(const double price, const double slDistance)
  {
   double lossPerLot = 0.0;
   if(slDistance <= 0.0 ||
      !OrderCalcProfit(ORDER_TYPE_BUY, _Symbol, 1.0, price, price - slDistance, lossPerLot) ||
      lossPerLot >= 0.0)
     {
      PrintFormat("%s: could not calculate the loss per lot (error %d) - trade skipped", EA_NAME, GetLastError());
      return(0.0);
     }

   double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPercent / 100.0;
   double lots      = riskMoney / -lossPerLot;
   double minVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(lots < minVolume)
     {
      PrintFormat("%s: risking %.2f%% needs %.3f lots, below the minimum of %.2f - trade skipped",
                  EA_NAME, InpRiskPercent, lots, minVolume);
      return(0.0);
     }
   return(NormalizeVolume(lots));
  }

//+------------------------------------------------------------------+
//| Trend filter: slow EMA higher than it was N bars ago             |
//+------------------------------------------------------------------+
bool IsSlowEMARising()
  {
   int count = InpTrendSlopeBars + 1;
   double slow[];
   ArraySetAsSeries(slow, true);
   if(CopyBuffer(g_slowHandle, 0, 1, count, slow) != count)
      return(false);
   return(slow[0] > slow[InpTrendSlopeBars]);
  }

//+------------------------------------------------------------------+
//| Bars since this EA's last entry on the symbol, -1 if none        |
//+------------------------------------------------------------------+
int BarsSinceLastEntry()
  {
   if(!HistorySelect(0, TimeCurrent()))
      return(-1);

   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
     {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0)
         continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) == _Symbol &&
         HistoryDealGetInteger(deal, DEAL_MAGIC) == (long)InpMagicNumber &&
         HistoryDealGetInteger(deal, DEAL_ENTRY) == DEAL_ENTRY_IN)
         return(iBarShift(_Symbol, g_timeframe, (datetime)HistoryDealGetInteger(deal, DEAL_TIME)));
     }
   return(-1);
  }

//+------------------------------------------------------------------+
//| Transient trade server errors that are safe to retry             |
//+------------------------------------------------------------------+
bool IsRetryableRetcode(const uint retcode)
  {
   return(retcode == TRADE_RETCODE_REQUOTE ||
          retcode == TRADE_RETCODE_PRICE_CHANGED ||
          retcode == TRADE_RETCODE_PRICE_OFF ||
          retcode == TRADE_RETCODE_TOO_MANY_REQUESTS);
  }

//+------------------------------------------------------------------+
//| Verifies SL/TP respect the broker's minimum stop distance        |
//+------------------------------------------------------------------+
bool CheckStopsDistance(const MqlTick &tick, const double sl, const double tp)
  {
   long stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(stopsLevel <= 0)
      return(true);

   double minDistance = stopsLevel * _Point;
//--- SL/TP of a long position are triggered by the Bid price
   if(sl > 0.0 && tick.bid - sl < minDistance)
     {
      PrintFormat("%s: stop loss %s is closer than the broker minimum of %I64d points - trade skipped",
                  EA_NAME, DoubleToString(sl, _Digits), stopsLevel);
      return(false);
     }
   if(tp > 0.0 && tp - tick.bid < minDistance)
     {
      PrintFormat("%s: take profit %s is closer than the broker minimum of %I64d points - trade skipped",
                  EA_NAME, DoubleToString(tp, _Digits), stopsLevel);
      return(false);
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| Checks terminal, account and symbol permissions                  |
//+------------------------------------------------------------------+
bool IsTradingPermitted()
  {
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
     {
      PrintFormat("%s: trade skipped - Algo Trading is disabled in the terminal", EA_NAME);
      return(false);
     }
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
     {
      PrintFormat("%s: trade skipped - Algo Trading is disabled in the EA properties", EA_NAME);
      return(false);
     }
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
     {
      PrintFormat("%s: trade skipped - automated trading is not allowed on this account", EA_NAME);
      return(false);
     }
   ENUM_SYMBOL_TRADE_MODE mode = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(mode != SYMBOL_TRADE_MODE_FULL && mode != SYMBOL_TRADE_MODE_LONGONLY)
     {
      PrintFormat("%s: trade skipped - long trades are not allowed on %s", EA_NAME, _Symbol);
      return(false);
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| Trading day and time window filter                               |
//+------------------------------------------------------------------+
bool IsTradingTimeAllowed(const datetime time)
  {
   MqlDateTime dt;
   TimeToStruct(time, dt);

   if(!IsTradingDay(dt.day_of_week))
      return(false);
   if(!InpUseTradingHours)
      return(true);

   int now   = dt.hour * 60 + dt.min;
   int start = InpStartHour * 60 + InpStartMinute;
   int end   = InpEndHour * 60 + InpEndMinute;

   if(start == end)                 // identical start and end = whole day
      return(true);
   if(start < end)                  // e.g. 08:00 - 20:00
      return(now >= start && now < end);
   return(now >= start || now < end); // window wraps past midnight, e.g. 22:00 - 04:00
  }

//+------------------------------------------------------------------+
bool IsTradingDay(const int dayOfWeek)
  {
   switch(dayOfWeek)
     {
      case 0:
         return(InpTradeSunday);
      case 1:
         return(InpTradeMonday);
      case 2:
         return(InpTradeTuesday);
      case 3:
         return(InpTradeWednesday);
      case 4:
         return(InpTradeThursday);
      case 5:
         return(InpTradeFriday);
      case 6:
         return(InpTradeSaturday);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Number of open positions of this EA on the current symbol        |
//+------------------------------------------------------------------+
int CountOpenPositions()
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == (long)InpMagicNumber)
         count++;
     }
   return(count);
  }

//+------------------------------------------------------------------+
//| Copies EMA values; arrays are indexed as series (0 = newest)     |
//+------------------------------------------------------------------+
bool CopyEMAValues(const int startPos, const int count, double &fast[], double &slow[])
  {
   if(BarsCalculated(g_fastHandle) < startPos + count || BarsCalculated(g_slowHandle) < startPos + count)
      return(false);

   ArraySetAsSeries(fast, true);
   ArraySetAsSeries(slow, true);
   return(CopyBuffer(g_fastHandle, 0, startPos, count, fast) == count &&
          CopyBuffer(g_slowHandle, 0, startPos, count, slow) == count);
  }

//+------------------------------------------------------------------+
//| Pip size: 10 points on 3/5 digit quotes, otherwise 1 point       |
//+------------------------------------------------------------------+
double CalculatePipSize()
  {
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(InpPointsPerPip > 0)
      return(point * InpPointsPerPip);

   long digits = SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   return((digits == 3 || digits == 5) ? point * 10.0 : point);
  }

//+------------------------------------------------------------------+
//| Rounds a price to the symbol's tick size                         |
//+------------------------------------------------------------------+
double NormalizePrice(const double price)
  {
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize > 0.0)
      return(NormalizeDouble(MathRound(price / tickSize) * tickSize, _Digits));
   return(NormalizeDouble(price, _Digits));
  }

//+------------------------------------------------------------------+
//| Rounds a volume down to the volume step within min/max limits    |
//+------------------------------------------------------------------+
double NormalizeVolume(const double volume)
  {
   double minVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step      = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0)
      return(0.0);

   double normalized = MathFloor(volume / step + 1e-9) * step;
   normalized = MathMax(minVolume, MathMin(maxVolume, normalized));

   int volumeDigits = (int)MathMax(0.0, MathCeil(-MathLog10(step)));
   return(NormalizeDouble(normalized, volumeDigits));
  }

//+------------------------------------------------------------------+
//| Input validation                                                 |
//+------------------------------------------------------------------+
bool ValidateInputs()
  {
   bool ok = true;

   if(InpFastEMAPeriod < 1 || InpSlowEMAPeriod < 1)
     {
      Print(EA_NAME, ": EMA periods must be at least 1");
      ok = false;
     }
   else
      if(InpFastEMAPeriod >= InpSlowEMAPeriod)
        {
         Print(EA_NAME, ": fast EMA period must be smaller than slow EMA period");
         ok = false;
        }
   if(InpLotMode == LOT_MODE_FIXED && InpLotSize <= 0.0)
     {
      Print(EA_NAME, ": lot size must be greater than 0");
      ok = false;
     }
   if(InpLotMode == LOT_MODE_RISK && (InpRiskPercent <= 0.0 || InpRiskPercent > 100.0))
     {
      Print(EA_NAME, ": risk per trade must be between 0 and 100 %");
      ok = false;
     }
   bool hasStopLoss = (InpStopMode == STOP_MODE_PIPS) ? (InpStopLossPips > 0.0) : (InpATRStopMult > 0.0);
   if(!hasStopLoss && (InpLotMode == LOT_MODE_RISK || InpUseBreakEven))
     {
      Print(EA_NAME, ": risk based lot size and break-even need a stop loss");
      ok = false;
     }
   if(InpStopLossPips < 0.0 || InpTakeProfitPips < 0.0)
     {
      Print(EA_NAME, ": stop loss and take profit cannot be negative");
      ok = false;
     }
   if(InpStopMode == STOP_MODE_ATR && (InpATRPeriod < 1 || InpATRStopMult < 0.0 || InpATRTakeMult < 0.0))
     {
      Print(EA_NAME, ": ATR period must be at least 1 and ATR multipliers cannot be negative");
      ok = false;
     }
   if(InpUseBreakEven && (InpBreakEvenTriggerR <= 0.0 || InpBreakEvenLock < 0.0))
     {
      Print(EA_NAME, ": break-even trigger must be > 0 and the locked pips cannot be negative");
      ok = false;
     }
   if(InpUseTrailingStop && (InpTrailingStart < 0.0 || InpTrailingDistance <= 0.0 || InpTrailingStep < 0.0))
     {
      Print(EA_NAME, ": trailing distance must be > 0, trailing start and step cannot be negative");
      ok = false;
     }
   if(InpUseTrendFilter && InpTrendSlopeBars < 1)
     {
      Print(EA_NAME, ": trend slope lookback must be at least 1 bar");
      ok = false;
     }
   if(InpCooldownBars < 0)
     {
      Print(EA_NAME, ": cooldown bars cannot be negative");
      ok = false;
     }
   if(InpMaxPositions < 0)
     {
      Print(EA_NAME, ": max open positions cannot be negative");
      ok = false;
     }
   if(InpPointsPerPip < 0)
     {
      Print(EA_NAME, ": points per pip cannot be negative");
      ok = false;
     }
   if(InpStartHour < 0 || InpStartHour > 23 || InpEndHour < 0 || InpEndHour > 23 ||
      InpStartMinute < 0 || InpStartMinute > 59 || InpEndMinute < 0 || InpEndMinute > 59)
     {
      Print(EA_NAME, ": trading hours must be 0-23 and minutes 0-59");
      ok = false;
     }
   if(!InpTradeMonday && !InpTradeTuesday && !InpTradeWednesday && !InpTradeThursday &&
      !InpTradeFriday && !InpTradeSaturday && !InpTradeSunday)
     {
      Print(EA_NAME, ": at least one trading day must be enabled");
      ok = false;
     }

   return(ok);
  }

//+------------------------------------------------------------------+
//| On-chart information panel                                       |
//+------------------------------------------------------------------+
void UpdatePanel(const bool force)
  {
   if(!InpShowPanel)
      return;
   if(MQLInfoInteger(MQL_TESTER) && !MQLInfoInteger(MQL_VISUAL_MODE))
      return;

   static uint lastUpdate = 0;
   uint now = GetTickCount();
   if(!force && now - lastUpdate < PANEL_REFRESH_MS)
      return;
   lastUpdate = now;

   string emaLine = "EMA data loading...";
   double fast[], slow[];
   if(CopyEMAValues(0, 1, fast, slow))
      emaLine = StringFormat("Fast EMA(%d): %s   Slow EMA(%d): %s   (%s)",
                             InpFastEMAPeriod, DoubleToString(fast[0], _Digits),
                             InpSlowEMAPeriod, DoubleToString(slow[0], _Digits),
                             fast[0] > slow[0] ? "fast above slow" : "fast below slow");

   string status = IsTradingTimeAllowed(TimeCurrent()) ? "ACTIVE" : "PAUSED (outside trading hours/days)";
   string lastSignal = (g_lastSignalTime > 0) ? TimeToString(g_lastSignalTime) : "none since start";

   string text = StringFormat("%s  |  %s %s\n", EA_NAME, _Symbol, TimeframeToString(g_timeframe));
   text += emaLine + "\n";
   text += StringFormat("%s   %s   Magic: %I64u\n", LotDescription(), StopsDescription(), InpMagicNumber);
   text += OptionsDescription() + "\n";
   text += "Schedule: " + ScheduleDescription() + "\n";
   text += "Status: " + status + "\n";
   text += StringFormat("Open positions: %d   Last crossover: %s", CountOpenPositions(), lastSignal);

   Comment(text);
  }

//+------------------------------------------------------------------+
string LotDescription()
  {
   if(InpLotMode == LOT_MODE_RISK)
      return(StringFormat("Risk: %.2f%% per trade", InpRiskPercent));
   return(StringFormat("Lots: %.2f", g_lotSize));
  }

//+------------------------------------------------------------------+
string StopsDescription()
  {
   if(InpStopMode == STOP_MODE_ATR)
      return(StringFormat("SL: ATR(%d) x%.2f   TP: ATR(%d) x%.2f",
                          InpATRPeriod, InpATRStopMult, InpATRPeriod, InpATRTakeMult));
   return(StringFormat("SL: %.1f pips   TP: %.1f pips", InpStopLossPips, InpTakeProfitPips));
  }

//+------------------------------------------------------------------+
string OptionsDescription()
  {
   string breakEven = InpUseBreakEven
                      ? StringFormat("at %.2f x SL (lock %.1f pips)", InpBreakEvenTriggerR, InpBreakEvenLock)
                      : "off";
   string trailing  = InpUseTrailingStop
                      ? StringFormat("from +%.1f pips, %.1f pips behind", InpTrailingStart, InpTrailingDistance)
                      : "off";
   string trend     = InpUseTrendFilter ? StringFormat("%d bars", InpTrendSlopeBars) : "off";
   string cooldown  = (InpCooldownBars > 0) ? StringFormat("%d bars", InpCooldownBars) : "off";
   return(StringFormat("Break-even: %s | Trailing: %s | Trend filter: %s | Cooldown: %s",
                       breakEven, trailing, trend, cooldown));
  }

//+------------------------------------------------------------------+
string ScheduleDescription()
  {
   string hours = InpUseTradingHours
                  ? StringFormat("%02d:%02d-%02d:%02d server time", InpStartHour, InpStartMinute, InpEndHour, InpEndMinute)
                  : "24h";
   string days = "";
   if(InpTradeMonday)
      days += " Mon";
   if(InpTradeTuesday)
      days += " Tue";
   if(InpTradeWednesday)
      days += " Wed";
   if(InpTradeThursday)
      days += " Thu";
   if(InpTradeFriday)
      days += " Fri";
   if(InpTradeSaturday)
      days += " Sat";
   if(InpTradeSunday)
      days += " Sun";
   return(hours + " |" + days);
  }

//+------------------------------------------------------------------+
string TimeframeToString(const ENUM_TIMEFRAMES timeframe)
  {
   return(StringSubstr(EnumToString(timeframe), 7)); // strip "PERIOD_"
  }
//+------------------------------------------------------------------+
