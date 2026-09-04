-- value_by_engaged_time
-- One row per engaged-time band
-- Engaged time = gaps between consecutive events, each capped at 30
-- minutes, summed up to the first purchase.
-- This removes idle time: mean falls 74.7 -> 30.1, median stays 19.08.
-- revenue > 0 drops the 403 purchases (8.4%) recording zero revenue,
-- so this page covers 4,391 of 4,794 purchases.

WITH
  capped AS (
    SELECT
      PARSE_DATE('%Y%m%d', CAST(event_date AS STRING)) AS day,
      user_pseudo_id,
      event_name,
      event_timestamp AS ts,
      ecommerce.purchase_revenue_in_usd AS purchase_revenue_in_usd,
      ecommerce.total_item_quantity     AS total_item_quantity,
      LEAST(
        IFNULL(
          event_timestamp - LAG(event_timestamp)
            OVER (
              PARTITION BY user_pseudo_id, event_date
              ORDER BY event_timestamp
            ),
          0),
        30 * 60 * 1000000) AS active_gap_us  
    FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
    WHERE
      _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'   -- prune the wildcard scan
      AND user_pseudo_id IS NOT NULL
      AND PARSE_DATE('%Y%m%d', CAST(event_date AS STRING))
        BETWEEN DATE '2020-11-01'
        AND DATE '2021-01-31'
  ),
  purch AS ( 
    SELECT
      day,
      user_pseudo_id,
      MIN(ts) AS t_purchase,
      ARRAY_AGG(purchase_revenue_in_usd IGNORE NULLS ORDER BY ts LIMIT 1)[
        SAFE_OFFSET(0)] AS revenue,
      ARRAY_AGG(total_item_quantity IGNORE NULLS ORDER BY ts LIMIT 1)[
        SAFE_OFFSET(0)] AS items
    FROM capped
    WHERE event_name = 'purchase'
    GROUP BY day, user_pseudo_id
  ),
  eng AS (
    SELECT
      SUM(IF(c.ts <= p.t_purchase, c.active_gap_us, 0)) / 60e6
        AS engaged_minutes,
      ANY_VALUE(p.revenue) AS revenue,
      ANY_VALUE(p.items) AS items
    FROM capped c
    JOIN purch p
      USING (day, user_pseudo_id)
    WHERE p.revenue > 0
    GROUP BY c.day, c.user_pseudo_id
  )
SELECT
  CASE
    WHEN engaged_minutes < 5 THEN '1 · under 5 min'
    WHEN engaged_minutes < 15 THEN '2 · 5–15 min'
    WHEN engaged_minutes < 30 THEN '3 · 15–30 min'
    WHEN engaged_minutes < 60 THEN '4 · 30–60 min'
    ELSE '5 · 60 min +'
    END AS engaged_band,
  COUNT(*) AS orders,
  ROUND(SUM(revenue), 2) AS total_revenue,
  ROUND(AVG(revenue), 2) AS mean_order_value,
  ROUND(APPROX_QUANTILES(revenue, 100)[SAFE_OFFSET(50)], 2)
    AS median_order_value,
  ROUND(AVG(items), 2) AS mean_items,
  ROUND(SUM(revenue) / SUM(items), 2) AS price_per_item
FROM eng
GROUP BY engaged_band;