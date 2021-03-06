###Momentum Trading Detector
require(quantmod)
require(xts)
require(data.table)
require(lubridate)
require(PerformanceAnalytics)
require(magrittr)

setwd("/Users/renco/GitHub/Renco_Quant_Trading")
start_date <- today() - 30 
end_date <- today() 


# Should we trade? --------------------------------------------------------


#Is market in distress?
getSymbols("000001.SS", from = start_date,
           to = end_date)
sh <- dailyReturn(get("000001.SS"))
sh <- data.table(coredata(sh), index(sh))
names(sh) <- c("d.ret", "date")
sh <- sh[d.ret !=  0 ]
sh.ret <- prod(1 + head(tail(sh$d.ret,8),7))
if (sh.ret < 1) {
  print("No Trading ")
}else{
  print("Good to go")
}
print(tail(index(get("000001.SS")),1))
print(sh.ret)


# Momentum Strat ----------------------------------------------------------
stock_list <- load("All_list.RData")
stocks_code <- as.vector(as.matrix(get(stock_list))) #for looping to saving time
mom.df <- data.frame(matrix(rep(NA, 2 * length(stocks_code)), ncol = 2))
names(mom.df) <- c("symbol","cum.ret")


code_count <- 0 
for (code in stocks_code) {
  code_count <- code_count + 1
  
  symbol <- "" ##Initiate
  symbol <- paste(sprintf("%06d", code),
                  ifelse(code <= 600000, "SZ","SS"),
                  sep = ".") #SZ stocks has number smaller than 1000
  #getSymbols(symbol,from=start_date) #Fecthing data
  tryCatch({getSymbols(symbol,from = start_date,to = end_date)
    #atr <- lag(ATR(get(symbol)))
    #ajusted for split and dividends 
    
    #get(symbol) <- adjustOHLC(get(symbol),use.Adjusted=TRUE)
    ret.ts <- dailyReturn(get(symbol))
    ret.ts <- data.table(coredata(ret.ts),index(ret.ts))
    names(ret.ts) <- c("d.ret","date")
    ret.ts <- ret.ts[d.ret != 0] #take out daily not trading
    if (dim(ret.ts)[1] < 7) {
      removeSymbols(symbol) #house keeping 
      next
    }
    # if ( tail(index(get(symbol)),1) != end_date) {
    # removeSymbols(symbol) #house keeping 
    # next
    #}
    #last 7 days skippping the most recent day 
    temp.cum.ret <- prod(1 + head(tail(ret.ts$d.ret,8),7)) 
    mom.df[code_count,"symbol"] <- symbol
    mom.df[code_count,"cum.ret"] <- temp.cum.ret
    removeSymbols(symbol)  #house keeping 
  },  
  warning = function(msg) {
    print(paste("Caught warning message:", msg))
  },
  error = function(msg) {
    print(paste("Caught fatal message:", msg))
    return(NA)
  }
  ) #tryCatch
} #for 

mom.dt <- data.table(mom.df) 
mom.dt <- mom.dt[order(-cum.ret)]
mom.dt <- mom.dt[is.na(cum.ret) == FALSE]
cat("Top 20 Winners:\n\n")
print(head(mom.dt,20))
port <- head(mom.dt, 20)


# optimal portfolio  ------------------------------------------------------

#mao tai 
#this is the long-term holding invariant to daily rebalancing
mt.symbol <- "600519.SS"
mt.holding <- 100
getSymbols(mt.symbol, from = today() - 126,
           to = today())
mt.price <- tail(Ad(get(mt.symbol)),1)
mt.value <- mt.price * mt.holding


#ge li
#long-term holding
gl.symbol <- "000651.SZ"
gl.holding <- 400
getSymbols(gl.symbol, from = today() - 126,
           to = today())
gl.price <- tail(Ad(get(gl.symbol)),1)
gl.value <- gl.price * gl.holding


#stocks that failed discretionary tests
exclude <- c("002235.SZ")


#init.p.value = 145226.18 - as.numeric(gl.value) - as.numeric(mt.value)#value for momentum investments
init.p.value = 80000 #80000 capital devoted to momentum strategy 
tolerance <- 0.015 * 265805.00 #(mt.value + gl.value + init.p.value) #acceptable maximum daily loss 

N = 5
num_holding_stock <- 0
slack = TRUE #addtional risk capital to use 
while (num_holding_stock < N & dim(port)[1] >= N | slack == TRUE) {
  
  num_mom_stock <- 0
  while (num_mom_stock < N) {
    
    #get data for holdings 
    #and trim stock that has negative mean return 
    
    port <- port[!symbol %in% exclude]
    holding <- data.frame(matrix(rep(NA, 4 * N),ncol = 4))
    names(holding) <- c("symbol", "weight","vol","cum.ret")
    holding["symbol"] <- port[1:N,symbol]
    
    del_row = c()
    for (i in 1:N) {
      symbol <- holding[i,"symbol"]
      getSymbols(symbol, from = today() - 126, to = today())
      ts <- dailyReturn(Ad(get(symbol)))
      ts <- ts[!is.na(ts)] #remove NA values
      holding[i,"weight"] <- mean(ts) / var(ts)
      if (holding[i,'weight'] < 0 ) {
        exclude <- c(exclude, symbol)
        print(paste(symbol, "has negative return -- Kill it"))
        del_row <- c(del_row, i) 
      }
      holding[i,"vol"] <- sd(ts, na.rm = TRUE)
      holding[i,"cum.ret"] <- mom.dt[i,cum.ret]
    }
    if (!is.null(del_row)) {
      holding <- holding[-del_row, ]
    }
    num_mom_stock <- dim(holding)[1]
  }#while num_mom_stock
  
  
  #normalize total weight to 100% 
  holding["weight"] <- holding["weight"] / sum(holding["weight"]) * 100 
  
  
  #risk managment
  #trim addtional holding to make sure the daily VaR is less than
  # 1% of total asset value 
  
  p.value = init.p.value
  risk.VaR <- Inf
  risk.downsize_ratio <- 1
  while (abs(risk.VaR) > tolerance) {
    
    #downsize portfolio until the daily VaR is less than 
    #1% ot total asset value
    p.value <- p.value * risk.downsize_ratio 
    risk.xts <- dailyReturn(Ad(get(mt.symbol)))
    risk.xts <- merge(risk.xts, dailyReturn(Ad(get(gl.symbol))))  
    for (symbol in unlist(holding['symbol'])) {
      risk.xts <- merge(risk.xts, dailyReturn(Ad(get(symbol))))  
    }
    names(risk.xts) <- c(mt.symbol, gl.symbol, unlist(holding['symbol']))
    mt.weight <- as.numeric(coredata(mt.value /  (mt.value + gl.value + p.value)))
    gl.weight <- as.numeric(coredata(gl.value /  (mt.value + gl.value + p.value)))
    value.weight <- mt.weight + gl.weight
    risk.weight <- c(mt.weight, gl.weight, unlist(holding["weight"]) * (1 - value.weight) * 1/100)
    stopifnot(abs(sum(risk.weight) - 1) < 1e-6)
    
    risk.ret <- xts(coredata(risk.xts) %*% as.matrix(risk.weight, col = 1),
                    order.by = index(get(mt.symbol)))
    risk.VaR <- VaR(risk.ret, p = 0.95, method = "modified") * (p.value + mt.value + gl.value)
    #risk.VaR <- VaR(risk.ret, p = 0.95, method = "modified") * (p.value)
    risk.downsize_ratio <- abs( as.numeric(tolerance / risk.VaR))
    if (risk.downsize_ratio < 1) {
      print(risk.downsize_ratio)
      print("Downsize")
      cat("\n")
    }
    if (abs(risk.downsize_ratio - 1) < 0.01) {
      break
    }
  }#while risk.VaR
  
  
  # #sizing the daily volatility
  # p.vol <- sqrt(sum(holding["vol"]^2 * holding["weight"] / 100))
  # if (p.vol >= 0.05) {
  #   print("portfolio's volatility is too large.")
  #   ratio = p.vol / 0.05
  #   holding["weight"] <- holding["weight"] / ratio  
  # }
  
  
  
  last.price = c() #used to calculate "shou"
  for (symbol in unlist(holding['symbol']) ) {
    last.price = c(last.price, tail(Ad(get(symbol)), 1))
  }
  
  
  holding["value"] = p.value * holding["weight"] / 100
  holding['shou'] = round(holding['value'] / (100 * last.price), 
                          digits = 0)
  
  
  exclude <- c(exclude, unlist(unlist(holding[holding["shou"] == 0,"symbol"])))  
  holding <- holding[holding["shou"] != 0,] #triming asset that has zero shou
  
  holding["value"] = last.price * holding["shou"] * 100
  if (sum(holding["value"]) / p.value < 0.95) {
    slack = TRUE
    tolerance = tolerance * (p.value / sum(holding["value"]))
    print(sum(holding["value"]) / p.value )
    print(paste("raise tolerance: ", tolerance))
  }else{
    slack = FALSE
  }
  
  num_holding_stock <- dim(holding)[1]
  
}#while num_holding_stock

print(holding)
chart.CumReturns(risk.ret)
print(paste("total momentum value: ", sum(holding['value'])))
print(paste("Daily VaR value: ", risk.VaR))

#clean up
removeSymbols(mt.symbol)
removeSymbols(gl.symbol)
sapply(unlist(holding['symbol']), removeSymbols) %>% invisible()



