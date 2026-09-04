-- daily_duration
-- One row per day. Feeds: Buyers, Conversion Rate, the hero trend,
-- Buyers per day, Conversion per day.
-- Percentiles are per-day for the trend chart only.

WITH user_day AS (
  SELECT
    PARSE_DATE('%Y%m%d', CAST(event_date AS STRING)) AS day,
    user_pseudo_id,
    (MIN(IF(event_name = 'purchase', event_timestamp, NULL))
       - MIN(event_timestamp)) / 60e6 AS m 
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE user_pseudo_id IS NOT NULL
  GROUP BY day, user_pseudo_id
)
SELECT
  day,
  COUNT(*) AS active_users,
  COUNTIF(m IS NOT NULL) AS purchasers,
  ROUND(AVG(m), 1) AS avg_minutes,
  ROUND(APPROX_QUANTILES(m, 100)[SAFE_OFFSET(25)], 1) AS p25_minutes,
  ROUND(APPROX_QUANTILES(m, 100)[SAFE_OFFSET(50)], 1) AS median_minutes,
  ROUND(APPROX_QUANTILES(m, 100)[SAFE_OFFSET(75)], 1) AS p75_minutes,
  ROUND(APPROX_QUANTILES(m, 100)[SAFE_OFFSET(90)], 1) AS p90_minutes
FROM user_day
GROUP BY day;