# libraries & source
library(tidyverse)
library(lubridate)
library(foreach)
library(doParallel) # includes package just parallel
library(scales)
library(kableExtra)
library(rmarkdown)
library(dbplyr)
library(DBI)
library(odbc)
library(rlang)
library(glue)
source("functions/prediction_functions.R", local = T)

# source query and get dataframe
con <- dbConnect(odbc(), "Athena")
select <- dplyr::select

# globals set in run.R
directory <- paste0("/home/rstudio-gavin/analysis/radhoc/revenue_model/models/", game_name)
files <- list.files(directory, pattern = paste0("day_", day_from, "_to_day_", day_to, ".rds$"), full.names = TRUE)
model <- files[which.max(file.info(files)$ctime)] %>% readRDS()

# pull sql data for prediction
prediction_query <- read_lines("sql_queries/prediction_data_query.sql") %>% 
  glue_collapse(sep = "\n") %>% 
  glue_sql(.con = con)
prediction_data_raw <- dbGetQuery(con, prediction_query)

# preprocessing
prediction_data <- prediction_data_raw %>% 
  mutate(install_dt = ymd(install_dt),
         publisher_name = str_replace_na(publisher_name, "Unknown"),
         usa = as.numeric(usa)) %>%
  mutate(!!sessions_day_from := as.numeric(!! sym(sessions_day_from)),
         !!sum_session_time_day_from := as.numeric(!! sym(sum_session_time_day_from)),
         !!utility_day_from := as.numeric(!! sym(utility_day_from)),
         !!spend_day_from := as.numeric(!! sym(spend_day_from)),
         !!spend_day_to := as.numeric(!! sym(spend_day_to))) %>% 
  mutate(ios = if_else(platform == 'IOS', 1, 0)) %>% 
  mutate(is_publisher_organic = if_else(publisher_name == "organic", 1, 0),
         is_publisher_facebook = if_else(publisher_name == 'facebook', 1, 0)) %>%  # all 0's will indicate 'other'
  select_at(vars(s, ios, usa, is_publisher_organic, is_publisher_facebook, !!sessions_day_from, !!utility_day_from, recent_utility_ratio, !!spend_day_from, !!spend_day_to)) %>% 
  mutate(spender = if_else(!! sym(spend_day_to) == 0, FALSE, TRUE))

# predict
prediction_df <- prediction_data %>% 
  select(s) %>% 
  mutate(!! paste0("day_", day_from, "_day_", day_to) := revenue_predictions(model, new_data = prediction_data))
