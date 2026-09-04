-- user_daily_detail
-- One row per PURCHASING user-day. Feeds: Median Minutes and Average
-- Only source carrying user_type, so only it can drive a New/Returning control.

WITH ud AS (
  SELECT
    PARSE_DATE('%Y%m%d', CAST(event_date AS STRING)) AS day,
    user_pseudo_id,
    LOGICAL_OR(event_name = 'first_visit') AS is_new,
    COUNT(*) AS events_that_day,
    (MIN(IF(event_name = 'purchase', event_timestamp, NULL))
       - MIN(event_timestamp)) / 60e6 AS minutes
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE user_pseudo_id IS NOT NULL
  GROUP BY day, user_pseudo_id
)
SELECT
  day,
  user_pseudo_id,
  IF(is_new, 'New', 'Returning') AS user_type,
  events_that_day,
  ROUND(minutes, 2) AS minutes_to_purchase,
  CASE
    WHEN minutes <   5 THEN '1 · under 5 min'
    WHEN minutes <  15 THEN '2 · 5–15 min'
    WHEN minutes <  30 THEN '3 · 15–30 min'
    WHEN minutes <  60 THEN '4 · 30–60 min'
    WHEN minutes < 180 THEN '5 · 1–3 h'
    WHEN minutes < 360 THEN '6 · 3–6 h'
    ELSE '7 · 6 h +'
  END AS duration_band
FROM ud
WHERE minutes IS NOT NULL;