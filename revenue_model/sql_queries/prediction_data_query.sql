-- !preview conn=con

with

/*
Athena installs data. After deducting the training period, get the corresponding day_to data to predict for
*/
installs as (
select s, 
       install_dt, 
       split(game_name, '_')[2] as platform,
       case when country = 'United States' then 1 else 0 end as usa
from device_metrics.game_install
where regexp_like(lower(game_name), ('^(?!.*QA).*' || {game_name} || '.*')) -- excludes 'QA' devices
and year || '-' || month || '-' || day = {cohort_date}
),


/* 
Get marketing data from adx.
Full quarter of training data with at least one full day_m day cycle i.e. last full quarter + day_m days 
*/
adx_min as (
select 
  adx_id,
  publisher_name,
  row_number() over(partition by adx_id order by time_stamp asc) rn -- some dups, get first instance of an install
from ourco_ui_dev.adxdata_match_v2
where lower(game_name) = {game_name}
and concat(yy,'-',mm,'-',dd) = {cohort_date}
--and concat(yy,'-',mm,'-',dd) >= date_format(date_add('day', -({day_to} + 91), current_date), '%Y-%m-%d')
--and concat(yy,'-',mm,'-',dd) <= date_format(date_add('day', -({day_to} + 1), current_date), '%Y-%m-%d')
),


/*
Dedupped installs based on earliest timestamp
*/
adx as (
select 
  adx_id,
  publisher_name
from adx_min
where rn = 1
),


/*
installs and marketing dta where exists
use min/max to dedup, some cases with a single s assoociated with multiple platforms
Use left join since singular misses some ourco data
*/
installs_base as (
select 
  i.s,
  i.usa,
  min(i.install_dt) as install_dt,
  min(i.platform) as platform,
  min(a.publisher_name) as publisher_name
from installs i 
left join adx a on upper(if(i.s like 'IDFV%', substr(i.s,6), i.s)) = a.adx_id 
group by i.s, i.usa
),


/*
day n sessions count
*/
sessions_day_from as (
select i.s,
       count(1) as sessions_day_from,
       sum(session_length) / 1000 as sum_session_time_day_from
from installs_base i        
join device_metrics.user_game_session sess on sess.s = i.s
where regexp_like(lower(sess.game_name), '^(?!.*QA).*' || {game_name} || '.*')
and date_diff('day', date_parse(i.install_dt, '%Y-%m-%d'), date_parse(sess.activity_date, '%Y-%m-%d')) <= {day_from}
group by i.s
),


/*
day n utility
*/
utility_day_from as (
select 
  u.s,
  sum(u.utility) as utility_day_from
from installs_base i
join adhoc.device_sessions_daily u on u.s = i.s
where lower(u.game_base) = {game_name}
and date_diff('day', date_parse(i.install_dt, '%Y-%m-%d'), u.activity_date) <= {day_from}
group by u.s
),


/*
recent utility. Are users continuing to play the game more recently or did they drop off.
*/
utility_recent as (
select 
  u.s,
  sum(u.utility) as recent_utility_sum
from installs_base i
join adhoc.device_sessions_daily u on u.s = i.s
where lower(u.game_base) = {game_name}
and date_diff('day', date_parse(i.install_dt, '%Y-%m-%d'), u.activity_date) <= floor({day_from} / 2)
group by u.s
),


/*
day n spend
*/
spend_day_from as (
select 
  i.s, 
  sum(dr.amt) as spend_day_from
from device_metrics.daily_revenue dr
join installs_base i on i.s = dr.s
where coalesce(channel,'IAP') = 'IAP'
and regexp_like(lower(game_name), ('^(?!.*QA).*' || {game_name} || '.*')) -- excludes 'QA' devices
and date_diff('day', date_parse(i.install_dt, '%Y-%m-%d'), date_parse(dr.activity_date, '%Y-%m-%d')) <= {day_from}
group by 1
),


/*
day m target spend (target)
*/
spend_day_to as (
select 
  i.s, 
  sum(dr.amt) as spend_day_to
from device_metrics.daily_revenue dr
join installs_base i on i.s = dr.s
where coalesce(channel,'IAP') = 'IAP'
and regexp_like(lower(game_name), ('^(?!.*QA).*' || {game_name} || '.*')) -- excludes 'QA' devices
and date_diff('day', date_parse(i.install_dt, '%Y-%m-%d'), date_parse(dr.activity_date, '%Y-%m-%d')) <= {day_to}
group by 1
)


select 
  i.s,
  i.install_dt,
  i.platform,
  i.usa,
  i.publisher_name,
  coalesce(sn.sessions_day_from, 0) as {rlang::parse_exprs(glue('sessions_day_{day_from}'))},
  coalesce(sn.sum_session_time_day_from, 0) as {rlang::parse_exprs(glue('sum_session_time_day_{day_from}'))},
  coalesce(un.utility_day_from, 0) as {rlang::parse_exprs(glue('utility_day_{day_from}'))},
  coalesce(spn.spend_day_from, 0) as {rlang::parse_exprs(glue('spend_day_{day_from}'))},
  round(coalesce(ru.recent_utility_sum / un.utility_day_from, 0), 2) as recent_utility_ratio,
  coalesce(spm.spend_day_to, 0) as {rlang::parse_exprs(glue('spend_day_{day_to}'))}
from installs_base i 
left join sessions_day_from sn on sn.s = i.s 
left join utility_day_from un on un.s = i.s 
left join spend_day_from spn on spn.s = i.s
left join utility_recent ru on ru.s = i.s
left join spend_day_to spm on spm.s = i.s