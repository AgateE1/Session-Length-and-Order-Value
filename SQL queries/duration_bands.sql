-- duration_bands
-- One row per elapsed-time band. Feeds "buyers vs elapsed time".
-- The two percentages divide by a grand total 

WITH ud AS (
  SELECT
    (MIN(IF(event_name = 'purchase', event_timestamp, NULL))
       - MIN(event_timestamp)) / 60e6 AS minutes
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'   -- prune the wildcard scan
    AND user_pseudo_id IS NOT NULL
    AND PARSE_DATE('%Y%m%d', CAST(event_date AS STRING))
        BETWEEN DATE '2020-11-01' AND DATE '2021-01-31'
  GROUP BY event_date, user_pseudo_id
  HAVING minutes IS NOT NULL
)
SELECT
  CASE
    WHEN minutes <   5 THEN '1 · under 5 min'
    WHEN minutes <  15 THEN '2 · 5–15 min'
    WHEN minutes <  30 THEN '3 · 15–30 min'
    WHEN minutes <  60 THEN '4 · 30–60 min'
    WHEN minutes < 180 THEN '5 · 1–3 h'
    WHEN minutes < 360 THEN '6 · 3–6 h'
    ELSE '7 · 6 h +'
  END AS band,
  COUNT(*) AS buyers,
  ROUND(100 * COUNT(*)/ SUM(COUNT(*)) OVER (), 1)  AS pct_of_buyers,
  ROUND(100 * SUM(minutes) / SUM(SUM(minutes)) OVER (), 1)  AS pct_of_minutes
FROM ud
GROUP BY band;