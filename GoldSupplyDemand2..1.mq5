//+------------------------------------------------------------------+
bool CanMakeServerRequest() {
   // Reset daily counter if it's a new day
   datetime now = TimeCurrent();
   MqlDateTime nowStruct, lastStruct;
   TimeToStruct(now, nowStruct);
   TimeToStruct(lastRequestCountReset, lastStruct);
   
   if (nowStruct.day != lastStruct.day) {
      dailyRequestCount = 0;
      lastRequestCountReset = now;
      ArrayResize(lastTrailingStopPrices, 0); // Reset trailing stop price tracking
      if (EnableRequestLogging) {
         Print("Daily request counter reset. New day: ", TimeToString(now, TIME_DATE));
      }
   }
   
   if (dailyRequestCount >= MaxDailyRequests) {
      if (EnableRequestLogging) {
         Print("Daily request limit reached: ", dailyRequestCount, "/", MaxDailyRequests, " - Blocking further requests");
      }
      return false;
   }
   
   return true;
}

void IncrementRequestCounter(string requestType) {
   dailyRequestCount++;
   if (EnableRequestLogging) {
      Print("Server Request #", dailyRequestCount, " - Type: ", requestType, " - Remaining: ", (MaxDailyRequests - dailyRequestCount));
   }
   
   // Warning when approaching limit
   if (dailyRequestCount >= MaxDailyRequests * 0.9) {
      Alert("WARNING: Approaching daily request limit - ", dailyRequestCount, "/", MaxDailyRequests);
   }
}

//+------------------------------------------------------------------+
//|                  SupplyDemandATR_EA.mq5                          |
//|   MetaTrader 5 Expert Advisor - Supply & Demand with ATR        |
//+------------------------------------------------------------------+
#property copyright "Waleh"
#property link      "https://x.com/Crypto_Dulex"
#property version   "1.00"
#property strict

input ENUM_TIMEFRAMES ZoneTF = PERIOD_H1;
input ENUM_TIMEFRAMES EntryTF = PERIOD_M15;
input double RiskPerTrade = 1.0;
input int ATRPeriod = 14;
input double ATRMultiplier = 1.5;
input double TP_RR = 2.0;
input double MinATR = 10;
input bool RequireConfirmation = true;
input int MaxTradesPerDay = 2;
input bool DrawZones = true;

input bool UseTrailingStop = true;
input double TrailATRMultiplier = 1.0;
input bool EnableAlerts = true;

// Server Request Optimization Settings
input group "=== Server Optimization ==="
input int MaxDailyRequests = 1800; // Stay below broker's 2000 limit
input int TrailingStopIntervalSeconds = 30; // Minimum seconds between trailing stop updates
input int MinPipsForTrailingUpdate = 5; // Minimum pip movement before updating trailing stop
input bool EnableRequestLogging = true; // Log all server requests for monitoring

// Account Authorization Settings
input group "=== Account Authorization ==="
input string AuthorizedAccounts = "1511339882,520312933"; // Comma-separated list of authorized account numbers
input bool EnableAccountCheck = true; // Set to false to disable authorization (for testing)

datetime lastTradeTime = 0;
int dailyTradeCount = 0;
bool isAccountAuthorized = false;

// Server request tracking variables
int dailyRequestCount = 0;
datetime lastRequestCountReset = 0;
datetime lastTrailingStopUpdate = 0;
string lastTrailingStopPrices[]; // Track last known prices to avoid unnecessary updates

//+------------------------------------------------------------------+
bool CheckAccountAuthorization() {
   if (!EnableAccountCheck) {
      Print("Account authorization disabled - EA will run on any account");
      return true;
   }
   
   long currentAccount = AccountInfoInteger(ACCOUNT_LOGIN);
   string accountStr = IntegerToString(currentAccount);
   string authList = AuthorizedAccounts;
   
   // Check if current account is in the authorized list
   string accounts[];
   int count = StringSplit(authList, ',', accounts);
   
   for (int i = 0; i < count; i++) {
      StringTrimLeft(accounts[i]);
      StringTrimRight(accounts[i]);
      
      if (accounts[i] == accountStr) {
         Print("Account ", accountStr, " is authorized to use this EA");
         return true;
      }
   }
   
   // Account not found in authorized list
   Print("UNAUTHORIZED ACCOUNT: ", accountStr);
   Print("This EA is not authorized to run on this account.");
   Print("Contact the developer for authorization: https://x.com/Crypto_Dulex");
   
   Alert("UNAUTHORIZED ACCOUNT: This EA is not licensed for account ", accountStr);
   
   return false;
}

//+------------------------------------------------------------------+
int OnInit() {
   // Check account authorization first
   isAccountAuthorized = CheckAccountAuthorization();
   
   if (!isAccountAuthorized) {
      Print("EA initialization failed: Account not authorized");
      Alert("EA STOPPED: Account not authorized. Contact developer for licensing.");
      return(INIT_FAILED);
   }
   
   Print("EA initialized successfully on authorized account: ", AccountInfoInteger(ACCOUNT_LOGIN));
   Print("Account Name: ", AccountInfoString(ACCOUNT_NAME));
   Print("Account Server: ", AccountInfoString(ACCOUNT_SERVER));
   Print("Account Company: ", AccountInfoString(ACCOUNT_COMPANY));
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   if (reason == REASON_ACCOUNT) {
      Print("Account changed - EA will be reloaded for authorization check");
   }
   
   Print("EA deinitialized. Reason code: ", reason);
}

//+------------------------------------------------------------------+
double GetATR(ENUM_TIMEFRAMES tf, int period) {
   int handle = iATR(_Symbol, tf, period);
   if (handle == INVALID_HANDLE) return -1;
   double atr[];
   if (CopyBuffer(handle, 0, 0, 1, atr) < 0) return -1;
   // Return ATR in price units, not points
   return atr[0];
}

//+------------------------------------------------------------------+
bool DetectDemandZone(double &zoneLow, double &zoneHigh) {
   zoneLow = iLow(_Symbol, ZoneTF, 1);
   zoneHigh = iHigh(_Symbol, ZoneTF, 2);
   if (DrawZones)
      DrawRectangle("DemandZone", zoneLow, zoneHigh, clrGreen);
   return true;
}

bool DetectSupplyZone(double &zoneHigh, double &zoneLow) {
   zoneHigh = iHigh(_Symbol, ZoneTF, 1);
   zoneLow = iLow(_Symbol, ZoneTF, 2);
   if (DrawZones)
      DrawRectangle("SupplyZone", zoneLow, zoneHigh, clrRed);
   return true;
}

void DrawRectangle(string name, double low, double high, color col) {
   string id = name + TimeToString(TimeCurrent(), TIME_MINUTES);
   datetime time1 = TimeCurrent();
   datetime time2 = time1 + PeriodSeconds(ZoneTF) * 10;
   ObjectCreate(0, id, OBJ_RECTANGLE, 0, time1, low * _Point, time2, high * _Point);
   ObjectSetInteger(0, id, OBJPROP_COLOR, col);
   ObjectSetInteger(0, id, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, id, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, id, OBJPROP_BACK, true);
}

//+------------------------------------------------------------------+
bool ConfirmationPatternBullish() {
   double open1 = iOpen(_Symbol, EntryTF, 1);
   double close1 = iClose(_Symbol, EntryTF, 1);
   double open2 = iOpen(_Symbol, EntryTF, 2);
   double close2 = iClose(_Symbol, EntryTF, 2);
   return close1 > open1 && close1 > close2 && open1 < open2;
}

bool ConfirmationPatternBearish() {
   double open1 = iOpen(_Symbol, EntryTF, 1);
   double close1 = iClose(_Symbol, EntryTF, 1);
   double open2 = iOpen(_Symbol, EntryTF, 2);
   double close2 = iClose(_Symbol, EntryTF, 2);
   return close1 < open1 && close1 < close2 && open1 > open2;
}

//+------------------------------------------------------------------+
double CalculateLotSize(double stopLossPoints) {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * (RiskPerTrade / 100.0);
   
   // Get contract size and tick value
   double contractSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   
   // Calculate lot size based on risk
   // stopLossPoints is already in price units (not points)
   double stopLossInTicks = stopLossPoints / tickSize;
   double lotSize = riskAmount / (stopLossInTicks * tickValue);
   
   // Get lot size limits
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   // Apply limits and normalize
   if (lotSize < minLot) lotSize = minLot;
   if (lotSize > maxLot) lotSize = maxLot;
   
   // Round to nearest lot step
   lotSize = MathRound(lotSize / lotStep) * lotStep;
   
   // Final safety check - ensure lot size is reasonable
   if (lotSize > balance / 1000.0) { // Don't risk more than 0.1% per pip
       lotSize = minLot;
   }
   
   Print("Debug: Risk Amount: ", riskAmount, 
         ", Stop Loss: ", stopLossPoints, 
         ", Calculated Lot: ", lotSize);
   
   return NormalizeDouble(lotSize, 2);
}

//+------------------------------------------------------------------+
void TrailingStop() {
   if (!UseTrailingStop) return;
   if (!CanMakeServerRequest()) return;
   
   // Throttle trailing stop updates
   datetime now = TimeCurrent();
   if (now - lastTrailingStopUpdate < TrailingStopIntervalSeconds) return;
   
   double atr = GetATR(EntryTF, ATRPeriod);
   if (atr <= 0) return;
   
   double trailDistance = atr * TrailATRMultiplier;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   bool anyUpdatesMade = false;
   
   // Loop through all open positions
   for (int i = PositionsTotal() - 1; i >= 0; i--) {
      if (PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == 123456) {
         ulong ticket = PositionGetInteger(POSITION_TICKET);
         ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double currentSL = PositionGetDouble(POSITION_SL);
         double currentTP = PositionGetDouble(POSITION_TP);
         
         MqlTradeRequest request;
         MqlTradeResult result;
         ZeroMemory(request);
         ZeroMemory(result);
         
         bool needsUpdate = false;
         double newSL = currentSL;
         double minMovement = MinPipsForTrailingUpdate * _Point;
         
         if (posType == POSITION_TYPE_BUY) {
            // For buy positions, trail stop loss upward
            double proposedSL = bid - trailDistance;
            
            // Only move SL if it's significantly better (minimum pip movement)
            if ((currentSL == 0 && proposedSL > 0) || (proposedSL > currentSL + minMovement)) {
               // Don't move SL above current price
               if (proposedSL < bid - minMovement) {
                  newSL = NormalizeDouble(proposedSL, _Digits);
                  needsUpdate = true;
               }
            }
         }
         else if (posType == POSITION_TYPE_SELL) {
            // For sell positions, trail stop loss downward
            double proposedSL = ask + trailDistance;
            
            // Only move SL if it's significantly better (minimum pip movement)
            if ((currentSL == 0 && proposedSL > 0) || (proposedSL < currentSL - minMovement)) {
               // Don't move SL below current price
               if (proposedSL > ask + minMovement) {
                  newSL = NormalizeDouble(proposedSL, _Digits);
                  needsUpdate = true;
               }
            }
         }
         
         if (needsUpdate && CanMakeServerRequest()) {
            request.action = TRADE_ACTION_SLTP;
            request.symbol = _Symbol;
            request.position = ticket;
            request.sl = newSL;
            request.tp = currentTP; // Keep existing TP
            
            if (OrderSend(request, result)) {
               IncrementRequestCounter("Trailing Stop Update");
               anyUpdatesMade = true;
               if (EnableAlerts) {
                  Alert("Trailing Stop Updated for ", _Symbol, 
                        " - New SL: ", newSL, " (was: ", currentSL, ")");
               }
               Print("Trailing stop updated for ticket ", ticket, 
                     " - New SL: ", newSL, " Previous SL: ", currentSL);
            } else {
               IncrementRequestCounter("Failed Trailing Stop");
               if (EnableAlerts) {
                  Alert("Trailing Stop Failed for ", _Symbol, 
                        " - Error: ", result.retcode, " - ", result.comment);
               }
               Print("Failed to update trailing stop for ticket ", ticket, 
                     " - Error: ", result.retcode, " - ", result.comment);
            }
         }
      }
   }
   
   // Update timestamp only if we actually checked (to prevent too frequent checks)
   if (anyUpdatesMade || PositionsTotal() == 0) {
      lastTrailingStopUpdate = now;
   }
}

//+------------------------------------------------------------------+
void TryToTrade() {
   // Check authorization before trading
   if (!isAccountAuthorized) {
      Print("Trading blocked: Account not authorized");
      return;
   }
   
   // Check if we can make server requests
   if (!CanMakeServerRequest()) {
      Print("Trading blocked: Daily server request limit reached");
      return;
   }
   
   MqlTradeRequest request;
   MqlTradeResult result;
   ZeroMemory(request);
   ZeroMemory(result);

   datetime now = TimeCurrent();
   MqlDateTime nowStruct, lastStruct;
   TimeToStruct(TimeCurrent(), nowStruct);
   TimeToStruct(lastTradeTime, lastStruct);
   if (nowStruct.day != lastStruct.day) dailyTradeCount = 0;

   if (dailyTradeCount >= MaxTradesPerDay) return;

   double atr = GetATR(EntryTF, ATRPeriod);
   if (atr < MinATR * _Point) return; // Compare with MinATR in price units

   double bid, ask;
   SymbolInfoDouble(_Symbol, SYMBOL_BID, bid);
   SymbolInfoDouble(_Symbol, SYMBOL_ASK, ask);

   double dLow, dHigh, sLow, sHigh;

   // Demand Zone Buy
   if (DetectDemandZone(dLow, dHigh)) {
      double entryBuy = ask; // Use current ask price
      double stopLossBuy = entryBuy - atr * ATRMultiplier; // ATR already in price units
      double takeProfitBuy = entryBuy + (entryBuy - stopLossBuy) * TP_RR;
      double stopLossDistance = entryBuy - stopLossBuy;
      double lotSizeBuy = CalculateLotSize(stopLossDistance);

      if (lotSizeBuy > 0 && (!RequireConfirmation || ConfirmationPatternBullish())) {
         request.action = TRADE_ACTION_DEAL;
         request.symbol = _Symbol;
         request.volume = lotSizeBuy;
         request.type = ORDER_TYPE_BUY;
         request.price = NormalizeDouble(ask, _Digits);
         request.sl = NormalizeDouble(stopLossBuy, _Digits);
         request.tp = NormalizeDouble(takeProfitBuy, _Digits);
         request.deviation = 10;
         request.magic = 123456;
         request.type_filling = ORDER_FILLING_IOC;

         if (OrderSend(request, result)) {
            IncrementRequestCounter("Buy Order");
            lastTradeTime = now;
            dailyTradeCount++;
            if (EnableAlerts) Alert("Buy Order Placed: ", lotSizeBuy, " lots at ", request.price);
         } else {
            IncrementRequestCounter("Failed Buy Order");
            if (EnableAlerts) {
               Alert("Buy Order Failed: ", result.retcode, " - ", result.comment);
            }
         }
      }
   }

   // Supply Zone Sell
   if (DetectSupplyZone(sHigh, sLow)) {
      double entrySell = bid; // Use current bid price
      double stopLossSell = entrySell + atr * ATRMultiplier; // ATR already in price units
      double takeProfitSell = entrySell - (stopLossSell - entrySell) * TP_RR;
      double stopLossDistance = stopLossSell - entrySell;
      double lotSizeSell = CalculateLotSize(stopLossDistance);

      if (lotSizeSell > 0 && (!RequireConfirmation || ConfirmationPatternBearish())) {
         request.action = TRADE_ACTION_DEAL;
         request.symbol = _Symbol;
         request.volume = lotSizeSell;
         request.type = ORDER_TYPE_SELL;
         request.price = NormalizeDouble(bid, _Digits);
         request.sl = NormalizeDouble(stopLossSell, _Digits);
         request.tp = NormalizeDouble(takeProfitSell, _Digits);
         request.deviation = 10;
         request.magic = 123456;
         request.type_filling = ORDER_FILLING_IOC;

         if (OrderSend(request, result)) {
            IncrementRequestCounter("Sell Order");
            lastTradeTime = now;
            dailyTradeCount++;
            if (EnableAlerts) Alert("Sell Order Placed: ", lotSizeSell, " lots at ", request.price);
         } else {
            IncrementRequestCounter("Failed Sell Order");
            if (EnableAlerts) {
               Alert("Sell Order Failed: ", result.retcode, " - ", result.comment);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
void OnTick() {
   // Check authorization on every tick (in case account changes)
   if (!isAccountAuthorized) {
      isAccountAuthorized = CheckAccountAuthorization();
      if (!isAccountAuthorized) return;
   }
   
   if (Period() != EntryTF) return;
   
   // Handle trailing stops for existing positions
   TrailingStop();
   
   // Look for new trading opportunities
   TryToTrade();
}