-- funnel_stages
-- One row per day per stage. Feeds the drop-off funnel and
-- the cart-tracking-outage time series. 

WITH d AS (
  SELECT
    PARSE_DATE('%Y%m%d', CAST(event_date AS STRING)) AS day,
    COUNT(DISTINCT user_pseudo_id) AS arrived,
    COUNT(DISTINCT IF(event_name = 'view_item', user_pseudo_id, NULL)) AS viewed_item,
    COUNT(DISTINCT IF(event_name = 'add_to_cart', user_pseudo_id, NULL)) AS added_to_cart,
    COUNT(DISTINCT IF(event_name = 'begin_checkout', user_pseudo_id, NULL)) AS began_checkout,
    COUNT(DISTINCT IF(event_name = 'purchase', user_pseudo_id, NULL)) AS purchased
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE user_pseudo_id IS NOT NULL
  GROUP BY day
)
SELECT day, stage, users
FROM d UNPIVOT(users FOR stage IN (
  arrived AS '1 · Arrived',
  viewed_item AS '2 · Viewed item',
  added_to_cart AS '3 · Added to cart',
  began_checkout AS '4 · Checkout',
  purchased AS '5 · Purchased'));