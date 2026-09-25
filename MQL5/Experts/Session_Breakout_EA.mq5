//+------------------------------------------------------------------+
//|                                          Session_Breakout_EA.mq5 |
//|              Intraday breakout of the night (Asian) session range |
//+------------------------------------------------------------------+
#property copyright   "bts-cg-claude-study"
#property version     "1.00"
#property description "Intraday breakout strategy. Measures the high and low of the night session,"
#property description "places a buy stop above and a sell stop below it at the London open, keeps"
#property description "the first one that is filled and closes everything at the end of the day."
#property description "Risk based lot size, range and spread filters. Orders are sent via CTrade."

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Enums                                                            |
//+------------------------------------------------------------------+
enum ENUM_LOT_MODE
  {
   LOT_MODE_FIXED = 0,   // Fixed lots
   LOT_MODE_RISK  = 1    // Risk % of balance
  };

enum ENUM_TRADE_DIRECTION
  {
   DIRECTION_LONG  = 0,  // Buy only
   DIRECTION_SHORT = 1,  // Sell only
   DIRECTION_BOTH  = 2   // Buy and sell
  };

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "Session times (broker server time)"
input int                  InpRangeStartHour    = 2;              // Range start hour
input int                  InpRangeStartMinute  = 0;              // Range start minute
input int                  InpRangeEndHour      = 9;              // Range end hour (orders are placed then)
input int                  InpRangeEndMinute    = 0;              // Range end minute
input int                  InpEntryEndHour      = 13;             // Entry deadline hour (unfilled orders deleted)
input int                  InpEntryEndMinute    = 0;              // Entry deadline minute
input int                  InpCloseHour         = 21;             // Close all positions at (hour)
input int                  InpCloseMinute       = 0;              // Close all positions at (minute)

input group "Breakout"
input ENUM_TRADE_DIRECTION InpTradeDirection    = DIRECTION_BOTH; // Trade direction
input double               InpBufferPips        = 1.0;            // Order distance beyond the range (pips)
input bool                 InpOneTradePerDay    = true;           // Delete the other order once one is filled
input int                  InpATRPeriod         = 14;             // Daily ATR period (range filter)
input double               InpMinRangeATR       = 0.1;            // Min range size, x daily ATR (0 = off)
input double               InpMaxRangeATR       = 1.0;            // Max range size, x daily ATR (0 = off)
input double               InpMaxSpreadPips     = 3.0;            // Max spread to place the orders (pips, 0 = off)

input group "Risk management"
input ENUM_LOT_MODE        InpLotMode           = LOT_MODE_RISK;  // Lot size mode
input double               InpRiskPercent       = 1.0;            // Risk per trade, % of balance (risk mode)
input double               InpLotSize           = 0.1;            // Lot size (fixed mode)
input double               InpStopRangeFactor   = 1.0;            // Stop loss, x range (1.0 = other side of the range)
input double               InpRewardRisk        = 1.0;            // Take profit, x stop loss (0 = no TP, exit at close)
input bool                 InpUseBreakEven      = false;          // Move SL to break-even
input double               InpBreakEvenTriggerR = 0.5;            // Profit that triggers break-even (x SL distance)
input double               InpBreakEvenLock     = 1.0;            // Pips locked in profit

input group "Trading days"
input bool                 InpTradeMonday       = true;           // Trade on Monday
input bool                 InpTradeTuesday      = true;           // Trade on Tuesday
input bool                 InpTradeWednesday    = true;           // Trade on Wednesday
input bool                 InpTradeThursday     = true;           // Trade on Thursday
input bool                 InpTradeFriday       = true;           // Trade on Friday

input group "General"
input int                  InpPointsPerPip      = 0;              // Points per pip (0 = auto-detect)
input ulong                InpMagicNumber       = 403000;         // Magic number
input uint                 InpSlippagePoints    = 10;             // Max slippage (points)
input string               InpOrderComment      = "Session Breakout"; // Order comment
input bool                 InpShowPanel         = true;           // Show info panel on chart
input bool                 InpDrawRange         = true;           // Draw the daily range on the chart

//+------------------------------------------------------------------+
//| Constants                                                        |
//+------------------------------------------------------------------+
#define EA_NAME            "Session Breakout EA"
#define OBJ_PREFIX         "SBE_"
#define PANEL_REFRESH_MS   1000
#define RETRY_SEC          10     // pause after a rejected close/delete/modify request
#define DATA_WAIT_SEC      300    // how long to wait for missing data before skipping the day

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
CTrade   g_trade;
int      g_atrHandle  = INVALID_HANDLE;
double   g_pipSize    = 0.0;      // price distance of one pip
double   g_lotSize    = 0.0;      // fixed lot size normalised to the symbol's volume rules
datetime g_day        = 0;        // server date currently handled
bool     g_setupDone  = false;    // today's orders are placed, or the day is skipped
double   g_rangeHigh  = 0.0;      // today's range, 0 until measured
double   g_rangeLow   = 0.0;
string   g_status     = "starting";
datetime g_retryAfter = 0;

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(!ValidateInputs())
      return(INIT_PARAMETERS_INCORRECT);

   g_pipSize = CalculatePipSize();

   if(InpLotMode == LOT_MODE_FIXED)
     {
      g_lotSize = NormalizeVolume(InpLotSize);
      if(g_lotSize <= 0.0)
        {
         PrintFormat("%s: lot size %.2f is not valid for %s", EA_NAME, InpLotSize, _Symbol);
         return(INIT_PARAMETERS_INCORRECT);
        }
     }

   if(InpMinRangeATR > 0.0 || InpMaxRangeATR > 0.0)
     {
      g_atrHandle = iATR(_Symbol, PERIOD_D1, InpATRPeriod);
      if(g_atrHandle == INVALID_HANDLE)
        {
         PrintFormat("%s: failed to create the daily ATR handle (error %d)", EA_NAME, GetLastError());
         return(INIT_FAILED);
        }
     }

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   PrintFormat("%s started on %s | %s | %s | 1 pip = %s", EA_NAME, _Symbol, ScheduleDescription(),
               RiskDescription(), DoubleToString(g_pipSize, _Digits));

   UpdatePanel(true);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);
   g_atrHandle = INVALID_HANDLE;

   Comment("");
   if(!MQLInfoInteger(MQL_TESTER))
      ObjectsDeleteAll(0, OBJ_PREFIX);
  }

//+------------------------------------------------------------------+
//| Expert tick: one daily cycle driven by the server clock          |
//+------------------------------------------------------------------+
void OnTick()
  {
   datetime now = TimeCurrent();
   datetime day = DayStart(now);
   if(day != g_day)
      StartNewDay(day);

   datetime rangeStart = day + MinutesOfDay(InpRangeStartHour, InpRangeStartMinute) * 60;
   datetime rangeEnd   = day + MinutesOfDay(InpRangeEndHour, InpRangeEndMinute) * 60;
   datetime entryEnd   = day + MinutesOfDay(InpEntryEndHour, InpEntryEndMinute) * 60;
   datetime closeTime  = day + MinutesOfDay(InpCloseHour, InpCloseMinute) * 60;

   if(now >= closeTime)
     {
      //--- end of the day: no position and no order is kept overnight
      Housekeeping(true, true, "end of day");
      if(CountPositions() == 0 && CountPendingOrders() == 0)
         SetStatus("Day finished - flat until tomorrow", false);
     }
   else
     {
      if(now >= entryEnd)
        {
         if(CountPendingOrders() > 0)
           {
            Housekeeping(false, true, "entry deadline reached");
            SetStatus("Entry deadline reached - unfilled orders deleted", true);
           }
        }
      else
         if(InpOneTradePerDay && CountPositions() > 0 && CountPendingOrders() > 0)
            Housekeeping(false, true, "the other side was filled");

      ManageBreakEven();

      if(!g_setupDone && now >= rangeEnd && now < entryEnd)
         g_setupDone = SetupBreakoutOrders(rangeStart, rangeEnd, now);
     }

   UpdatePanel(false);
  }

//+------------------------------------------------------------------+
//| Resets the daily state                                           |
//+------------------------------------------------------------------+
void StartNewDay(const datetime day)
  {
   g_day       = day;
   g_rangeHigh = 0.0;
   g_rangeLow  = 0.0;

   MqlDateTime dt;
   TimeToStruct(day, dt);
   if(!IsTradingDay(dt.day_of_week))
     {
      g_setupDone = true;
      SetStatus("Not a trading day", false);
      return;
     }

//--- after a restart, do not place today's orders a second time
   g_setupDone = DayAlreadyTraded(day);
   if(g_setupDone)
      SetStatus("Today's orders were already placed", false);
   else
      SetStatus(StringFormat("Waiting for the range to end at %02d:%02d", InpRangeEndHour, InpRangeEndMinute), false);
  }

//+------------------------------------------------------------------+
//| Measures the range and places the stop orders.                   |
//| Returns true when the day is done (orders placed or day skipped),|
//| false to try again on the next tick.                             |
//+------------------------------------------------------------------+
bool SetupBreakoutOrders(const datetime rangeStart, const datetime rangeEnd, const datetime now)
  {
//--- 1. conditions that can change within seconds: retry on the next ticks
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick) || tick.bid <= 0.0 || tick.ask <= 0.0)
      return(false);
   if(InpMaxSpreadPips > 0.0 && tick.ask - tick.bid > InpMaxSpreadPips * g_pipSize)
     {
      SetStatus(StringFormat("Waiting for the spread to drop below %.1f pips", InpMaxSpreadPips), false);
      return(false);
     }
   if(!IsTradingPermitted())
      return(false);

//--- 2. high and low of the night session, from M1 bars
   int    expectedBars = (int)((rangeEnd - rangeStart) / 60);
   double highs[], lows[];
   int    copiedHigh = CopyHigh(_Symbol, PERIOD_M1, rangeStart, rangeEnd - 1, highs);
   int    copiedLow  = CopyLow(_Symbol, PERIOD_M1, rangeStart, rangeEnd - 1, lows);
   if(copiedHigh <= 0 || copiedLow <= 0 || copiedHigh < expectedBars / 3 || copiedLow < expectedBars / 3)
      return(WaitOrSkip(now, rangeEnd, "not enough price data for the range (holiday or data loading)"));

   double high  = highs[ArrayMaximum(highs)];
   double low   = lows[ArrayMinimum(lows)];
   double range = high - low;
   g_rangeHigh  = high;
   g_rangeLow   = low;
   DrawRange(rangeStart, rangeEnd, high, low);
   if(range <= 0.0)
      return(SkipDay("empty range"));

//--- 3. skip abnormally quiet or agitated nights, relative to the daily ATR
   if(g_atrHandle != INVALID_HANDLE)
     {
      double atr[];
      if(CopyBuffer(g_atrHandle, 0, 1, 1, atr) != 1 || atr[0] <= 0.0)
         return(WaitOrSkip(now, rangeEnd, "daily ATR not available"));
      if(InpMinRangeATR > 0.0 && range < InpMinRangeATR * atr[0])
         return(SkipDay(StringFormat("range of %.1f pips is too small (min %.1f)",
                                     range / g_pipSize, InpMinRangeATR * atr[0] / g_pipSize)));
      if(InpMaxRangeATR > 0.0 && range > InpMaxRangeATR * atr[0])
         return(SkipDay(StringFormat("range of %.1f pips is too large (max %.1f)",
                                     range / g_pipSize, InpMaxRangeATR * atr[0] / g_pipSize)));
     }

//--- 4. a buy stop above and a sell stop below the range
   double buffer     = InpBufferPips * g_pipSize;
   double buyEntry   = NormalizePrice(high + buffer);
   double sellEntry  = NormalizePrice(low - buffer);
   double slDistance = (buyEntry - sellEntry) * InpStopRangeFactor;
   double tpDistance = slDistance * InpRewardRisk;

   int placed = 0;
   if(InpTradeDirection != DIRECTION_SHORT && PlaceStopOrder(true, buyEntry, slDistance, tpDistance, tick))
      placed++;
   if(InpTradeDirection != DIRECTION_LONG && PlaceStopOrder(false, sellEntry, slDistance, tpDistance, tick))
      placed++;

   if(placed > 0)
      SetStatus(StringFormat("%d order(s) placed, range %.1f pips - waiting for a breakout", placed, range / g_pipSize), true);
   else
      SetStatus("No order could be placed today (see the Experts log)", true);
   return(true);
  }

//+------------------------------------------------------------------+
//| Places one buy stop or sell stop order with SL/TP                |
//+------------------------------------------------------------------+
bool PlaceStopOrder(const bool isBuy, const double entry, const double slDistance, const double tpDistance,
                    const MqlTick &tick)
  {
   string side = isBuy ? "buy stop" : "sell stop";
   double sl   = NormalizePrice(isBuy ? entry - slDistance : entry + slDistance);
   double tp   = (tpDistance > 0.0) ? NormalizePrice(isBuy ? entry + tpDistance : entry - tpDistance) : 0.0;

//--- the broker requires a minimum distance between the price, the order and its SL/TP
   double minDistance = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   double market      = isBuy ? tick.ask : tick.bid;
   if((isBuy ? entry - market : market - entry) <= minDistance)
     {
      PrintFormat("%s: %s at %s skipped - the price is already at or beyond the breakout level",
                  EA_NAME, side, DoubleToString(entry, _Digits));
      return(false);
     }
   if(slDistance <= minDistance || (tp > 0.0 && tpDistance <= minDistance))
     {
      PrintFormat("%s: %s skipped - SL or TP closer than the broker minimum", EA_NAME, side);
      return(false);
     }

   ENUM_ORDER_TYPE marketType = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double lots = g_lotSize;
   if(InpLotMode == LOT_MODE_RISK)
     {
      lots = CalculateRiskLots(marketType, entry, slDistance);
      if(lots <= 0.0)
         return(false);
     }

   double margin = 0.0;
   if(!OrderCalcMargin(marketType, _Symbol, lots, entry, margin) || margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE))
     {
      PrintFormat("%s: %s skipped - not enough free margin for %.2f lots", EA_NAME, side, lots);
      return(false);
     }

   bool sent = isBuy ? g_trade.BuyStop(lots, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, InpOrderComment)
                     : g_trade.SellStop(lots, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, InpOrderComment);
   uint retcode = g_trade.ResultRetcode();
   if(sent && (retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_PLACED))
     {
      PrintFormat("%s: %s %.2f lots @ %s | SL %s | TP %s", EA_NAME, side, lots,
                  DoubleToString(entry, _Digits), DoubleToString(sl, _Digits), DoubleToString(tp, _Digits));
      return(true);
     }

   PrintFormat("%s: %s failed - retcode %u (%s), error %d", EA_NAME, side, retcode,
               g_trade.ResultRetcodeDescription(), GetLastError());
   return(false);
  }

//+------------------------------------------------------------------+
//| Moves the SL to break-even once the trade has run far enough     |
//+------------------------------------------------------------------+
void ManageBreakEven()
  {
   if(!InpUseBreakEven || TimeCurrent() < g_retryAfter || CountPositions() == 0)
      return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick) || tick.bid <= 0.0 || tick.ask <= 0.0)
      return;

   double minDistance = MathMax((double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL), 1.0) * _Point;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol ||
         PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber)
         continue;

      bool   isBuy     = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      double price     = isBuy ? tick.bid : tick.ask;   // price that closes the position
      double profit    = isBuy ? price - openPrice : openPrice - price;

      //--- only while the SL is still on the losing side: its distance is the initial risk
      bool slBeforeEntry = (currentSL > 0.0 && (isBuy ? currentSL < openPrice : currentSL > openPrice));
      if(!slBeforeEntry || profit < InpBreakEvenTriggerR * MathAbs(openPrice - currentSL))
         continue;

      double lockDistance = InpBreakEvenLock * g_pipSize;
      double newSL = NormalizePrice(isBuy ? openPrice + lockDistance : openPrice - lockDistance);
      if((isBuy ? price - newSL : newSL - price) < minDistance)
         continue;

      if(g_trade.PositionModify(ticket, newSL, currentTP) && g_trade.ResultRetcode() == TRADE_RETCODE_DONE)
         PrintFormat("%s: position #%I64u stop loss moved to break-even (%s)", EA_NAME, ticket,
                     DoubleToString(newSL, _Digits));
      else
        {
         PrintFormat("%s: failed to move position #%I64u to break-even - retcode %u (%s)", EA_NAME, ticket,
                     g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
         g_retryAfter = TimeCurrent() + RETRY_SEC;
         return;
        }
     }
  }

//+------------------------------------------------------------------+
//| Deletes pending orders and/or closes positions of this EA        |
//+------------------------------------------------------------------+
void Housekeeping(const bool closePositions, const bool deleteOrders, const string reason)
  {
   if(TimeCurrent() < g_retryAfter)
      return;

   bool ok = true;
   if(deleteOrders && CountPendingOrders() > 0)
      ok = DeletePendingOrders(reason) && ok;
   if(closePositions && CountPositions() > 0)
      ok = ClosePositions(reason) && ok;
   if(!ok)
      g_retryAfter = TimeCurrent() + RETRY_SEC;
  }

//+------------------------------------------------------------------+
bool DeletePendingOrders(const string reason)
  {
   bool ok = true;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol || OrderGetInteger(ORDER_MAGIC) != (long)InpMagicNumber)
         continue;

      if(g_trade.OrderDelete(ticket) && g_trade.ResultRetcode() == TRADE_RETCODE_DONE)
         PrintFormat("%s: order #%I64u deleted (%s)", EA_NAME, ticket, reason);
      else
        {
         PrintFormat("%s: failed to delete order #%I64u (%s) - retcode %u (%s)", EA_NAME, ticket, reason,
                     g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
         ok = false;
        }
     }
   return(ok);
  }

//+------------------------------------------------------------------+
bool ClosePositions(const string reason)
  {
   bool ok = true;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol ||
         PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber)
         continue;

      if(g_trade.PositionClose(ticket) &&
         (g_trade.ResultRetcode() == TRADE_RETCODE_DONE || g_trade.ResultRetcode() == TRADE_RETCODE_PLACED))
         PrintFormat("%s: position #%I64u closed (%s)", EA_NAME, ticket, reason);
      else
        {
         PrintFormat("%s: failed to close position #%I64u (%s) - retcode %u (%s)", EA_NAME, ticket, reason,
                     g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
         ok = false;
        }
     }
   return(ok);
  }

//+------------------------------------------------------------------+
//| True if this EA already placed orders or traded today            |
//+------------------------------------------------------------------+
bool DayAlreadyTraded(const datetime day)
  {
   if(CountPendingOrders() > 0 || CountPositions() > 0)
      return(true);
   if(!HistorySelect(day, TimeCurrent()))
      return(false);

   for(int i = HistoryOrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = HistoryOrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(HistoryOrderGetString(ticket, ORDER_SYMBOL) == _Symbol &&
         HistoryOrderGetInteger(ticket, ORDER_MAGIC) == (long)InpMagicNumber)
         return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
int CountPositions()
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
int CountPendingOrders()
  {
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(OrderGetTicket(i) == 0)
         continue;
      if(OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == (long)InpMagicNumber)
         count++;
     }
   return(count);
  }

//+------------------------------------------------------------------+
//| Lot size that loses InpRiskPercent of the balance at the SL      |
//+------------------------------------------------------------------+
double CalculateRiskLots(const ENUM_ORDER_TYPE orderType, const double price, const double slDistance)
  {
   double stopPrice  = (orderType == ORDER_TYPE_BUY) ? price - slDistance : price + slDistance;
   double lossPerLot = 0.0;
   if(slDistance <= 0.0 ||
      !OrderCalcProfit(orderType, _Symbol, 1.0, price, stopPrice, lossPerLot) ||
      lossPerLot >= 0.0)
     {
      PrintFormat("%s: could not calculate the loss per lot (error %d) - order skipped", EA_NAME, GetLastError());
      return(0.0);
     }

   double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPercent / 100.0;
   double lots      = riskMoney / -lossPerLot;
   double minVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(lots < minVolume)
     {
      PrintFormat("%s: risking %.2f%% needs %.3f lots, below the minimum of %.2f - order skipped",
                  EA_NAME, InpRiskPercent, lots, minVolume);
      return(0.0);
     }
   return(NormalizeVolume(lots));
  }

//+------------------------------------------------------------------+
//| Checks terminal, account and symbol permissions                  |
//+------------------------------------------------------------------+
bool IsTradingPermitted()
  {
   string problem = "";
   long   mode    = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      problem = "Algo Trading is disabled in the terminal";
   else
      if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
         problem = "Algo Trading is disabled in the EA properties";
      else
         if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
            problem = "automated trading is not allowed on this account";
         else
            if(mode == SYMBOL_TRADE_MODE_DISABLED || mode == SYMBOL_TRADE_MODE_CLOSEONLY)
               problem = "new trades are not allowed on " + _Symbol;

   if(problem == "")
      return(true);
   SetStatus("Waiting: " + problem, true);
   return(false);
  }

//+------------------------------------------------------------------+
bool SkipDay(const string reason)
  {
   SetStatus("Skipped today: " + reason, true);
   return(true);
  }

//+------------------------------------------------------------------+
//| Waits a few minutes for missing data, then skips the day         |
//+------------------------------------------------------------------+
bool WaitOrSkip(const datetime now, const datetime rangeEnd, const string reason)
  {
   if(now - rangeEnd < DATA_WAIT_SEC)
     {
      SetStatus("Waiting: " + reason, false);
      return(false);
     }
   return(SkipDay(reason));
  }

//+------------------------------------------------------------------+
//| Updates the status line, logging it when requested and new       |
//+------------------------------------------------------------------+
void SetStatus(const string status, const bool log)
  {
   if(status == g_status)
      return;
   g_status = status;
   if(log)
      PrintFormat("%s: %s", EA_NAME, status);
  }

//+------------------------------------------------------------------+
bool IsTradingDay(const int dayOfWeek)
  {
   switch(dayOfWeek)
     {
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
     }
   return(false);
  }

//+------------------------------------------------------------------+
datetime DayStart(const datetime time)
  {
   MqlDateTime dt;
   TimeToStruct(time, dt);
   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;
   return(StructToTime(dt));
  }

//+------------------------------------------------------------------+
int MinutesOfDay(const int hour, const int minute)
  {
   return(hour * 60 + minute);
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

   if(InpRangeStartHour < 0 || InpRangeStartHour > 23 || InpRangeEndHour < 0 || InpRangeEndHour > 23 ||
      InpEntryEndHour < 0 || InpEntryEndHour > 23 || InpCloseHour < 0 || InpCloseHour > 23 ||
      InpRangeStartMinute < 0 || InpRangeStartMinute > 59 || InpRangeEndMinute < 0 || InpRangeEndMinute > 59 ||
      InpEntryEndMinute < 0 || InpEntryEndMinute > 59 || InpCloseMinute < 0 || InpCloseMinute > 59)
     {
      Print(EA_NAME, ": hours must be 0-23 and minutes 0-59");
      ok = false;
     }
   else
     {
      int rangeStart = MinutesOfDay(InpRangeStartHour, InpRangeStartMinute);
      int rangeEnd   = MinutesOfDay(InpRangeEndHour, InpRangeEndMinute);
      int entryEnd   = MinutesOfDay(InpEntryEndHour, InpEntryEndMinute);
      int closeTime  = MinutesOfDay(InpCloseHour, InpCloseMinute);
      if(!(rangeStart < rangeEnd && rangeEnd < entryEnd && entryEnd <= closeTime))
        {
         Print(EA_NAME, ": times must follow range start < range end < entry deadline <= close, within one day");
         ok = false;
        }
     }
   if(InpBufferPips < 0.0 || InpMaxSpreadPips < 0.0)
     {
      Print(EA_NAME, ": buffer and max spread cannot be negative");
      ok = false;
     }
   if(InpMinRangeATR < 0.0 || InpMaxRangeATR < 0.0 ||
      (InpMaxRangeATR > 0.0 && InpMaxRangeATR <= InpMinRangeATR) ||
      ((InpMinRangeATR > 0.0 || InpMaxRangeATR > 0.0) && InpATRPeriod < 1))
     {
      Print(EA_NAME, ": range filter needs 0 <= min < max and an ATR period of at least 1");
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
   if(InpStopRangeFactor <= 0.0 || InpRewardRisk < 0.0)
     {
      Print(EA_NAME, ": stop loss factor must be > 0 and take profit factor cannot be negative");
      ok = false;
     }
   if(InpUseBreakEven && (InpBreakEvenTriggerR <= 0.0 || InpBreakEvenLock < 0.0))
     {
      Print(EA_NAME, ": break-even trigger must be > 0 and the locked pips cannot be negative");
      ok = false;
     }
   if(InpPointsPerPip < 0)
     {
      Print(EA_NAME, ": points per pip cannot be negative");
      ok = false;
     }
   if(!InpTradeMonday && !InpTradeTuesday && !InpTradeWednesday && !InpTradeThursday && !InpTradeFriday)
     {
      Print(EA_NAME, ": at least one trading day must be enabled");
      ok = false;
     }

   return(ok);
  }

//+------------------------------------------------------------------+
//| Draws today's range as a rectangle                               |
//+------------------------------------------------------------------+
void DrawRange(const datetime from, const datetime to, const double high, const double low)
  {
   if(!InpDrawRange)
      return;
   if(MQLInfoInteger(MQL_TESTER) && !MQLInfoInteger(MQL_VISUAL_MODE))
      return;

   string name = OBJ_PREFIX + TimeToString(from, TIME_DATE);
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_RECTANGLE, 0, from, high, to, low);
   else
     {
      ObjectMove(0, name, 0, from, high);
      ObjectMove(0, name, 1, to, low);
     }
   ObjectSetInteger(0, name, OBJPROP_COLOR, clrDodgerBlue);
   ObjectSetInteger(0, name, OBJPROP_FILL, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
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

   string rangeText = "not measured yet";
   if(g_rangeHigh > 0.0)
      rangeText = StringFormat("high %s  low %s  (%.1f pips)", DoubleToString(g_rangeHigh, _Digits),
                               DoubleToString(g_rangeLow, _Digits), (g_rangeHigh - g_rangeLow) / g_pipSize);

   string text = StringFormat("%s  |  %s  |  %s\n", EA_NAME, _Symbol, DirectionDescription());
   text += ScheduleDescription() + "\n";
   text += RiskDescription() + "\n";
   text += "Today's range: " + rangeText + "\n";
   text += "Status: " + (CountPositions() > 0 ? "In trade" : g_status) + "\n";
   text += StringFormat("Open positions: %d   Pending orders: %d   Server time: %s",
                        CountPositions(), CountPendingOrders(), TimeToString(TimeCurrent(), TIME_MINUTES));

   Comment(text);
  }

//+------------------------------------------------------------------+
string ScheduleDescription()
  {
   return(StringFormat("Range %02d:%02d-%02d:%02d | entries until %02d:%02d | close at %02d:%02d (server time)",
                       InpRangeStartHour, InpRangeStartMinute, InpRangeEndHour, InpRangeEndMinute,
                       InpEntryEndHour, InpEntryEndMinute, InpCloseHour, InpCloseMinute));
  }

//+------------------------------------------------------------------+
string RiskDescription()
  {
   string lots = (InpLotMode == LOT_MODE_RISK) ? StringFormat("risk %.2f%% per trade", InpRiskPercent)
                                               : StringFormat("%.2f lots", g_lotSize);
   string tp   = (InpRewardRisk > 0.0) ? StringFormat("TP %.2f x SL", InpRewardRisk) : "no TP";
   string be   = InpUseBreakEven ? StringFormat("break-even at %.2f x SL", InpBreakEvenTriggerR) : "no break-even";
   return(StringFormat("%s | SL %.2f x range | %s | %s", lots, InpStopRangeFactor, tp, be));
  }

//+------------------------------------------------------------------+
string DirectionDescription()
  {
   if(InpTradeDirection == DIRECTION_LONG)
      return("Buy only");
   if(InpTradeDirection == DIRECTION_SHORT)
      return("Sell only");
   return("Buy and sell");
  }
//+------------------------------------------------------------------+
