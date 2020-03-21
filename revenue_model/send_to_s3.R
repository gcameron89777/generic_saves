# With the revenue poredictions, send them to S3 ----


#libraries
# library(noctua) # remotes::install_github("dyfanjones/noctua", ref = "retry")
# noctua_options(retry = 20) # how many times to retry with dbWriteTable
source('/home/rstudio-gavin/analysis/radhoc/revenue_model/functions/general_functions.R', local = T) # for try_backoff

# connections
con_s3 <- DBI::dbConnect(noctua::athena(), s3_staging_dir = "s3://ourco-emr/tables/revenue_predictions.db")
con_athena <- DBI::dbConnect(odbc(), "Athena")

# for cohorts
yr <- year(cohort_date) %>% toString()
mt <- format(cohort_date %>% as.Date(), '%m')
d <- format(cohort_date %>% as.Date(), '%d')

## download existing data
cohort_query <- read_lines("/home/rstudio-gavin/analysis/radhoc/revenue_model/sql_queries/cohorts_data.sql") %>% 
  glue_collapse(sep = "\n") %>% 
  glue_sql(.con = con_athena)
cohort_data <- dbGetQuery(con_athena, cohort_query)

if(cohort_data %>% nrow() == 0) { # first entry for this cohort, likely day 30 horizon
  
  try_backoff(
    dbWriteTable(conn = con_s3,
                 name = paste0("revenue_predictions.", game_name),
                 value = prediction_df,
                 append = T,
                 overwrite = F,
                 file.type = "parquet",
                 partition = c(year = yr, month = mt, day = d),
                 s3.location = paste0("s3://ourco-emr/tables/revenue_predictions.db/", game_name)
    ),
    max_attempts = 20,
    verbose = T)
  
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
                 s3.location = paste0("s3://ourco-emr/tables/revenue_predictions.db/", game_name)
    ),
    max_attempts = 20,
    verbose = T)
}