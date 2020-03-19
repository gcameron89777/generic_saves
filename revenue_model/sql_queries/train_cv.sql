-- !preview conn=con

/*day_from to day_to training data query*/
with

/*
Athena installs data. After deducting the training period, get the preceeding 90 days of installs for training.
*/
installs as (
select s, 
       install_dt, 
       split(game_name, '_')[2] as platform,
       case when country = 'United States' then 1 else 0 end as usa
from device_metrics.game_install
where year || '-' || month || '-' || day >= date_format(date_add('day', -({day_to} + 91), date_parse({training_date}, '%Y-%m-%d')), '%Y-%m-%d')
and year || '-' || month || '-' || day <= date_format(date_add('day', -({day_to} + 1), date_parse({training_date}, '%Y-%m-%d')), '%Y-%m-%d')
and regexp_like(lower(game_name), ('^(?!.*QA).*' || {game_name} || '.*')) -- excludes 'QA' devices
),


/* 
Get marketing data from adx.
Full quarter of training data with at least one full m day cycle i.e. last full quarter + m days 
*/
adx_min as (
select 
  adx_id,
  publisher_name,
  row_number() over(partition by adx_id order by time_stamp asc) rn -- some dups, get first instance of an install
from ourco_ui_dev.adxdata_match_v2
where lower(game_name) = {game_name}
and concat(yy,'-',mm,'-',dd) >= date_format(date_add('day', -({day_to} + 91), date_parse({training_date}, '%Y-%m-%d')), '%Y-%m-%d')
and concat(yy,'-',mm,'-',dd) <= date_format(date_add('day', -({day_to} + 1), date_parse({training_date}, '%Y-%m-%d')), '%Y-%m-%d')
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
*/
installs_base as (
select 
  i.s,
  min(i.install_dt) as install_dt,
  min(i.platform) as platform,
  min(i.usa) as usa,
  min(a.publisher_name) as publisher_name
from installs i 
left join adx a on upper(if(i.s like 'IDFV%', substr(i.s,6), i.s)) = a.adx_id 
group by i.s
),


/*
day from sessions count
*/
sessions_day_from as (
select i.s,
       count(1) as sessions_day_from,
       sum(session_length) / 1000 as sum_session_time_secs_from
from installs_base i        
join device_metrics.user_game_session sess on sess.s = i.s
where regexp_like(lower(sess.game_name), '^(?!.*QA).*' || {game_name} || '.*')
and date_diff('day', date_parse(i.install_dt, '%Y-%m-%d'), date_parse(sess.activity_date, '%Y-%m-%d')) <= {day_from}
group by i.s
),


/*
day from utility
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
day from spend
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
day to spend (target)
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
  coalesce(sf.sessions_day_from, 0) as sessions_day_from,
  coalesce(sum_session_time_secs_from, 0) as sum_session_time_secs_from,
  coalesce(uf.utility_day_from, 0) as utility_day_from,
  coalesce(sdf.spend_day_from, 0) as spend_day_from,
  round(coalesce(ru.recent_utility_sum / uf.utility_day_from, 0), 2) as recent_utility_ratio,
  coalesce(sdt.spend_day_to, 0) as spend_day_to
from installs_base i 
left join sessions_day_from sf on sf.s = i.s 
left join utility_day_from uf on uf.s = i.s 
left join spend_day_from sdf on sdf.s = i.s
left join utility_recent ru on ru.s = i.s
left join spend_day_to sdt on sdt.s = i.s

