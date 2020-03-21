# Manual Run of predictions update over a given date range and prediction horizons (nested loop): ----


# libraries
library(tidyverse)
library(DBI)
library(scales)

# top level vars, loop agnostic
game_name <- "fungame"
day_from <- 7 # train from

# loops
dates <- seq(as.Date("2020-02-28"), as.Date("2020-02-29"), by = 1)
horizons <- c(30, 60, 90, 120)

# run
## for each cohort
for(cohort in seq_along(dates)) {
  
  cohort_date <- dates[cohort] %>% toString()
  
  # predictions for each time horizon
  for(h in horizons) {
    
    day_to <- h
    source("globals.R", local = T)
    
    # populate S3
    source("predict.R", local = T) # will return prediction_df with predictions for the above cohort
    source("send_to_s3.R", local = T) # send the predictions to s3
    print(paste0(cohort_date, " - day ", day_to))
  }
}