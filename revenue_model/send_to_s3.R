source('functions/general_functions.R', local = T) # for try_backoff

con_s3 <- DBI::dbConnect(noctua::athena(), s3_staging_dir = paste0("s3://glu-emr/tables/revenue_predictions.", game_name))
con_athena <- DBI::dbConnect(odbc(), "Athena")

yr <- year(cohort_date)
mt <- format(cohort_date %>% as.Date(), '%m')
d <- format(cohort_date %>% as.Date(), '%d')

  
  ## download existing data
  cohort_query <- read_lines("sql_queries/cohorts_data.sql") %>% 
    glue_collapse(sep = "\n") %>% 
    glue_sql(.con = con_athena)
  cohort_data <- dbGetQuery(con_athena, cohort_query)
  
  if(cohort_data %>% nrow() == 0) { # first entry for this cohort, likely day 30 horizon
  
    try_backoff(
    dbWriteTable(conn = con_s3,
                 name = paste0("revenue_predictions.", game_name),
                 value = prediction_df,
                 append = T,
                 file.type = "parquet",
                 partition = c(year = yr, month = mt, day = d),
                 s3.location = paste0("s3://ourco-emr/tables/revenue_predictions.", game_name)
                 ),
    verbose = T,
    max_attempts = 20
    )
    
  } else { # else amend existing row
  
  ## join onto local prediction_df
  cohort_data <- cohort_data %>% 
    select_at(vars(-c(paste0("day_", day_from, "_day_", day_to)))) %>% 
    left_join(prediction_df, by = "s") %>% # left join in case it's first field added for this cohort
    select_at(vars(s, day_7_day_30, day_7_day_60, day_7_day_90, day_7_day_120)) # remove partitions, those will be re added below
  
  ## push the new df (even though setting says append, this seems to update as desired)
  try_backoff(
    dbWriteTable(conn = con_s3,
                 name = paste0("revenue_predictions.", game_name),
                 value = cohort_data,
                 append = T,
                 overwrite = F,
                 file.type = "parquet",
                 partition = c(year = yr, month = mt, day = d),
                 s3.location = paste0("s3://ourco-emr/tables/revenue_predictions.", game_name)),
    verbose = T,
    max_attempts = 20
  )
}