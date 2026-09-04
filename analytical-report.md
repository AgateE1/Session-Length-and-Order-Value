# Time to First Purchase: Analytical Report

**Dataset:** `bigquery-public-data.ga4_obfuscated_sample_ecommerce` (public GA4 sample, Google Merchandise Store) · **Period:** 1 Nov 2020 – 31 Jan 2021
**Companion files:** *Time to first purchase* dashboard (Looker Studio, 3 pages); SQL queries (separate)

> **Headline:** Half of same-day buyers purchase within **19.1 minutes** of arriving, and that has not moved in three months, including through the largest demand swing in the data. It is neither a trend to explain nor an early-warning indicator. It mostly measures basket size rather than friction, so it is not a number to drive down. The losses worth attention sit elsewhere in the funnel.

> Every figure traces to a query result, a chart data label, or arithmetic on those. Statements marked ⚠ depend on the final query's implementation and should be checked against it.

---

## 1. Objective

**What the PM asked:** how long it takes a user to purchase, measured from first arrival on any given day to their first purchase that same day, and how that progresses daily.

**Definition.** For a user on a calendar day, the elapsed time between their **first recorded event of the day** (any type) and their **first `purchase` event that same day**. Users who did not purchase on a day they were active contribute nothing. This measures the interval for *converting* users, not the population's purchase latency. That distinction matters throughout §7.

**Date range.** 92 days. All 5,692 purchase events fall inside the window, so the date filter excludes nothing. Exception: the funnel (§6) starts 26 Nov 2020, because `add_to_cart` was untracked for 18 days in November.

**Unit of analysis.** The **user-day**, not the user, session, or order. A user purchasing on three days contributes three observations, so the population of **4,794** is 4,794 user-days, not 4,794 people.

---

## 2. Data & methodology

**The table.** A flattened GA4 event export; each row is one event fired by one user at one timestamp. There is no sessions, orders, or users table, so every construct below is derived from the event stream.

**Event types.** Arrival uses *any* event; `view_item`, `add_to_cart`, `begin_checkout` and `purchase` form the funnel, with `purchase` also the duration endpoint. Arrival deliberately uses any event rather than `session_start`, because the PM asked about "first arriving on the website" and the earliest event of any type is the closest proxy.

**Identifying users.** `user_pseudo_id`, the GA4 client identifier: device- and browser-scoped, cookie-based, not a logged-in account ID. One person on two devices is two users. Acceptable for a single-day metric; a hard ceiling on any multi-day extension.

**First arrival and first purchase.** Both are minimum timestamps within a user-day group: `MIN(event_timestamp)` across all events, and across `purchase` events respectively. Taking the minimum is what matches the PM's question: a user buying twice in a day contributes one duration.

**Same-day handling.** The day is `event_date`, the date GA4 itself assigned in the property's reporting timezone, rather than one derived from the raw timestamp; both endpoints must fall on it, and a user-day enters the result only if it contains a purchase. A user who browses Monday and buys Thursday is therefore absent entirely rather than recorded as a long duration, and a session crossing midnight becomes two user-days.

**Duration.** Timestamps are microseconds: `(first_purchase_ts − first_event_ts) / 60,000,000`. The value cannot be negative, since a purchase is itself an event and cannot precede the minimum.

**Why the median.** The distribution is severely right-skewed, with a **median of 19.1 minutes against a mean of 74.7**, the mean sitting above roughly 90% of observations:

| Band | Share of buyers | Share of elapsed time |
|---|---|---|
| Under 5 min | 7.8% | 0.4% |
| 5–15 min | 33.5% | 4.4% |
| 15–30 min | 23.6% | 6.8% |
| 30–60 min | 14.2% | 7.9% |
| 1–3 h | 10.9% | 15.0% |
| 3–6 h | 4.9% | 16.5% |
| 6 h + | **5.1%** | **49.1%** |

The slowest 5% hold **49.1%** of all elapsed time, the slowest 10% hold 65.6%. A mean over this describes the tail, not the typical buyer; it is kept on the dashboard labelled as skewed so the gap between the two stays visible.

**The 7-day rolling median.** Daily medians are computed first, then smoothed with a **7-day trailing window**. Smoothing is necessary because daily buyer counts range from roughly 150 in December to under 20 on quiet January days, and a median on 15 observations moves on one or two buyers.

⚠ A rolling median *of daily medians* is not the same statistic as a median over all buyers pooled across seven days: the first weights each day equally regardless of volume, the second weights each buyer equally. Quiet January days carry disproportionate weight under the first. Confirm which the query implements.

---

## 3. SQL

The full query, with commentary on the individual CTEs, is provided as a separate accompanying file.

---

## 4. Main findings

| Band | Buyers | Share | Cumulative |
|---|---|---|---|
| Under 5 min | 373 | 7.8% | 7.8% |
| 5–15 min | 1,605 | 33.5% | 41.3% |
| 15–30 min | 1,132 | 23.6% | **64.9%** |
| 30–60 min | 683 | 14.2% | 79.1% |
| 1–3 h | 524 | 10.9% | 90.1% |
| 3–6 h | 233 | 4.9% | 94.9% |
| 6 h + | 244 | 5.1% | 100.0% |
| **Total** | **4,794** | | |

**The typical purchase is fast.** 3,110 of 4,794 buyers, or **64.9%**, finish within half an hour, 41.3% within fifteen minutes. Whatever consideration happens here mostly happens inside one short visit.

**The modal band is 5–15 minutes, not the fastest.** Only 7.8% buy in under five minutes, so the common pattern is a short but non-trivial browse rather than arriving with a product already decided.

**The long tail is a measurement artefact.** The 244 buyers in the 6h+ band are not plausibly shopping for six continuous hours; far likelier they visited in the morning, left, and returned later the same day, and the intervening hours count as duration (§7.2).

### The daily progression

The answer to the PM's question is a negative one: **the metric does not move.** Across 92 days the smoothed median stays in a narrow band, drifting mildly upward into mid-December and easing back through January.

What makes this meaningful is the contrast. Conversion **peaked at 3.17% on 30 November 2020**, Black Friday / Cyber Monday week, then fell to a small fraction by mid-January; daily buyer volume peaked near 150 in mid-December and fell below 20 in January. Demand, traffic quality and conversion all moved substantially. The median time to purchase did not move with them.

1. **It is not an early-warning indicator.** It did not respond to the largest demand swing in the data, so it will not signal a change in conversion before conversion does.
2. **Day-to-day movement should not be interpreted.** With some January days resting on fewer than two dozen buyers, single-day changes are sampling noise.

⚠ The median *does* decline modestly across the same mid-December-to-January window. The defensible claim is that the two series differ greatly in amplitude, not that one is flat. Compute both ranges from `MIN`/`MAX` aggregates rather than reading them off the chart.

---

## 5. Additional analysis: order value and basket size

| Speed band | Avg order value | Items per order | Price per item |
|---|---|---|---|
| Under 5 min | $49.77 | 2.26 | $22.04 |
| 5–15 min | $57.36 | 3.69 | $15.53 |
| 15–30 min | $74.28 | 5.04 | $14.73 |
| 30–60 min | $81.66 | 5.15 | $15.87 |
| 60 min + | $95.60 | 6.38 | $14.98 |

**A note on the time measure.** Unlike §4 and §6, which use elapsed time, this analysis uses **engaged time**: the gaps between a user's consecutive events, each capped at 30 minutes, summed to the first purchase. Capping removes the idle time between visits, and drops the mean from 74.7 minutes to 30.1 while the median holds at 19.08. This matters for the interpretation below. Because idle time is already stripped, the gradient cannot be dismissed as people leaving a tab open: someone in the 60 minute band spent an hour actively shopping.

Order value rises steadily with duration, from **$49.77 to $95.60: a 1.9× spread, or $45.83 per order.** Order value is item count × item price, and decomposing it settles the question: **items per order nearly triples** (2.26 → 6.38) while **price per item stays flat** at roughly $15 across four of five bands. The columns multiply back to the order values within a few cents, so the entire gradient is basket size. **Slower buyers are not trading up to more expensive products; they are putting more of the same products in the basket.**

**The fastest band is a different behaviour, not a faster version of the same one.** Under-5-minute buyers have the **smallest basket** (2.26 items) and the **highest unit price** ($22.04, ~45% above every other band), consistent with arriving for one specific expensive item and leaving. 7.8% of buyers, worth treating separately.

### Two readings, and what would separate them

**A. Duration signals intent.** Long sessions are users browsing a category and assembling a basket; the minutes are engagement, and compressing them would remove the browsing that fills the cart.

**B. Duration is a by-product of basket size.** Six items mechanically take longer to add than two, at ~$15 either way; duration then carries nothing basket size does not carry more directly.

Both predict exactly the observed chart. **The test that would separate them:** hold items-per-order constant and re-examine. If a four-item order is still worth more at 60 minutes than at 5, something beyond mechanics operates; if the relationship disappears, duration is a proxy for basket size.

**What both agree on:** this is not a friction metric and not a number to drive down. A target to reduce it would, on A, cut the browsing that fills baskets, and on B, simply be a target to shrink baskets. It is a useful *segmentation* signal and a poor *optimisation* target.

---

## 6. Funnel analysis

Covering **26 Nov 2020 onward**, after `add_to_cart` tracking was restored:

| Step | Users | Retained | Share of elapsed time |
|---|---|---|---|
| 1 · Arrived | 242,200 | | |
| 2 · Viewed an item | 52,300 | 21.6% | 13.9% |
| 3 · Added to cart | 13,800 | 26.4% | 12.1% |
| 4 · Began checkout | 7,100 | **51.4%** | **46.6%** |
| 5 · Purchased | 3,600 | 50.7% | 27.5% |
| **End to end** | | **1.49%** | |

**The largest loss is before the funnel really starts.** 189,900 of 242,200 visitors, or **78.4%**, leave without viewing a single product. In absolute terms this dwarfs every other step combined, and no checkout optimisation addresses it; it is a traffic-quality and landing-experience question deserving its own investigation.

**Why add-to-cart → checkout deserves investigation.** That stage consumes **46.6% of total journey time and loses 48.6% of the users who reach it**, the only stage where a large time cost and a large drop-off coincide. At arrive → item view, users leave quickly without engaging and time is not the obstacle. Here they have demonstrated intent by putting something in a basket, then spend the largest block of time in the journey, and half still do not proceed.

Everywhere else in this analysis, reducing time risks removing the browsing that fills baskets (§5). This stage is the exception: the basket is already assembled, so the time is unlikely to be adding items. Hesitation, friction, or a mechanical obstacle are all far likelier. **It is the one place where reducing elapsed time plausibly gains conversions rather than costing basket value.** What the obstacle actually is, whether late-revealed shipping cost, forced account creation, or a slow cart page, needs instrumentation this dataset lacks (§8.4).

---

## 7. Limitations

Two of these constrain how the headline figure may be quoted. The rest are noted for completeness rather than as caveats on the conclusion.

**7.1 The metric is same-day by construction.** It covers only users who arrived and purchased on the same calendar day, because that is what was asked. **"19 minutes" is therefore the median for same-day converters, not the time it takes a customer to decide to buy**. The qualifier should travel with the number wherever it is quoted.

**7.2 A day is not a session.** Measurement runs from the first event of the calendar day, so a user who visits at 09:00 and returns to buy at 17:00 records an eight-hour purchase. This explains the long tail, in which 5.1% of buyers hold 49.1% of all elapsed time, and it is why the mean reads 74.7 against a median of 19.1. Those durations are largely gaps between visits, so the slow bands should not be read as "high-consideration" buyers.

**Also noted:**

- **Buyer/order gap, investigated and closed.** Page 2 excludes 403 buyer-days because their purchase records no revenue (`WHERE revenue > 0` in the value query). 4,794 − 403 = 4,391, the exact figure on the page. Tested for bias: the excluded group's median is 20.2 minutes against 18.9 for the group kept, a difference of 1.3 minutes on a sample of 398 where the standard error of that median is 1.6 (p = 0.43, 95% CI −2.0 to +4.6). The median and the mean also move in opposite directions across the two groups, which is the signature of noise rather than a systematic difference. So §5 rests on 91.6% of buyer-days and is unbiased, though its absolute totals ($312,190 revenue) are floors rather than totals.
- **Holiday quarter.** Nov–Jan covers Black Friday and Christmas, and gift-buying produces large multi-item baskets, which bears directly on Reading B in §5. No baseline set here will hold in March.
- **No segmentation.** Nothing is split by device, source, or new vs returning; 8 minutes on desktop and 40 on mobile would produce a similar pooled median.
- **UTC day boundaries** split late-evening sessions, biasing duration slightly downward for users in western time zones. ⚠ Confirm whether the query converts.
- **Add-to-cart untracked for 18 days in November**, so the funnel starts 26 Nov and excludes the Black Friday peak.

---

## 8. Recommendations

**8.1 Do not set a target on time to first purchase.** It is stable, it did not respond to the largest demand swing in the data, and §5 shows it is largely a function of basket size. Under either reading there, driving it down means shrinking baskets. It belongs in segmentation, not on a KPI dashboard.

**8.2 Do not treat slow buyers as a problem to fix.** They carry the largest baskets and the highest order values, $95.60 against $49.77 for the fastest band. Any initiative to accelerate them risks the revenue it is meant to protect.

**8.3 Use time to first add-to-cart if a friction metric is wanted.** It ends before basket assembly begins, so it tracks decision speed rather than shopping volume, and unlike time to purchase it can legitimately be optimised downward.

**8.4 Prioritise the cart to checkout stage.** It consumes 46.6% of journey time and loses 48.6% of the users who reach it, the only stage where both are true, and the one place where reducing elapsed time plausibly gains conversions rather than costing basket value. It needs instrumentation before a fix can be specified: cart views, shipping estimates, promo attempts, account prompts, error states.

**8.5 Treat the pre-product-page loss as a separate and larger workstream.** 189,900 of 242,200 visitors leave without viewing a single product. In absolute terms it dwarfs everything downstream, and no checkout work touches it. This is a traffic-quality and landing-experience problem, not a purchase-journey one.

**8.6 Fix the missing transaction ids.** 883 purchase events record `(not set)`, so 16.6% of buyer-days produce no order record at all. It does not affect the conclusions here, and the dashboard's per-order figures ($71.10 average order value, 4.57 items) are unaffected because they are averages over the orders that were tracked. The totals are not: **$312,190 revenue and 4,391 orders are floors, not totals**, and they would rise by up to a sixth once the gap is closed, depending on whether untracked purchases carry similar value. Any transaction-level work inherits the same loss.

**8.7 Do not baseline from this quarter.** November to January contains Black Friday and Christmas. Every figure in this report describes a holiday period and will not hold in March.
