-- !preview conn=con_athena

/*gets data for a given game cohort*/
select * 
from {rlang::parse_exprs(glue('revenue_predictions.{game_name}'))}
where year || '-' || month || '-' || day = {cohort_date}
