-- funnel_timing
-- Four rows, one per journey leg. 
-- GREATEST holds the 26 Nov floor no matter where the date control is
-- dragged 
-- the cart outage would otherwise corrupt legs 2 and 3

WITH
  ud AS (
    SELECT
      MIN(event_timestamp) AS t_first,
      MIN(IF(event_name = 'view_item', event_timestamp, NULL)) AS t_view,
      MIN(IF(event_name = 'add_to_cart', event_timestamp, NULL)) AS t_cart,
      MIN(IF(event_name = 'begin_checkout', event_timestamp, NULL))
        AS t_checkout,
      MIN(IF(event_name = 'purchase', event_timestamp, NULL)) AS t_purchase
    FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
    WHERE
      _TABLE_SUFFIX BETWEEN '20201126' AND '20210131'   -- prune the wildcard scan
      AND user_pseudo_id IS NOT NULL
      AND PARSE_DATE('%Y%m%d', CAST(event_date AS STRING))
        BETWEEN GREATEST(DATE '2020-11-26', DATE '2020-11-01')
        AND DATE '2021-01-31'
    GROUP BY event_date, user_pseudo_id
    HAVING
      t_view IS NOT NULL
      AND t_cart IS NOT NULL
      AND t_checkout IS NOT NULL
      AND t_purchase IS NOT NULL
  ),
  legs AS (
    SELECT
      GREATEST(t_view - t_first, 0) / 60e6 AS leg1,
      GREATEST(t_cart - t_view, 0) / 60e6 AS leg2,
      GREATEST(t_checkout - t_cart, 0) / 60e6 AS leg3,
      GREATEST(t_purchase - t_checkout, 0) / 60e6 AS leg4,
      (t_purchase - t_first) / 60e6 AS total
    FROM ud
  ),
  clean AS (
    SELECT *
    FROM legs
    WHERE total > 0 AND ABS(leg1 + leg2 + leg3 + leg4 - total) < 0.02
  )
SELECT
  'Average buyer journey' AS journey,
  stage,
  ROUND(100 * AVG(leg / total), 1) AS pct_of_journey,
  ROUND(APPROX_QUANTILES(leg, 100)[SAFE_OFFSET(50)], 2) AS median_minutes,
  COUNT(*) AS buyers
FROM
  clean
    UNPIVOT(
      leg
        FOR
          stage IN (
            leg1 AS '1 · Arrive → item view',
            leg2 AS '2 · Item view → add to cart',
            leg3 AS '3 · Add to cart → checkout',
            leg4 AS '4 · Checkout → purchase'))
GROUP BY stage;