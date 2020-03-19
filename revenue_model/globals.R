

# training features (includes target)
spend_from <- paste0("spend_day_", day_from)
spend_to <- paste0("spend_day_", day_to)

## training features from paste
sessions_day_from <- paste0("sessions_day_", day_from)
sessions_day_to <- paste0("sessions_day_", day_to)
sum_session_time_day_from <- paste0("sum_session_time_day_", day_from)
utility_day_from <- paste0("utility_day_", day_from)
spend_day_from <- paste0("spend_day_", day_from)
spend_day_to <- paste0("spend_day_", day_to)

# training features (includes target)
binary_training_features <- c(utility_day_from, 
                              "recent_utility_ratio", 
                              spend_day_from, #spend_day_from, # yes, needed for filtering before fitting where == 0
                              "ios", 
                              "usa",
                              "is_publisher_organic", 
                              "is_publisher_facebook", 
                              "spender")

regression_training_features <- c(utility_day_from, 
                                  "recent_utility_ratio", 
                                  spend_day_from,
                                  "ios", 
                                  "usa",
                                  "is_publisher_organic", 
                                  "is_publisher_facebook", 
                                  spend_day_to)
binary_target <- "spender"