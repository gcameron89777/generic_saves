

### predict xgb ###
revenue_predictions <- function(model_obj, new_data) {
  
  # debugging
  # model_obj <- model
  # new_data <- prediction_data
  
  algorithm <- model_obj$model_description %>% str_split("_") %>% unlist() %>% pluck(1)
  
  # expected that this script is called by predict.R, in which case regression and binary training features vector variables will have been loaded
  training_features <- c(regression_training_features, binary_training_features) %>% unique() 
  
  ### This function returns a vector of predictions using a hurdle approach
  # model: a pre trained model
  # new_data: data pulled from glu for making predictions on with the required fields
  
  # define data for fitting
  new_data <- new_data %>% select(training_features)
  
  ## create xgb.DMatrix if xgb
  ## currently only XGB anyway, removed ranger and glm
    
    # new data for the binary model dmatrix
    new_data_binary <- new_data %>% 
      select_at(vars(-c(spend_from, spend_to, binary_target))) %>% 
      as.matrix() %>%
      xgboost::xgb.DMatrix(label = as.numeric(new_data[[binary_target]]))
    
    # new data for the regression model dmatrix
    new_data_regression <- new_data %>% 
      select_at(vars(-binary_target, -spend_to)) %>% as.matrix() %>% xgboost::xgb.DMatrix(label = new_data %>% .[[spend_to]])
    
    predict_spenders = predict(model_obj$binary_model, new_data_binary)
    predict_spend = predict(model_obj$regression_model, new_data_regression) 
    predictions_product = ifelse(new_data[[spend_day_from]] > 0, predict_spend, predict_spenders * predict_spend)
    predictions_hurdle = ifelse(new_data[[spend_day_from]] > 0, predict_spend, 
                                ifelse(predict_spenders > (model_obj$params$hurdle_pct / 100), predict_spend, predict_spenders * predict_spend))
  
  # return the predictions vector
  # return(predictions_product)
  return(predictions_hurdle)
}