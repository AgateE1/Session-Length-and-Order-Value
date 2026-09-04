-- =============================================================================
-- Why do 403 purchasing user-days have no revenue?
--
-- value_by_engaged_time uses WHERE p.revenue > 0, which silently drops BOTH
-- nulls and genuine zeros. Those have different causes and different fixes, so
-- step one is telling them apart.
--
-- Run all four parts. Part A alone usually decides it.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- A. NULL or ZERO? And do those orders still have items?
--
-- This is the whole question in one result.
-- -----------------------------------------------------------------------------
WITH purch AS (
  SELECT
    PARSE_DATE('%Y%m%d', CAST(event_date AS STRING)) AS day,
    user_pseudo_id,
    ARRAY_AGG(ecommerce.purchase_revenue_in_usd IGNORE NULLS ORDER BY event_timestamp LIMIT 1)[SAFE_OFFSET(0)] AS revenue,
    ARRAY_AGG(ecommerce.total_item_quantity     IGNORE NULLS ORDER BY event_timestamp LIMIT 1)[SAFE_OFFSET(0)] AS items,
    COUNT(*) AS purchase_events
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE event_name = 'purchase'
    AND user_pseudo_id IS NOT NULL
    AND PARSE_DATE('%Y%m%d', CAST(event_date AS STRING))
        BETWEEN DATE '2020-11-01' AND DATE '2021-01-31'
  GROUP BY day, user_pseudo_id
)
SELECT
  CASE
    WHEN revenue IS NULL THEN 'A · revenue IS NULL'
    WHEN revenue = 0     THEN 'B · revenue = 0'
    ELSE                      'C · revenue > 0 (kept by the dashboard)'
  END AS revenue_state,
  COUNT(*)                                    AS buyer_days,
  COUNTIF(items IS NULL)                      AS also_missing_items,
  COUNTIF(items > 0)                          AS has_items,
  ROUND(AVG(items), 2)                        AS avg_items,
  SUM(purchase_events)                        AS purchase_events
FROM purch
GROUP BY revenue_state
ORDER BY revenue_state;

-- HOW TO READ IT
--   A + B should sum to 403, and C should be 4,391.
--
--   If nearly all 403 are in A (NULL) ............ a tracking problem
--   If nearly all 403 are in B (zero) ............ genuinely free orders
--   If A rows still have items > 0 ............... the order was real, only the
--                                                  money field failed to record
--   If A rows have NULL items too ................ the whole ecommerce payload
--                                                  is missing from the event


-- -----------------------------------------------------------------------------
-- B. Is it a period, or is it spread out?
--
-- A tracking break clusters in time. A business reason does not.
-- -----------------------------------------------------------------------------
SELECT
  DATE_TRUNC(PARSE_DATE('%Y%m%d', CAST(event_date AS STRING)), MONTH) AS month,
  COUNT(*)                                                  AS purchase_events,
  COUNTIF(ecommerce.purchase_revenue_in_usd IS NULL)                  AS null_revenue,
  COUNTIF(ecommerce.purchase_revenue_in_usd = 0)                      AS zero_revenue,
  ROUND(100 * COUNTIF(ecommerce.purchase_revenue_in_usd IS NULL
                      OR ecommerce.purchase_revenue_in_usd = 0)
            / COUNT(*), 1)                                  AS pct_no_revenue
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE event_name = 'purchase'
  AND PARSE_DATE('%Y%m%d', CAST(event_date AS STRING))
      BETWEEN DATE '2020-11-01' AND DATE '2021-01-31'
GROUP BY month
ORDER BY month;

-- HOW TO READ IT
--   Roughly flat 8% every month ......... structural. Something about how a
--                                         subset of orders is recorded.
--   Concentrated in one month ........... a tracking outage, like the
--                                         add-to-cart gap in November.


-- -----------------------------------------------------------------------------
-- C. Look at twenty of them
--
-- Nothing beats reading the actual rows.
-- -----------------------------------------------------------------------------
SELECT
  PARSE_DATE('%Y%m%d', CAST(event_date AS STRING)) AS day,
  user_pseudo_id,
  TIMESTAMP_MICROS(event_timestamp)                AS event_ts,
  ecommerce.purchase_revenue_in_usd,
  ecommerce.total_item_quantity
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE event_name = 'purchase'
  AND (ecommerce.purchase_revenue_in_usd IS NULL OR ecommerce.purchase_revenue_in_usd = 0)
  AND PARSE_DATE('%Y%m%d', CAST(event_date AS STRING))
      BETWEEN DATE '2020-11-01' AND DATE '2021-01-31'
ORDER BY event_ts
LIMIT 20;

-- WHAT TO LOOK FOR
--   * Do these users have a normal-looking day around the purchase, or do they
--     look like a bot or a test account (very few events, odd timing)?
--   * Do several land in the same minute? That suggests automated test orders.
--   * Is total_item_quantity populated? If yes, the basket was real.


-- -----------------------------------------------------------------------------
-- D. Do those users behave differently otherwise?
--
-- If the no-revenue user-days have the same duration profile as the rest, the
-- exclusion does not bias page 2. If they are systematically faster or slower,
-- it might.
-- -----------------------------------------------------------------------------
WITH ud AS (
  SELECT
    PARSE_DATE('%Y%m%d', CAST(event_date AS STRING)) AS day,
    user_pseudo_id,
    (MIN(IF(event_name = 'purchase', event_timestamp, NULL))
       - MIN(event_timestamp)) / 60e6 AS minutes,
    MAX(IF(event_name = 'purchase', ecommerce.purchase_revenue_in_usd, NULL)) AS revenue
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE user_pseudo_id IS NOT NULL
    AND PARSE_DATE('%Y%m%d', CAST(event_date AS STRING))
        BETWEEN DATE '2020-11-01' AND DATE '2021-01-31'
  GROUP BY day, user_pseudo_id
  HAVING minutes IS NOT NULL
)
SELECT
  IF(revenue > 0, 'kept (revenue > 0)', 'dropped (null or zero)') AS grp,
  COUNT(*)                                                     AS buyer_days,
  ROUND(AVG(minutes), 1)                                       AS mean_minutes,
  ROUND(APPROX_QUANTILES(minutes, 100)[SAFE_OFFSET(50)], 1)    AS median_minutes
FROM ud
GROUP BY grp;

-- HOW TO READ IT
--   Similar medians .... the 403 are a random slice, so page 2 is unbiased and
--                        you can say so.
--   Very different ..... the exclusion is selective and page 2's gradient needs
--                        a caveat.
