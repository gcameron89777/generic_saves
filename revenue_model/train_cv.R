
### Reads in raw data via Athena and tunes and trains an XGB model using cross validation. Model saved in directory /models ###



# Libraries ----
library(tidyverse)
library(lubridate)
library(foreach)
library(doParallel) # includes package just parallel
library(scales)
library(dbplyr)
library(DBI)
library(odbc)
library(rlang)
library(glue)
library(rsample) # folds
library(Metrics) # Evaluation metrics

# source query and get dataframe
con <- dbConnect(odbc(), "Athena")
select <- dplyr::select



# Globals ----
## true global globals
game_name <- "fungame"
day_from <- 7 # train from
day_to <- 120 # predict to

# when running maually set a date here, else use a custom date
# will get data for preceeding 3 months to train with
# training_date <- Sys.Date()
training_date <- "2020-03-01"
source("globals.R", local = T) # format the globals



# Get Data ----
## write query & pull
rawd_query <- read_lines("sql_queries/train_cv.sql") %>% 
  glue_collapse(sep = "\n") %>% 
  glue_sql(.con = con)
rawd <- dbGetQuery(con, rawd_query)



## conflicts
select <- dplyr::select

# Preprocessing ----
pdata <- rawd %>% 
  mutate(install_dt = ymd(install_dt),
         publisher_name = str_replace_na(publisher_name, "Unknown"),
         usa = as.numeric(usa)) %>%
  mutate(!!sessions_day_from := as.numeric(sessions_day_from),
         !!sum_session_time_day_from := as.numeric(sum_session_time_secs_from),
         !!utility_day_from := as.numeric(utility_day_from),
         !!spend_day_from := as.numeric(spend_day_from),
         !!spend_day_to := as.numeric(spend_day_to)) %>% 
  mutate(ios = if_else(platform == 'IOS', 1, 0)) %>% 
  mutate(is_publisher_organic = if_else(publisher_name == "organic", 1, 0),
         is_publisher_facebook = if_else(publisher_name == 'facebook', 1, 0)) %>%  # all 0's will indicate 'other'
  select_at(vars(s, ios, usa, is_publisher_organic, is_publisher_facebook, !!sessions_day_from, !!utility_day_from, recent_utility_ratio, !!spend_day_from, !!spend_day_to)) %>% 
  mutate(spender = if_else(!! sym(spend_day_to) == 0, FALSE, TRUE))



# Splits & Folds ----
set.seed(42)
pdata <- sample_n(pdata, 1000000) # Ram issues

pdata_split <- initial_split(pdata, 0.9)
training_data <- training(pdata_split)
testing_data <- testing(pdata_split)

## 5 fold split stratified on spender
train_cv <- vfold_cv(training_data, 5, strata = binary_target) %>% 
  
  # create training and validation sets within each fold
  mutate(train = map(splits, ~training(.x)), 
         validate = map(splits, ~testing(.x))) %>% 
  
  # hacky way that somehow gets around the error message 'Error: `x` must be a vector, not a `rsplit/vfold_split` object'
  # unkown why this gets around it but it does
  group_by(id) %>% nest() %>% unnest() 

rm(list = c("pdata", "con", "rawd")); invisible(gc()) # save memory


# Training & Cross Validation ----
library(xgboost)
# workflow:
# for each fold
# 1 binary classifier
# 2 predict spenders
# 3 fit regression on actual spenders only
# 4 predict regression on all installs
# 5 prediction uses ifelse logic: 
#   a) if spender by from day then apply full regression amount
#   b) else if the binary probability passes a hurdle, also apply the full regression amount
#   c) else use the product of spender probability and regression expected spend amount

# cross validation folds
model_xgb <- train_cv %>% 
  crossing(nrounds = c(25, 50, 75)) %>%
  crossing(eta = c(.05, .1)) %>% 
  
  # subset data for classification part
  mutate(btrain = map(train, ~.x %>% select_at(vars(binary_training_features))),
         bvalidate = map(validate, ~.x %>% select_at(vars(binary_training_features)))) %>% 
  
  # subset data for the regression part
  ## only train on those with spend after day_to
  mutate(rtrain = map(train, ~.x %>% select_at(vars(regression_training_features))),
         rvalidate = map(validate, ~.x %>% select_at(vars(regression_training_features)))) %>% 
  
  # convert binary classification data to a dmatrix for speed and use less memory
  mutate(dtrain_binary = map(btrain, ~xgb.DMatrix(.x %>% select_at(vars(-binary_target)) %>%  as.matrix(), label = as.numeric(.x[[binary_target]]))),
         dvalidate_binary = map(bvalidate, ~xgb.DMatrix(.x %>% select_at(vars(-binary_target)) %>%  as.matrix(), label = as.numeric(.x[[binary_target]])))) %>% 
  
  # convert regression data to a dmatrix
  mutate(dtrain_regression = map(rtrain, ~xgb.DMatrix(.x %>% select_at(vars(-spend_day_to)) %>% as.matrix(), label = .x[[spend_day_to]])),
         dvalidate_regression = map(rvalidate, ~xgb.DMatrix(.x %>% select_at(vars(-spend_day_to)) %>% as.matrix(), label = .x[[spend_day_to]]))) %>% 
  
  mutate(
    
    # xgb binary classifier for each fold. Target is logical vector spender. 
    model_binary = pmap(list(.x = dtrain_binary, .y = nrounds, .z = eta), function(.x, .y, .z) {
      xgboost(.x, nrounds = .y, eta = .z, objective = "binary:logistic")
    }),
    
    # Regression for the spenders. Only fit on those with any spend after m days
    model_regression = pmap(list(.x = dtrain_regression, .y = nrounds, .z = eta), function(.x, .y, .z) {
      xgboost(.x, nrounds = .y, eta = .z, objective = "reg:squarederror")
    }
    )) %>% 
  
  mutate(
    
    # predictions for spenders (classification)
    validate_spenders = map2(.x = model_binary, .y = dvalidate_binary, ~predict(.x, .y)),
    
    # and amount (regression)
    validate_spend = map2(.x = model_regression, .y = dvalidate_regression, ~predict(.x, .y))) %>%  
  
  mutate(
    
    # use regression prediction on those predicted to be spenders, hurdle with product otherwise
    validate_predictions = map2(.x = validate_spenders, .y = validate_spend, ~ifelse(.x < 0.5, 0, ifelse(.y < 0, 0, .y))),
    validate_predictions_hurdle_10_pct = pmap(list(validate_spenders = validate_spenders, 
                                                   validate_spend = validate_spend, 
                                                   validate = validate,
                                                   hurdle = 0.1), 
                                              function(validate_spenders, validate_spend, validate, hurdle) { 
                                                ifelse(validate[[spend_day_from]] > 0, validate_spend, 
                                                       ifelse(validate_spenders > hurdle, validate_spend, validate_spenders * validate_spend))
                                              }),
    
    validate_predictions_hurdle_20_pct = pmap(list(validate_spenders = validate_spenders, 
                                                   validate_spend = validate_spend, 
                                                   validate = validate,
                                                   hurdle = 0.2), 
                                              function(validate_spenders, validate_spend, validate, hurdle) { 
                                                ifelse(validate[[spend_day_from]] > 0, validate_spend, 
                                                       ifelse(validate_spenders > hurdle, validate_spend, validate_spenders * validate_spend)) 
                                              }),
    validate_predictions_hurdle_30_pct = pmap(list(validate_spenders = validate_spenders, 
                                                   validate_spend = validate_spend, 
                                                   validate = validate,
                                                   hurdle = 0.3), 
                                              function(validate_spenders, validate_spend, validate, hurdle) { 
                                                ifelse(validate[[spend_day_from]] > 0, validate_spend, 
                                                       ifelse(validate_spenders > hurdle, validate_spend, validate_spenders * validate_spend)) 
                                              })      
  ) %>% 
  
  # actuals for validation
  mutate(validate_actual = map(validate, ~.x[[spend_day_to]]),
         validate_actual_spenders = map(validate, ~.x[[binary_target]])) %>% 
  
  # validation
  mutate(
    rmse_hurdle_10_pct = map2_dbl(.x = validate_actual, .y = validate_predictions_hurdle_10_pct, ~Metrics::rmse(actual = .x, predicted = .y)),
    rmse_hurdle_20_pct = map2_dbl(.x = validate_actual, .y = validate_predictions_hurdle_20_pct, ~Metrics::rmse(actual = .x, predicted = .y)),
    rmse_hurdle_30_pct = map2_dbl(.x = validate_actual, .y = validate_predictions_hurdle_30_pct, ~Metrics::rmse(actual = .x, predicted = .y))
  )


# Model List Comparisson ----
model_list <- model_xgb %>% mutate(hypers = paste0("nrounds=",nrounds, "_eta=",eta)) %>% split(.$hypers)
rmse_compare <- model_list %>% 
  imap(~tibble(
    model_name = .y,
    hurdle_10_pct = mean(.x$rmse_hurdle_10_pct),
    hurdle_20_pct = mean(.x$rmse_hurdle_20_pct),
    hurdle_30_pct = mean(.x$rmse_hurdle_30_pct)
  )) %>% 
  bind_rows() %>% 
  pivot_longer(ends_with("_pct"),
               names_to = "hurdle",
               values_to = "rmse") %>% 
  separate(hurdle, into = c(NA, "hurdle_pct", NA), sep = "_", remove = T, convert = T) %>% 
  separate(model_name, into = c("nrounds", "eta"), sep = "_") %>% 
  separate(nrounds, into = c(NA, "nrounds"), sep = "=", remove = T, convert = T) %>% 
  separate(eta, into = c(NA, "eta"), sep = "=", remove = T, convert = T) %>% 
  arrange(rmse)
rmse_compare %>% print()



# Out of Sample Test and Save Fully Fitted Model ----
source("functions/xv_functions.R", local = T)

## get the best model from cross validation
best_model <- rmse_compare %>% top_n(1, -rmse)
print("Best model is:")
best_model %>% print()

## parameters to pass to whichever algorithm is used
model_function_params <- list(
  train_df = training_data, 
  test_df = testing_data, 
  training_features <- c(regression_training_features, binary_training_features) %>% unique(),
  best_model = best_model,
  binary_target = binary_target,
  spend_day_from = spend_day_from,
  spend_day_to = spend_day_to)

## fit the final model
model_object <- do.call(fit_xgb, model_function_params)
model_object$regression_feature_importance_matrix %>% xgb.plot.importance()
model_object$model_description <- paste0("Out of sample test RMSE is: ", model_object$test_rmse_hurdle_approach %>% round(2),
                                         " Hurdle is: ", best_model$hurdle_pct / 100,
                                         " eta is: ", best_model$eta,
                                         " nrounds is: ", best_model$nrounds)
# summary for those interested
print(model_object$model_description)

## save the model for prediction
saveRDS(model_object, 
        paste0("models/",game_name,"/",game_name,"_",Sys.Date() %>% format("%Y%m%d") %>% tolower(),"_day_",day_from,"_to_day_",day_to, ".rds"))

