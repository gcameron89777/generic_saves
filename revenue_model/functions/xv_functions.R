
### fit xgb ###
fit_xgb <- function(train_df, test_df, training_features, best_model, binary_target, spend_day_from, spend_day_to) {
  
  ### This function returns out of sample rmse using xgboost ###
  # training_df: data frame
  # test_df: hold out test set df
  # training_features: vector of features
  # nrounds: hyperparameter value
  # binary target: str of binary part target
  
  # define data for fitting
  training_data <- train_df %>% select(training_features)
  testing_data <- test_df %>% select(training_features)
  
  ## create xgb.DMatrix in case of xgboost
  # train data for the binary model dmatrix
  training_data_binary_xgb_dm <- training_data %>% 
    select_at(vars(-c(spend_day_from, spend_day_to, binary_target))) %>% 
    as.matrix() %>%
    xgb.DMatrix(label = as.numeric(training_data %>% .[[binary_target]]))
  
  # test data for the binary model dmatrix
  testing_data_binary_xgb_dm <- testing_data %>% 
    select_at(vars(-c(spend_day_from, spend_day_to, binary_target))) %>% 
    as.matrix() %>% 
    xgb.DMatrix(label = as.numeric(testing_data %>% .[[binary_target]]))  
  
  # train data for the regression model dmatrix
  training_data_regression_xgb_dm <- training_data %>% 
    select_at(vars(-binary_target, -spend_day_to)) %>% 
    as.matrix() %>% 
    xgb.DMatrix(label = training_data %>% .[[spend_day_to]])
  
  # test data for the  regression model dmatrix
  testing_data_regression_xgb_dm <- testing_data %>% 
    select_at(vars(-binary_target, -spend_day_to)) %>% 
    as.matrix() %>% 
    xgb.DMatrix(label = testing_data %>% .[[spend_day_to]])
  
  # fit model on full training data
  # binary model
  binary_model <- xgboost(training_data_binary_xgb_dm, nrounds = best_model$nrounds, eta = best_model$eta, objective = "binary:logistic")
  
  # regression model
  regression_model <- xgboost(training_data_regression_xgb_dm, nrounds = best_model$nrounds, eta = best_model$eta, objective = "reg:squarederror")
  
  # predictions for spenders (classification)
  predict_spenders = predict(binary_model, testing_data_binary_xgb_dm)
  
  # predictions for spend
  predict_spend <- predict(regression_model, testing_data_regression_xgb_dm)
  
  # use regression prediction on those predicted to be spenders, 0 otherwise. Also 0 where prediction is < 0
  ## leave it out, all predictions are less than 0.5 rendering this approach pointless, use product instead
  # predictions_on_spenders <- ifelse(predict_spenders < 0.5, 0, ifelse(predict_spend < 0, 0, predict_spend))
  
  # predictions based on spender probability * regression prediction. Also set minimum to 0
  predictions_hurdle = ifelse(test_df[[spend_day_from]] > 0, predict_spend, 
                               ifelse(predict_spenders > (best_model$hurdle_pct / 100), predict_spenders, predict_spenders * predict_spend))
  
  # rmse
  test_rmse_hurdle_approach <- Metrics::rmse(actual = testing_data[[spend_day_to]], predicted = predictions_hurdle)
  
  # mae
  test_mae_hurdle_approach <- Metrics::mae(actual = testing_data[[spend_day_to]], predicted = predictions_hurdle)

  # matrix for feature importance
  binary_feature_importance_matrix <- xgb.importance(model = binary_model) 
  regression_feature_importance_matrix <- xgb.importance(model = regression_model)
  
  
  return(list(
    model_description = paste0("xgb_", game_name, "_", "day_", day_from, "_to_day_", day_to),
    binary_model = binary_model,
    regression_model = regression_model,
    test_rmse_hurdle_approach = test_rmse_hurdle_approach,
    test_mae_hurdle_approach = test_mae_hurdle_approach,
    binary_feature_importance_matrix = binary_feature_importance_matrix,
    regression_feature_importance_matrix = regression_feature_importance_matrix,
    params = best_model
  ))
  
}