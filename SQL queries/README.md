# SQL Documentation

**Project:** Time to First Purchase
**Source table:** `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`

The public Google Analytics 4 sample e-commerce export (Google Merchandise Store), covering 1 Nov 2020 to 31 Jan 2021. Date-sharded, so the queries read it as a wildcard table and the three with a fixed window prune the scan with `_TABLE_SUFFIX`. Revenue and item quantity are nested under the `ecommerce` record in this export, which is why they appear as `ecommerce.purchase_revenue_in_usd` rather than as top-level columns.
**Companion to:** the analytical report (§3) and the Looker Studio dashboard

Six queries, each one a separate data source in Looker Studio. They are deliberately independent: every one recalculates what it needs from the raw events rather than joining to another query, so a change or a failure in one cannot corrupt the others.

| # | Query | Outputs | Feeds |
|---|---|---|---|
| 1 | `daily_duration` | one row per day | Buyers, Conversion Rate, main trend chart, buyers per day, conversion per day |
| 2 | `user_daily_detail` | one row per purchasing user-day | Median Minutes and Average scorecards |
| 3 | `duration_bands` | one row per time band (7) | "Two-thirds finish within 30 minutes", "5% hold half the elapsed time" |
| 4 | `funnel_stages` | one row per day per stage | the drop-off funnel, the cart-outage chart |
| 5 | `funnel_timing` | four rows, one per journey leg | "Cart → checkout: 47% of time" |
| 6 | `value_by_engaged_time` | one row per engaged-time band (5) | all of page 2: order value, items, price per item |

---

## Patterns used across all six

Explained once here, then referenced rather than repeated.

### `WITH name AS (...)` — a CTE

A named temporary result. Everything inside runs first, and the query below reads from it. Used throughout to collapse the raw event stream down to one row per person per day **before** any averaging happens. Without this step, an average would be computed across events rather than across people.

### `PARSE_DATE('%Y%m%d', CAST(event_date AS STRING))`

`event_date` is stored as a number like `20201101`. `CAST` turns it into the text `"20201101"`, and `PARSE_DATE` with the pattern `%Y%m%d` turns that text into a real `DATE`. Needed because Looker Studio cannot treat a plain number as a date.

Using `event_date` rather than deriving a date from the timestamp means the day boundary is the one GA4 already assigned, in the property's reporting timezone.

### `MIN(IF(event_name = 'x', event_timestamp, NULL))` — conditional aggregation

The workhorse of the whole project. The `IF` returns a timestamp only on rows matching that event, and `NULL` everywhere else. `MIN` ignores `NULL`s, so the result is the earliest occurrence of that event in the group.

Two consequences worth knowing:

- If the event never happened, every value is `NULL` and the result is `NULL`. That is used deliberately as a filter later.
- Several of these can sit side by side in one `SELECT`, so five milestones are found in a single pass over the table instead of five separate scans.

### `/ 60e6` — microseconds to minutes

`event_timestamp` is in microseconds. `60e6` is 60,000,000, the number of microseconds in a minute.

### `APPROX_QUANTILES(x, 100)[SAFE_OFFSET(n)]` — percentiles

`APPROX_QUANTILES(x, 100)` sorts the values and returns an array of 101 cut points. `[SAFE_OFFSET(50)]` takes the 50th, which is the median; `[SAFE_OFFSET(25)]` gives the 25th percentile, and so on.

`SAFE_OFFSET` returns `NULL` instead of throwing an error if the array is shorter than expected, which matters on quiet days with very few buyers. One thin day cannot break the query.

`APPROX` means this is a fast approximation rather than an exact percentile. At these row counts the difference is negligible, but it is worth knowing if a reviewer asks.

### `UNPIVOT(...)` — wide to long

Turns columns into rows. Before it, one day is one row with five columns. After it, one day is five rows with a label and a number:

| before | | | | after | | |
|---|---|---|---|---|---|---|
| day | arrived | viewed | | day | stage | users |
| 2020-12-01 | 4,102 | 1,205 | | 2020-12-01 | 1 · Arrived | 4,102 |
| | | | | 2020-12-01 | 2 · Viewed item | 1,205 |

Required because a Looker chart needs one dimension and one metric. It cannot plot five separate columns as five bars.

### `SUM(COUNT(*)) OVER ()` — a grand total

An empty `OVER ()` means "across every row in the result". So `COUNT(*) / SUM(COUNT(*)) OVER ()` gives each row's share of the total, without a second query or a self-join. This is why the percentage columns sum to 100.

### `'1 · ', '2 · '` prefixes on labels

Purely so Looker sorts correctly. It orders text alphabetically, which would otherwise place `15–30 min` before `5–15 min`.

---

## 1 · daily_duration

**One row per calendar day.** The backbone of page 1.

```sql
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
```

**Line by line**

- `PARSE_DATE(...) AS day` — see Patterns. Gives Looker a real date to plot.
- `user_pseudo_id` — the person. GA4's browser and device id, so one human on a phone and a laptop counts as two. Grouping by this plus day is what creates the **user-day**.
- `MIN(IF(event_name = 'purchase', ...)) - MIN(event_timestamp)` — **the core calculation.** `MIN(event_timestamp)` is the earliest event of any kind that day, so when they arrived. The conditional `MIN` is the earliest purchase. The difference is the time to purchase. `NULL` if they never bought.
- `/ 60e6 AS m` — converted to minutes.
- `WHERE user_pseudo_id IS NOT NULL` — drops rows with no user id, which cannot be grouped into a user-day.
- **No date filter.** The window is applied by the date control in Looker instead, which is why the report period can be changed without editing SQL.
- `GROUP BY day, user_pseudo_id` — one row out per person per day.
- `COUNT(*) AS active_users` — everyone active that day, buyers or not. The denominator of the conversion rate.
- `COUNTIF(m IS NOT NULL) AS purchasers` — `COUNTIF` counts rows where a condition is true. `m` is only non-null for people who bought, so this is the buyer count. The numerator. Conversion Rate itself is a calculated field in Looker: `purchasers / active_users`.
- `ROUND(AVG(m), 1) AS avg_minutes` — the mean. `AVG` ignores nulls, so it averages buyers only. Shown on the dashboard labelled "skewed" on purpose.
- `p25 / median / p75 / p90` — see Patterns. The median is the headline metric. The upper percentiles are not currently plotted, but they are what would reveal whether the slow tail is worsening independently of the median.

**Worth knowing**

These percentiles are **per day**, so a single day's median rests only on that day's buyers, which on quiet January days is under two dozen people. That is why the daily line is noisy and the chart carries a 7-day average on top.

The 19.1 headline does **not** come from here. It comes from query 2, which pools every buyer-day and takes one median across the whole period. Those two numbers answer slightly different questions and will not match exactly.

---

## 2 · user_daily_detail

**One row per purchasing user-day.** The finest grain in the project, and the source of the headline number.

```sql
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
```

**Line by line**

- `day`, `user_pseudo_id` — both kept in the output this time, because the result stays at row level rather than being aggregated.
- `LOGICAL_OR(event_name = 'first_visit') AS is_new` — an aggregate that answers "was this true on **any** row in the group?". So: did this person fire a `first_visit` event that day? If yes they are new, if no they are returning. It is the aggregate equivalent of OR-ing every row together.
- `COUNT(*) AS events_that_day` — how many events this person fired. A rough activity measure and a useful sanity check: a buyer with 2 events and a buyer with 200 are very different behaviours that can share the same duration.
- `MIN(IF(...)) - MIN(...)` — the same core calculation as query 1, deliberately recomputed rather than joined, so the sources stay independent.
- `GROUP BY day, user_pseudo_id` — one row per person per day. Again no date filter, so the Looker control drives the window.
- `IF(is_new, 'New', 'Returning') AS user_type` — turns the true/false into a readable label for a filter control.
- `ROUND(minutes, 2)` — two decimals, because at row level the precision is real. The scorecards round again to one for display.
- The `CASE` block — the same seven bands as query 3, recomputed here so this source can be split by band on its own. See Patterns for why the labels are numbered.
- `WHERE minutes IS NOT NULL` — buyers only. This is a `WHERE` and not a `HAVING` because `minutes` already exists as a column of the CTE by this point; the grouping happened inside `ud`.

**Worth knowing**

This is where **19.1 minutes** actually comes from. Looker takes a median across every row here, pooling all buyer-days in the period.

That is a different statistic from the daily medians in query 1. **This one weights every buyer equally. That one weights every day equally.** If asked which the headline uses, the answer is this one.

`user_type` exists but is not currently used on the dashboard. Splitting the median by New versus Returning is the cheapest extra cut available and is one filter control away.

---

## 3 · duration_bands

**One row per elapsed-time band, seven rows.**

```sql
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
```

**Line by line**

- The CTE selects **only** `minutes`. It does not need the day or the user id in the output, only in the `GROUP BY`, because the result is aggregated into bands afterwards.
- `BETWEEN DATE '2020-11-01' AND DATE '2021-01-31'` — unlike queries 1 and 2, the window is **hardcoded**. Deliberate: this chart shows the shape of the whole quarter, so it should not change when someone drags the date control.
- `GROUP BY event_date, user_pseudo_id` — one row per person per day. Grouping on the raw `event_date` rather than the parsed one is fine, since both identify the same day.
- `HAVING minutes IS NOT NULL` — **`HAVING`, not `WHERE`.** `HAVING` filters *after* grouping, which is what lets it test an aggregate. `minutes` does not exist yet at the point `WHERE` runs, so a `WHERE` could not do this.
- The `CASE` block — buckets each buyer into a band. `CASE` stops at the first match, so the conditions need no lower bounds: anything reaching `< 15` has already failed `< 5`.
- `COUNT(*) AS buyers` — how many buyers in this band.
- `pct_of_buyers` — share of all buyers. See Patterns for `SUM(COUNT(*)) OVER ()`.
- `pct_of_minutes` — the same pattern applied to **time** instead of people: this band's total minutes over all minutes.

**Worth knowing**

Putting those last two columns side by side is the entire point of the chart. A band holding 5% of the buyers but 49% of the minutes is the finding.

`minutes` here is **elapsed** time, including any period the person was away from the site. So the 6h+ band is mostly people who visited in the morning and returned in the afternoon, not six hours of shopping. That is exactly the limitation this chart demonstrates, and it is why query 6 uses a different, idle-stripped measure for the order value analysis. **The band labels look the same on page 2 and page 3, but they are not measuring the same thing.**

---

## 4 · funnel_stages

**One row per day per funnel stage.**

```sql
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
```

**Line by line**

- `COUNT(DISTINCT user_pseudo_id) AS arrived` — distinct people active that day. `DISTINCT` matters: without it this counts events, and someone who loaded twenty pages would count twenty times.
- `COUNT(DISTINCT IF(event_name = 'view_item', user_pseudo_id, NULL))` — the conditional-count pattern. The `IF` returns the user id only on matching rows and `NULL` elsewhere, and `COUNT(DISTINCT ...)` ignores nulls. So this counts distinct people who reached that stage, in the same pass as every other stage. One scan of the table instead of five.
- The three following lines repeat that for cart, checkout and purchase.
- `GROUP BY day` — one row per day with five counts across it. No date filter, so the Looker control drives the window.
- `UNPIVOT(...)` — see Patterns. Five columns become five rows so a funnel chart can plot stage as a dimension.

**Worth knowing**

Counts are distinct users **per day**, and Looker then sums across days. So a person active on five days contributes five to "Arrived". **The 242,200 figure is 242,200 user-days, not 242,200 unique people.** That is consistent with how the duration metric is defined, so the funnel and the duration analysis share a unit. But if anyone asks how many real visitors there were, the honest answer is that this query does not say.

The stages are counted **independently**. Someone who added to cart without ever firing `view_item` still counts in stage 3. So this is five separate headcounts drawn as a funnel, not a strictly tracked path. In practice the shape is the same, but the "retained %" between two bars is a ratio of two populations rather than a followed cohort.

Because `add_to_cart` was not recorded for 18 days in November, stage 3 is zero on those days. That is what the outage chart at the top of page 3 shows, and why the funnel is read from 26 November onward.

---

## 5 · funnel_timing

**Four rows, one per leg of the journey.**

```sql
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
```

**Line by line**

- `MIN(event_timestamp) AS t_first` — when they arrived.
- The four conditional `MIN`s — the first time each milestone happened that day. Five timestamps per person per day, found in one pass.
- `BETWEEN GREATEST(DATE '2020-11-26', DATE '2020-11-01') AND ...` — `GREATEST` returns the later of two dates, so this floor is 26 November. The 1 Nov is the analysis window start; the 26 Nov is the day add-to-cart tracking returned. Wrapping them in `GREATEST` means the outage can never leak in even if the window start moves earlier. As written both are constants so it simply evaluates to 26 Nov; the construction exists so the second date can be swapped for a Looker parameter without losing the guard.
- The four-part `HAVING` — **important.** Keeps only user-days where **all four milestones fired**. It has to: you cannot measure the time between two steps for someone who never reached the second. But it means this population is much smaller than the funnel population, and these percentages describe people who completed the whole journey in one day.
- `GREATEST(t_view - t_first, 0) / 60e6 AS leg1` — the gap between consecutive milestones, in minutes. `GREATEST(x, 0)` clamps negatives to zero, which are possible when events arrive out of order or someone adds to cart without ever firing `view_item`. Without the clamp, one broken journey could drag an average down.
- `(t_purchase - t_first) / 60e6 AS total` — the whole journey, deliberately **not** clamped, so a broken one stays visible and gets filtered next.
- `WHERE total > 0 AND ABS(leg1 + leg2 + leg3 + leg4 - total) < 0.02` — **a consistency check, and the smartest line in the set.** If the four legs do not add up to the total within 0.02 of a minute, about one second, the journey is out of order and its legs are meaningless. Those rows are dropped rather than silently distorting the averages.
- `'Average buyer journey' AS journey` — a constant label, so Looker has something to group the four bars under.
- `ROUND(100 * AVG(leg / total), 1) AS pct_of_journey` — **the key metric, and note what it is.** It averages each buyer's **own** percentage rather than dividing total leg minutes by total journey minutes.

  | | effect |
  |---|---|
  | `AVG(leg / total)` | every buyer counts equally, whatever their speed |
  | `SUM(leg) / SUM(total)` | the slowest buyers would dominate |

  The first is the right choice, because the question is where a typical journey's time goes, not where the aggregate clock goes. Had it been the second, the slow tail would swamp the answer.
- `median_minutes` — the median length of this leg in real minutes, as a sanity check alongside the percentage.
- `COUNT(*) AS buyers` — how many complete journeys this rests on. Much smaller than 4,794, because of the four-milestone `HAVING`.
- `UNPIVOT(...)` — four columns become four rows.

**Worth knowing**

The 46.55% on the dashboard is the average share of a buyer's journey spent between adding to cart and starting checkout, among people who completed all four steps in one day.

It is **not** arithmetically related to the 48.6% drop-off at that step, which comes from query 4 and is computed over everybody. Two different populations. The point of putting them together is that both are large at the same stage.

---

## 6 · value_by_engaged_time

**One row per engaged-time band, five rows.** The most sophisticated query in the set, and the one that most needs explaining out loud.

```sql
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
```

### The engaged-time engine

Read `active_gap_us` from the inside out:

| part | what it does |
|---|---|
| `LAG(event_timestamp) OVER (PARTITION BY user_pseudo_id, event_date ORDER BY event_timestamp)` | a window function returning the **previous** event's timestamp for the same person on the same day. `PARTITION BY` restarts the sequence for each user-day, so one person's last event never leaks into the next person's first. |
| `event_timestamp - LAG(...)` | the gap since their previous action |
| `IFNULL(..., 0)` | the first event of a day has no previous event, so `LAG` returns null. That gap is set to zero: the clock starts at their first action. |
| `LEAST(..., 30 * 60 * 1000000)` | **the key idea.** Caps every gap at 30 minutes expressed in microseconds. If someone's next click is eight hours later, they were not shopping for eight hours; they left and came back. Counting only the first 30 minutes of any gap keeps genuine browsing and discards idle time between visits. 30 minutes is the session timeout GA4 itself uses. |

Result: for every event, how much **active** time it represents.

### Line by line, rest of the query

- `purch` CTE, `MIN(ts) AS t_purchase` — their first purchase that day, the point the engaged clock stops at.
- `ARRAY_AGG(purchase_revenue_in_usd IGNORE NULLS ORDER BY ts LIMIT 1)[SAFE_OFFSET(0)]` — "give me the value attached to the **first** purchase". `ARRAY_AGG` collects values into an array, skipping nulls, sorted by time, keeping only the first; `[SAFE_OFFSET(0)]` pulls that single value back out. This is the standard BigQuery way to do "first value in a group", because `MIN` would give the *smallest* revenue rather than the *earliest*. `LIMIT 1` inside `ARRAY_AGG` also keeps it cheap: it never builds the full array.
- `SUM(IF(c.ts <= p.t_purchase, c.active_gap_us, 0)) / 60e6` — add up the capped gaps, but only for events **at or before** the purchase. The `IF` zeroes out anything after it, so browsing that happened once the order was placed does not inflate the time.
- `ANY_VALUE(p.revenue)` — revenue and items are already one value per user-day, but SQL still requires an aggregate around them inside a `GROUP BY`. `ANY_VALUE` says "pick one, they are all identical" and is cheaper than `MIN` or `MAX`.
- `JOIN purch p USING (day, user_pseudo_id)` — an inner join, so only user-days containing a purchase survive. This is what restricts the page to buyers.
- `WHERE p.revenue > 0` — **the line that explains the 4,794 versus 4,391 gap on the dashboard.** 403 purchasing user-days record zero or null revenue and are dropped here. **4,794 − 403 = 4,391**, exactly the "Orders with items" scorecard. A single clean cause.
- The `CASE` block — five bands, not seven. The long tail bands are unnecessary because capping gaps at 30 minutes has already removed most extreme values.
- `ROUND(AVG(revenue), 2) AS mean_order_value` — the $49.77 to $95.60 gradient.
- `median_order_value` — the median alongside the mean, so the gradient can be checked for skew. Not currently plotted, but it is the right robustness check to have.
- `ROUND(AVG(items), 2) AS mean_items` — the 2.26 to 6.38 basket-size climb.
- `ROUND(SUM(revenue) / SUM(items), 2) AS price_per_item` — **total revenue divided by total items**, not the average of each order's price per item. The two differ. This version answers "what does a dollar in this band buy", which is the right question for the chart, and it is why the columns multiply back to the order values so cleanly.

---

## Two things worth saying out loud

### 1 · Page 2 measures engaged time. Pages 1 and 3 measure elapsed time.

Same band labels, different meaning. Capping each gap at 30 minutes drops the mean from **74.7 minutes to 30.1**, while the median barely moves (**19.08**). That gap is the whole "a day is not a session" problem, solved for this page.

This makes the value finding **stronger**, not weaker. Because idle time is already stripped, the gradient cannot be explained away as people leaving a tab open. Someone in the 60 min + band really did spend an hour actively shopping.

If a reviewer notices the "60 min +" band appears on two pages with different counts, this is why.

### 2 · The buyer/order gap has one cause, and it is in the SQL

`WHERE p.revenue > 0` drops 403 purchasing user-days with no revenue recorded. 4,794 − 403 = 4,391. Not missing transaction ids, not duplicates. Page 2 therefore covers **4,391 of 4,794 buyer-days, or 91.6%**, and its absolute totals ($312,190 revenue) are floors rather than totals. The per-order averages are unaffected, because they average over the orders that were kept.
