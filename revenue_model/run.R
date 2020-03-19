library(tidyverse)
library(DBI)
library(scales)

# Cron Run ----

# globals
## kept in global memory and used by all scripts that reference them
### run from cronR:
cron_args <- commandArgs(trailingOnly = T)
game_name <- cron_args[1]
day_from <- cron_args[2] %>% as.numeric()
day_to <- cron_args[3] %>% as.numeric()
source("globals.R", local = T) # format the globals

# populate S3
cohort_date <- (Sys.Date() - (1 + day_from)) %>% toString() # yesterday minus days required for tarining period
source("predict.R", local = T) # will return prediction_df with predictions for the above cohort
source("send_to_s3.R", local = T) # send the predictions to s3
print(paste0("Successful upload of predictions for cohort: ", cohort_date, " day ", day_from, " day ", day_to))



# Manual Run: ----
# game_name <- "covetfashion"
# day_from <- 7 # train from
# day_to <- 30 # predict to

# S3 send loop
## (when running from cron will just be a single date)
# dates <- seq(as.Date("2020-03-01"), as.Date("2020-03-17"), by = 1)
# for(d in seq_along(dates)) {
#   
#   # populate S3
#   cohort_date <- dates[d] %>% toString()
#   source("predict.R", local = T) # will return prediction_df with predictions for the above cohort
#   source("send_to_s3.R", local = T) # send the predictions to s3
#   print(cohort_date)
# }