-- =====================================================================
-- Netflix Customer Intelligence & AI Analytics Copilot
-- 37 SQL business questions  |  MySQL 8.0  |  database: netflix_ci
--
-- Conventions used in every query
--   * "Current plan" of a customer = their subscription row whose status is
--     NOT 'Plan Changed' (every customer has exactly one such row).
--   * "As-of" date = end of the dataset (viewing/tickets/churn end 2026-06-30,
--     payments end 2026-05-31). Never CURDATE(): the data is a fixed snapshot.
--   * Revenue uses payments.amount_clean (anomalous amounts replaced by the
--     plan price during cleaning) and payment_status = 'Success'.
--
-- Run all queries:  python database/run_queries.py        (or paste into Workbench)
-- Each query starts with a "-- Qnn" marker line; run_queries.py relies on it.
-- =====================================================================


-- =====================================================================
-- SECTION A - INTERMEDIATE (Q01-Q15)
-- =====================================================================

-- Q01  Active customers by country
-- Active = the customer's current subscription has status 'Active'.
SELECT c.country,
       COUNT(DISTINCT c.customer_id) AS active_customers
FROM customers c
JOIN subscriptions s ON s.customer_id = c.customer_id
WHERE s.subscription_status = 'Active'
GROUP BY c.country
ORDER BY active_customers DESC, c.country;


-- Q02  Total and average monthly revenue per subscription plan
-- Average monthly revenue = average of the plan's month-by-month totals.
WITH monthly AS (
    SELECT sp.plan_name,
           DATE_FORMAT(p.payment_date, '%Y-%m') AS payment_month,
           SUM(p.amount_clean)                  AS month_revenue
    FROM payments p
    JOIN subscriptions s       ON s.subscription_id = p.subscription_id
    JOIN subscription_plans sp ON sp.plan_id = s.plan_id
    WHERE p.payment_status = 'Success'
    GROUP BY sp.plan_name, DATE_FORMAT(p.payment_date, '%Y-%m')
)
SELECT plan_name,
       ROUND(SUM(month_revenue), 2) AS total_revenue,
       ROUND(AVG(month_revenue), 2) AS avg_monthly_revenue,
       COUNT(*)                     AS months_with_revenue
FROM monthly
GROUP BY plan_name
ORDER BY total_revenue DESC, plan_name;


-- Q03  Overall churn rate
SELECT COUNT(*)                         AS total_customers,
       SUM(churned)                     AS churned_customers,
       ROUND(100 * AVG(churned), 2)     AS churn_rate_pct
FROM churn_labels;


-- Q04  Customers and churn rate per acquisition channel
SELECT c.acquisition_channel,
       COUNT(*)                         AS customers,
       SUM(cl.churned)                  AS churned,
       ROUND(100 * AVG(cl.churned), 2)  AS churn_rate_pct
FROM customers c
JOIN churn_labels cl ON cl.customer_id = c.customer_id
GROUP BY c.acquisition_channel
ORDER BY customers DESC, c.acquisition_channel;


-- Q05  Average customer age by (current) subscription plan
-- Customers whose age was imputed are excluded so the average uses real ages only.
SELECT sp.plan_name,
       ROUND(AVG(c.age), 1) AS avg_age,
       COUNT(*)             AS customers_with_known_age
FROM customers c
JOIN subscriptions s       ON s.customer_id = c.customer_id
                          AND s.subscription_status <> 'Plan Changed'
JOIN subscription_plans sp ON sp.plan_id = s.plan_id
WHERE c.age_imputed = 0
GROUP BY sp.plan_name
ORDER BY avg_age DESC, sp.plan_name;


-- Q06  Top 10 most-watched titles by total watch minutes
SELECT ct.content_id,
       ct.title,
       ct.content_type,
       ct.genre,
       SUM(v.watch_duration_minutes) AS total_watch_minutes,
       COUNT(*)                      AS sessions
FROM viewing_activity v
JOIN content ct ON ct.content_id = v.content_id
GROUP BY ct.content_id, ct.title, ct.content_type, ct.genre
ORDER BY total_watch_minutes DESC, ct.title
LIMIT 10;


-- Q07  Average completion % by content type and genre
-- Rows whose completion was imputed during cleaning are excluded.
SELECT ct.content_type,
       ct.genre,
       ROUND(AVG(v.completion_percentage), 2) AS avg_completion_pct,
       COUNT(*)                               AS sessions
FROM viewing_activity v
JOIN content ct ON ct.content_id = v.content_id
WHERE v.completion_imputed = 0
GROUP BY ct.content_type, ct.genre
ORDER BY ct.content_type, avg_completion_pct DESC, ct.genre;


-- Q08  Failed payments in each of the last 12 months (anchored to the last payment month)
SELECT DATE_FORMAT(payment_date, '%Y-%m') AS payment_month,
       COUNT(*)                           AS failed_payments
FROM payments
WHERE payment_status = 'Failed'
  AND payment_date >= DATE_SUB(DATE_FORMAT((SELECT MAX(payment_date) FROM payments), '%Y-%m-01'),
                               INTERVAL 11 MONTH)
GROUP BY DATE_FORMAT(payment_date, '%Y-%m')
ORDER BY payment_month;


-- Q09  Average resolution time (hours) by issue category
-- Open tickets (Pending / Escalated) have no resolution time and are ignored by AVG.
SELECT issue_category,
       ROUND(AVG(resolution_time_hours), 1) AS avg_resolution_hours,
       COUNT(resolution_time_hours)         AS resolved_tickets
FROM support_tickets
GROUP BY issue_category
ORDER BY avg_resolution_hours DESC, issue_category;


-- Q10  Distribution of CSAT score across Resolved / Closed tickets
SELECT customer_satisfaction_score,
       COUNT(*)                                          AS tickets,
       ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)  AS pct_of_tickets
FROM support_tickets
WHERE ticket_status IN ('Resolved', 'Closed')
GROUP BY customer_satisfaction_score
ORDER BY customer_satisfaction_score;


-- Q11  Device type generating the most total viewing minutes
SELECT device_type,
       SUM(watch_duration_minutes) AS total_watch_minutes,
       ROUND(100 * SUM(watch_duration_minutes) / SUM(SUM(watch_duration_minutes)) OVER (), 2) AS pct_of_minutes
FROM viewing_activity
GROUP BY device_type
ORDER BY total_watch_minutes DESC, device_type;


-- Q12  Average rating by sentiment label (label as supplied in the data)
SELECT sentiment_label,
       ROUND(AVG(rating), 2) AS avg_rating,
       COUNT(*)              AS reviews
FROM customer_feedback
GROUP BY sentiment_label
ORDER BY avg_rating DESC, sentiment_label;


-- Q12b Same question using the corrected label (the supplied label is ~5% mislabeled)
SELECT sentiment_corrected,
       ROUND(AVG(rating), 2) AS avg_rating,
       COUNT(*)              AS reviews
FROM customer_feedback
GROUP BY sentiment_corrected
ORDER BY avg_rating DESC, sentiment_corrected;


-- Q13  New customers per acquisition channel per calendar year
SELECT YEAR(registration_date) AS signup_year,
       acquisition_channel,
       COUNT(*)                AS customers
FROM customers
GROUP BY YEAR(registration_date), acquisition_channel
ORDER BY signup_year, customers DESC, acquisition_channel;


-- Q14  Percentage of customers with auto-renew turned off (current subscription)
SELECT COUNT(*)                                                  AS customers,
       SUM(s.auto_renew = 0)                                     AS auto_renew_off,
       ROUND(100 * AVG(s.auto_renew = 0), 2)                     AS pct_auto_renew_off_all,
       ROUND(100 * AVG(CASE WHEN s.subscription_status = 'Active'
                            THEN (s.auto_renew = 0) END), 2)     AS pct_auto_renew_off_active_only
FROM subscriptions s
WHERE s.subscription_status <> 'Plan Changed';


-- Q15  Customers with more than 3 support tickets
SELECT t.customer_id,
       COUNT(*) AS ticket_count
FROM support_tickets t
GROUP BY t.customer_id
HAVING COUNT(*) > 3
ORDER BY ticket_count DESC, t.customer_id;


-- =====================================================================
-- SECTION B - ADVANCED (Q16-Q27)   CTEs, window functions, cohorts
-- =====================================================================

-- Q16  Rank plans by monthly recurring revenue (monthly_price x active subscriptions)
WITH plan_mrr AS (
    SELECT sp.plan_name,
           sp.monthly_price,
           COUNT(*)                          AS active_subscriptions,
           ROUND(sp.monthly_price * COUNT(*), 2) AS monthly_revenue
    FROM subscriptions s
    JOIN subscription_plans sp ON sp.plan_id = s.plan_id
    WHERE s.subscription_status = 'Active'
    GROUP BY sp.plan_name, sp.monthly_price
)
SELECT plan_name,
       monthly_price,
       active_subscriptions,
       monthly_revenue,
       RANK() OVER (ORDER BY monthly_revenue DESC) AS revenue_rank
FROM plan_mrr
ORDER BY revenue_rank;


-- Q17  Most recent support ticket per customer (ROW_NUMBER)
-- Tickets with an invalid (NULL) date sort last, so a dated ticket always wins.
WITH ranked AS (
    SELECT t.*,
           ROW_NUMBER() OVER (PARTITION BY t.customer_id
                              ORDER BY t.ticket_date DESC, t.ticket_id DESC) AS rn
    FROM support_tickets t
)
SELECT customer_id, ticket_id, ticket_date, issue_category, issue_subcategory,
       priority, ticket_status, customer_satisfaction_score
FROM ranked
WHERE rn = 1
ORDER BY customer_id;


-- Q18  3-month moving average of new customer registrations
WITH monthly AS (
    SELECT DATE_FORMAT(registration_date, '%Y-%m') AS signup_month,
           COUNT(*)                                AS new_customers
    FROM customers
    GROUP BY DATE_FORMAT(registration_date, '%Y-%m')
)
SELECT signup_month,
       new_customers,
       ROUND(AVG(new_customers) OVER (ORDER BY signup_month
                                      ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 2) AS moving_avg_3m,
       COUNT(*) OVER (ORDER BY signup_month
                      ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)                      AS months_in_window
FROM monthly
ORDER BY signup_month;


-- Q19  Month-over-month watch-time decline in the most recent month (LAG)
-- A customer/month grid is built first so a month with no viewing counts as 0 minutes.
WITH months AS (
    SELECT DISTINCT DATE_FORMAT(viewing_date, '%Y-%m') AS ym FROM viewing_activity
),
viewers AS (
    SELECT DISTINCT customer_id FROM viewing_activity
),
monthly AS (
    SELECT customer_id,
           DATE_FORMAT(viewing_date, '%Y-%m') AS ym,
           SUM(watch_duration_minutes)        AS watch_min
    FROM viewing_activity
    GROUP BY customer_id, DATE_FORMAT(viewing_date, '%Y-%m')
),
grid AS (
    SELECT v.customer_id, m.ym, COALESCE(mo.watch_min, 0) AS watch_min
    FROM viewers v
    CROSS JOIN months m
    LEFT JOIN monthly mo ON mo.customer_id = v.customer_id AND mo.ym = m.ym
),
lagged AS (
    SELECT customer_id, ym, watch_min,
           LAG(watch_min) OVER (PARTITION BY customer_id ORDER BY ym) AS prev_watch_min
    FROM grid
)
SELECT customer_id,
       ym                AS latest_month,
       prev_watch_min,
       watch_min         AS latest_watch_min,
       ROUND(100 * (watch_min - prev_watch_min) / prev_watch_min, 1) AS pct_change
FROM lagged
WHERE ym = (SELECT MAX(ym) FROM months)
  AND prev_watch_min > 0
  AND watch_min < prev_watch_min
ORDER BY pct_change, customer_id;


-- Q20  Registration-cohort retention at 1, 3 and 6 months
-- Active at N months = not churned within N months of registering.
-- A cohort is only measured at N months if every member has had N months to churn
-- (registered at least N months before the end of the data); otherwise NULL.
WITH ref_date AS (
    SELECT MAX(viewing_date) AS as_of FROM viewing_activity
),
cust AS (
    SELECT DATE_FORMAT(c.registration_date, '%Y-%m') AS cohort_month,
           (DATE_ADD(c.registration_date, INTERVAL 1 MONTH) <= r.as_of) AS obs_1,
           (DATE_ADD(c.registration_date, INTERVAL 3 MONTH) <= r.as_of) AS obs_3,
           (DATE_ADD(c.registration_date, INTERVAL 6 MONTH) <= r.as_of) AS obs_6,
           (cl.churn_date IS NULL OR cl.churn_date > DATE_ADD(c.registration_date, INTERVAL 1 MONTH)) AS act_1,
           (cl.churn_date IS NULL OR cl.churn_date > DATE_ADD(c.registration_date, INTERVAL 3 MONTH)) AS act_3,
           (cl.churn_date IS NULL OR cl.churn_date > DATE_ADD(c.registration_date, INTERVAL 6 MONTH)) AS act_6
    FROM customers c
    JOIN churn_labels cl ON cl.customer_id = c.customer_id
    CROSS JOIN ref_date r
)
SELECT cohort_month,
       COUNT(*) AS cohort_size,
       ROUND(100 * SUM(obs_1 AND act_1) / NULLIF(SUM(obs_1), 0), 2) AS retained_1m_pct,
       ROUND(100 * SUM(obs_3 AND act_3) / NULLIF(SUM(obs_3), 0), 2) AS retained_3m_pct,
       ROUND(100 * SUM(obs_6 AND act_6) / NULLIF(SUM(obs_6), 0), 2) AS retained_6m_pct
FROM cust
GROUP BY cohort_month
ORDER BY cohort_month;


-- Q21  Top 5 countries by churn rate (DENSE_RANK)
WITH country_churn AS (
    SELECT c.country,
           COUNT(*)                   AS customers,
           SUM(cl.churned)            AS churned,
           100 * AVG(cl.churned)      AS churn_rate
    FROM customers c
    JOIN churn_labels cl ON cl.customer_id = c.customer_id
    GROUP BY c.country
),
ranked AS (
    SELECT country, customers, churned, churn_rate,
           DENSE_RANK() OVER (ORDER BY churn_rate DESC) AS churn_rank
    FROM country_churn
)
SELECT churn_rank, country, customers, churned, ROUND(churn_rate, 2) AS churn_rate_pct
FROM ranked
WHERE churn_rank <= 5
ORDER BY churn_rank, country;


-- Q22  Running total of successful payments per customer
SELECT customer_id,
       payment_id,
       payment_date,
       amount_clean AS amount,
       ROUND(SUM(amount_clean) OVER (PARTITION BY customer_id
                                     ORDER BY payment_date, payment_id
                                     ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW), 2) AS running_total
FROM payments
WHERE payment_status = 'Success'
ORDER BY customer_id, payment_date, payment_id;


-- Q23  Customers whose monthly watch time fell three months in a row (N < N-1 < N-2)
WITH months AS (
    SELECT DISTINCT DATE_FORMAT(viewing_date, '%Y-%m') AS ym FROM viewing_activity
),
viewers AS (
    SELECT DISTINCT customer_id FROM viewing_activity
),
monthly AS (
    SELECT customer_id,
           DATE_FORMAT(viewing_date, '%Y-%m') AS ym,
           SUM(watch_duration_minutes)        AS watch_min
    FROM viewing_activity
    GROUP BY customer_id, DATE_FORMAT(viewing_date, '%Y-%m')
),
grid AS (
    SELECT v.customer_id, m.ym, COALESCE(mo.watch_min, 0) AS watch_min
    FROM viewers v
    CROSS JOIN months m
    LEFT JOIN monthly mo ON mo.customer_id = v.customer_id AND mo.ym = m.ym
),
lagged AS (
    SELECT customer_id, ym, watch_min,
           LAG(watch_min, 1) OVER (PARTITION BY customer_id ORDER BY ym) AS m1,
           LAG(watch_min, 2) OVER (PARTITION BY customer_id ORDER BY ym) AS m2
    FROM grid
),
declines AS (
    SELECT customer_id, ym, m2, m1, watch_min,
           ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY ym DESC) AS rn,
           COUNT(*)     OVER (PARTITION BY customer_id)                  AS declining_windows
    FROM lagged
    WHERE m2 IS NOT NULL AND watch_min < m1 AND m1 < m2
)
SELECT customer_id,
       ym        AS latest_decline_ends,
       m2        AS watch_two_months_before,
       m1        AS watch_prior_month,
       watch_min AS watch_that_month,
       declining_windows
FROM declines
WHERE rn = 1
ORDER BY declining_windows DESC, customer_id;


-- Q24  Monthly churn rate, last 12 months
-- churn rate = customers who churned in the month / customers active at the start of it.
-- Only customers registered before the month started are counted (in both numerator and denominator).
WITH RECURSIVE ref_date AS (
    SELECT CAST(DATE_FORMAT(MAX(viewing_date), '%Y-%m-01') AS DATE) AS last_month
    FROM viewing_activity
),
months AS (
    SELECT CAST(DATE_SUB(last_month, INTERVAL 11 MONTH) AS DATE) AS month_start
    FROM ref_date
    UNION ALL
    SELECT CAST(DATE_ADD(month_start, INTERVAL 1 MONTH) AS DATE)
    FROM months
    WHERE month_start < (SELECT last_month FROM ref_date)
),
base AS (
    SELECT m.month_start,
           SUM(c.registration_date < m.month_start
               AND (cl.churn_date IS NULL OR cl.churn_date >= m.month_start)) AS active_at_start,
           SUM(c.registration_date < m.month_start
               AND cl.churned = 1
               AND cl.churn_date >= m.month_start
               AND cl.churn_date <  DATE_ADD(m.month_start, INTERVAL 1 MONTH)) AS churned_in_month
    FROM months m
    CROSS JOIN customers c
    JOIN churn_labels cl ON cl.customer_id = c.customer_id
    GROUP BY m.month_start
)
SELECT DATE_FORMAT(month_start, '%Y-%m') AS churn_month,
       active_at_start,
       churned_in_month,
       ROUND(100 * churned_in_month / NULLIF(active_at_start, 0), 2) AS churn_rate_pct
FROM base
ORDER BY month_start;


-- Q25  Retention rate by acquisition channel (still active today)
SELECT c.acquisition_channel,
       COUNT(*)                                   AS customers_acquired,
       SUM(cl.churned = 0)                        AS still_active,
       ROUND(100 * AVG(cl.churned = 0), 2)        AS retention_rate_pct,
       RANK() OVER (ORDER BY AVG(cl.churned = 0) DESC) AS retention_rank
FROM customers c
JOIN churn_labels cl ON cl.customer_id = c.customer_id
GROUP BY c.acquisition_channel
ORDER BY retention_rank;


-- Q26  Lifetime spend per customer and spend quartile (NTILE; quartile 1 = highest spenders)
WITH spend AS (
    SELECT c.customer_id,
           COALESCE(SUM(p.amount_clean), 0) AS lifetime_spend
    FROM customers c
    LEFT JOIN payments p ON p.customer_id = c.customer_id AND p.payment_status = 'Success'
    GROUP BY c.customer_id
)
SELECT customer_id,
       ROUND(lifetime_spend, 2) AS lifetime_spend,
       NTILE(4) OVER (ORDER BY lifetime_spend DESC, customer_id) AS spend_quartile
FROM spend
ORDER BY spend_quartile, lifetime_spend DESC, customer_id;


-- Q26b Quartile summary: how concentrated is revenue?
WITH spend AS (
    SELECT c.customer_id,
           COALESCE(SUM(p.amount_clean), 0) AS lifetime_spend
    FROM customers c
    LEFT JOIN payments p ON p.customer_id = c.customer_id AND p.payment_status = 'Success'
    GROUP BY c.customer_id
),
q AS (
    SELECT customer_id, lifetime_spend,
           NTILE(4) OVER (ORDER BY lifetime_spend DESC, customer_id) AS spend_quartile
    FROM spend
)
SELECT spend_quartile,
       COUNT(*)                                   AS customers,
       ROUND(MIN(lifetime_spend), 2)              AS min_spend,
       ROUND(MAX(lifetime_spend), 2)              AS max_spend,
       ROUND(AVG(lifetime_spend), 2)              AS avg_spend,
       ROUND(100 * SUM(lifetime_spend) / SUM(SUM(lifetime_spend)) OVER (), 2) AS pct_of_total_spend
FROM q
GROUP BY spend_quartile
ORDER BY spend_quartile;


-- Q27  Top 3 issue subcategories by ticket volume, per country
WITH subcat AS (
    SELECT c.country,
           t.issue_subcategory,
           COUNT(*) AS tickets
    FROM support_tickets t
    JOIN customers c ON c.customer_id = t.customer_id
    GROUP BY c.country, t.issue_subcategory
),
ranked AS (
    SELECT country, issue_subcategory, tickets,
           ROW_NUMBER() OVER (PARTITION BY country
                              ORDER BY tickets DESC, issue_subcategory) AS rn
    FROM subcat
)
SELECT country, rn AS subcategory_rank, issue_subcategory, tickets
FROM ranked
WHERE rn <= 3
ORDER BY country, rn;


-- =====================================================================
-- SECTION C - EXPERT (Q28-Q37)   multi-CTE pipelines, business scoring
-- =====================================================================
-- Shared definitions for Q28, Q31 and Q37 (all use CURRENTLY ACTIVE customers):
--   days_since_last_activity = as-of date minus last viewing date (as-of = last viewing date in
--                              the data; customers with no viewing at all are treated as 1 day
--                              before the data starts, i.e. the maximum)
--   failed_payment_rate      = failed payments / all payment attempts, whole history
--   support_ticket_count     = all tickets ever raised
-- Each component is min-max normalised to 0-1 across active customers (1 = worst).
-- Components are cast to DOUBLE: MySQL keeps only 4 decimals when dividing integers/decimals.
-- NOTE on price changes (Q29, Q34): in this dataset every payment is charged at the customer's
-- CURRENT plan price and subscriptions.monthly_price never changes, so a "price change" is
-- detected as a plan change between plans whose catalog price (subscription_plans) differs.
-- The "high churn risk" flag in Q28 is a rule-based proxy (top quartile of the Q31 score);
-- in Week 2 it can be replaced with the trained model's churn probability.


-- Q28  Active customers with 2+ failed payments in the last 90 days AND high churn risk
-- 90 days is measured back from the last payment date in the data. High risk = top quartile
-- of the composite risk score (see Q31).
WITH ref_date AS (
    SELECT MAX(viewing_date) AS as_of, MIN(viewing_date) AS first_day FROM viewing_activity
),
active AS (
    SELECT s.customer_id, sp.plan_name
    FROM subscriptions s
    JOIN subscription_plans sp ON sp.plan_id = s.plan_id
    WHERE s.subscription_status = 'Active'
),
last_view AS (
    SELECT customer_id, MAX(viewing_date) AS last_view_date FROM viewing_activity GROUP BY customer_id
),
pay AS (
    SELECT customer_id, COUNT(*) AS payments, SUM(payment_status = 'Failed') AS failed
    FROM payments GROUP BY customer_id
),
tix AS (
    SELECT customer_id, COUNT(*) AS support_ticket_count FROM support_tickets GROUP BY customer_id
),
feat AS (
    SELECT a.customer_id, a.plan_name,
           CAST(DATEDIFF(r.as_of, COALESCE(lv.last_view_date, DATE_SUB(r.first_day, INTERVAL 1 DAY))) AS DOUBLE) AS days_since_last_activity,
           COALESCE(CAST(p.failed AS DOUBLE) / NULLIF(p.payments, 0), 0) AS failed_payment_rate,
           CAST(COALESCE(t.support_ticket_count, 0) AS DOUBLE) AS support_ticket_count
    FROM active a
    CROSS JOIN ref_date r
    LEFT JOIN last_view lv ON lv.customer_id = a.customer_id
    LEFT JOIN pay p        ON p.customer_id  = a.customer_id
    LEFT JOIN tix t        ON t.customer_id  = a.customer_id
),
scored AS (
    SELECT customer_id, plan_name,
           (COALESCE((days_since_last_activity - MIN(days_since_last_activity) OVER ())
                     / NULLIF(MAX(days_since_last_activity) OVER () - MIN(days_since_last_activity) OVER (), 0), 0)
          + COALESCE((failed_payment_rate - MIN(failed_payment_rate) OVER ())
                     / NULLIF(MAX(failed_payment_rate) OVER () - MIN(failed_payment_rate) OVER (), 0), 0)
          + COALESCE((support_ticket_count - MIN(support_ticket_count) OVER ())
                     / NULLIF(MAX(support_ticket_count) OVER () - MIN(support_ticket_count) OVER (), 0), 0)) / 3 AS risk_score
    FROM feat
),
risk AS (
    SELECT customer_id, plan_name, risk_score,
           NTILE(4) OVER (ORDER BY risk_score DESC, customer_id) AS risk_quartile
    FROM scored
),
recent_fails AS (
    SELECT p.customer_id, COUNT(*) AS failed_payment_count
    FROM payments p
    CROSS JOIN (SELECT MAX(payment_date) AS last_pay FROM payments) lp
    WHERE p.payment_status = 'Failed'
      AND p.payment_date > DATE_SUB(lp.last_pay, INTERVAL 90 DAY)
    GROUP BY p.customer_id
    HAVING COUNT(*) >= 2
)
SELECT f.customer_id,
       f.failed_payment_count,
       r.plan_name AS current_plan,
       ROUND(r.risk_score, 4) AS churn_risk_score
FROM recent_fails f
JOIN risk r ON r.customer_id = f.customer_id
WHERE r.risk_quartile = 1
ORDER BY f.failed_payment_count DESC, r.risk_score DESC, f.customer_id;


-- Q29  Engagement 30 days before vs 30 days after each customer's most recent price change
-- Engagement = average watch minutes per session. Only changes whose full 60-day window lies inside
-- the viewing data, and customers with sessions on both sides, are measured.
WITH seq AS (
    SELECT s.customer_id, s.plan_id, s.subscription_start_date,
           LAG(s.plan_id) OVER (PARTITION BY s.customer_id ORDER BY s.subscription_start_date) AS prev_plan_id,
           ROW_NUMBER()   OVER (PARTITION BY s.customer_id ORDER BY s.subscription_start_date DESC) AS rn_desc
    FROM subscriptions s
),
changes AS (
    SELECT q.customer_id,
           q.subscription_start_date AS change_date,
           pf.plan_name AS from_plan,
           pt.plan_name AS to_plan,
           CASE WHEN pt.monthly_price > pf.monthly_price THEN 'Upgrade' ELSE 'Downgrade' END AS direction
    FROM seq q
    JOIN subscription_plans pf ON pf.plan_id = q.prev_plan_id
    JOIN subscription_plans pt ON pt.plan_id = q.plan_id
    WHERE q.rn_desc = 1 AND q.prev_plan_id IS NOT NULL AND pf.monthly_price <> pt.monthly_price
),
bounds AS (
    SELECT MIN(viewing_date) AS first_day, MAX(viewing_date) AS last_day FROM viewing_activity
),
eng AS (
    SELECT ch.customer_id, ch.change_date, ch.from_plan, ch.to_plan, ch.direction,
           AVG(CASE WHEN v.viewing_date >= DATE_SUB(ch.change_date, INTERVAL 30 DAY)
                     AND v.viewing_date <  ch.change_date
                    THEN v.watch_duration_minutes END) AS avg_before,
           AVG(CASE WHEN v.viewing_date >= ch.change_date
                     AND v.viewing_date <  DATE_ADD(ch.change_date, INTERVAL 30 DAY)
                    THEN v.watch_duration_minutes END) AS avg_after
    FROM changes ch
    CROSS JOIN bounds b
    JOIN viewing_activity v ON v.customer_id = ch.customer_id
    WHERE DATE_SUB(ch.change_date, INTERVAL 30 DAY) >= b.first_day
      AND DATE_ADD(ch.change_date, INTERVAL 29 DAY) <= b.last_day
    GROUP BY ch.customer_id, ch.change_date, ch.from_plan, ch.to_plan, ch.direction
)
SELECT customer_id, change_date, from_plan, to_plan, direction,
       ROUND(avg_before, 1) AS avg_min_per_session_before,
       ROUND(avg_after, 1)  AS avg_min_per_session_after,
       ROUND(100 * (avg_after - avg_before) / avg_before, 1) AS pct_change
FROM eng
WHERE avg_before IS NOT NULL AND avg_after IS NOT NULL
ORDER BY pct_change, customer_id;


-- Q29b Summary of Q29: overall and by direction
WITH seq AS (
    SELECT s.customer_id, s.plan_id, s.subscription_start_date,
           LAG(s.plan_id) OVER (PARTITION BY s.customer_id ORDER BY s.subscription_start_date) AS prev_plan_id,
           ROW_NUMBER()   OVER (PARTITION BY s.customer_id ORDER BY s.subscription_start_date DESC) AS rn_desc
    FROM subscriptions s
),
changes AS (
    SELECT q.customer_id,
           q.subscription_start_date AS change_date,
           CASE WHEN pt.monthly_price > pf.monthly_price THEN 'Upgrade' ELSE 'Downgrade' END AS direction
    FROM seq q
    JOIN subscription_plans pf ON pf.plan_id = q.prev_plan_id
    JOIN subscription_plans pt ON pt.plan_id = q.plan_id
    WHERE q.rn_desc = 1 AND q.prev_plan_id IS NOT NULL AND pf.monthly_price <> pt.monthly_price
),
bounds AS (
    SELECT MIN(viewing_date) AS first_day, MAX(viewing_date) AS last_day FROM viewing_activity
),
eng AS (
    SELECT ch.customer_id, ch.direction,
           AVG(CASE WHEN v.viewing_date >= DATE_SUB(ch.change_date, INTERVAL 30 DAY)
                     AND v.viewing_date <  ch.change_date
                    THEN v.watch_duration_minutes END) AS avg_before,
           AVG(CASE WHEN v.viewing_date >= ch.change_date
                     AND v.viewing_date <  DATE_ADD(ch.change_date, INTERVAL 30 DAY)
                    THEN v.watch_duration_minutes END) AS avg_after
    FROM changes ch
    CROSS JOIN bounds b
    JOIN viewing_activity v ON v.customer_id = ch.customer_id
    WHERE DATE_SUB(ch.change_date, INTERVAL 30 DAY) >= b.first_day
      AND DATE_ADD(ch.change_date, INTERVAL 29 DAY) <= b.last_day
    GROUP BY ch.customer_id, ch.direction
),
measured AS (
    SELECT * FROM eng WHERE avg_before IS NOT NULL AND avg_after IS NOT NULL
),
summary AS (
    SELECT 0 AS sort_order, direction,
           COUNT(*) AS customers,
           ROUND(AVG(avg_before), 1) AS avg_before,
           ROUND(AVG(avg_after), 1)  AS avg_after,
           ROUND(100 * (AVG(avg_after) - AVG(avg_before)) / AVG(avg_before), 1) AS pct_change_of_averages,
           ROUND(AVG(100 * (avg_after - avg_before) / avg_before), 1)           AS avg_of_customer_pct_changes
    FROM measured
    GROUP BY direction
    UNION ALL
    SELECT 1, 'All changes',
           COUNT(*),
           ROUND(AVG(avg_before), 1),
           ROUND(AVG(avg_after), 1),
           ROUND(100 * (AVG(avg_after) - AVG(avg_before)) / AVG(avg_before), 1),
           ROUND(AVG(100 * (avg_after - avg_before) / avg_before), 1)
    FROM measured
)
SELECT direction, customers, avg_before, avg_after, pct_change_of_averages, avg_of_customer_pct_changes
FROM summary
ORDER BY sort_order, direction;


-- Q30  Country scorecard: customers, churn, churn rate, avg lifetime value of churned customers,
--      and the single most common churn reason - one result set
WITH cust AS (
    SELECT c.customer_id, c.country, cl.churned, cl.churn_reason
    FROM customers c
    JOIN churn_labels cl ON cl.customer_id = c.customer_id
),
spend AS (
    SELECT customer_id, SUM(amount_clean) AS lifetime_spend
    FROM payments
    WHERE payment_status = 'Success'
    GROUP BY customer_id
),
country_stats AS (
    SELECT cu.country,
           COUNT(*)                         AS total_customers,
           SUM(cu.churned)                  AS churned_customers,
           ROUND(100 * AVG(cu.churned), 2)  AS churn_rate_pct,
           ROUND(AVG(CASE WHEN cu.churned = 1 THEN COALESCE(s.lifetime_spend, 0) END), 2) AS avg_clv_of_churned
    FROM cust cu
    LEFT JOIN spend s ON s.customer_id = cu.customer_id
    GROUP BY cu.country
),
reasons AS (
    SELECT country, churn_reason, COUNT(*) AS reason_count,
           ROW_NUMBER() OVER (PARTITION BY country ORDER BY COUNT(*) DESC, churn_reason) AS rn
    FROM cust
    WHERE churned = 1
    GROUP BY country, churn_reason
)
SELECT cs.country, cs.total_customers, cs.churned_customers, cs.churn_rate_pct,
       cs.avg_clv_of_churned,
       r.churn_reason  AS top_churn_reason,
       r.reason_count  AS top_reason_count
FROM country_stats cs
LEFT JOIN reasons r ON r.country = cs.country AND r.rn = 1
ORDER BY cs.churn_rate_pct DESC, cs.country;


-- Q31  At-risk revenue: composite churn-risk score x monthly price, top 50 active customers
-- risk_score = average of the three normalised components (0 = safest, 1 = riskiest).
WITH ref_date AS (
    SELECT MAX(viewing_date) AS as_of, MIN(viewing_date) AS first_day FROM viewing_activity
),
active AS (
    SELECT s.customer_id, sp.plan_name, sp.monthly_price
    FROM subscriptions s
    JOIN subscription_plans sp ON sp.plan_id = s.plan_id
    WHERE s.subscription_status = 'Active'
),
last_view AS (
    SELECT customer_id, MAX(viewing_date) AS last_view_date FROM viewing_activity GROUP BY customer_id
),
pay AS (
    SELECT customer_id, COUNT(*) AS payments, SUM(payment_status = 'Failed') AS failed
    FROM payments GROUP BY customer_id
),
tix AS (
    SELECT customer_id, COUNT(*) AS support_ticket_count FROM support_tickets GROUP BY customer_id
),
feat AS (
    SELECT a.customer_id, a.plan_name, a.monthly_price,
           CAST(DATEDIFF(r.as_of, COALESCE(lv.last_view_date, DATE_SUB(r.first_day, INTERVAL 1 DAY))) AS DOUBLE) AS days_since_last_activity,
           COALESCE(CAST(p.failed AS DOUBLE) / NULLIF(p.payments, 0), 0) AS failed_payment_rate,
           CAST(COALESCE(t.support_ticket_count, 0) AS DOUBLE) AS support_ticket_count
    FROM active a
    CROSS JOIN ref_date r
    LEFT JOIN last_view lv ON lv.customer_id = a.customer_id
    LEFT JOIN pay p        ON p.customer_id  = a.customer_id
    LEFT JOIN tix t        ON t.customer_id  = a.customer_id
),
scored AS (
    SELECT customer_id, plan_name, monthly_price,
           days_since_last_activity, failed_payment_rate, support_ticket_count,
           (COALESCE((days_since_last_activity - MIN(days_since_last_activity) OVER ())
                     / NULLIF(MAX(days_since_last_activity) OVER () - MIN(days_since_last_activity) OVER (), 0), 0)
          + COALESCE((failed_payment_rate - MIN(failed_payment_rate) OVER ())
                     / NULLIF(MAX(failed_payment_rate) OVER () - MIN(failed_payment_rate) OVER (), 0), 0)
          + COALESCE((support_ticket_count - MIN(support_ticket_count) OVER ())
                     / NULLIF(MAX(support_ticket_count) OVER () - MIN(support_ticket_count) OVER (), 0), 0)) / 3 AS risk_score
    FROM feat
)
SELECT customer_id, plan_name, monthly_price,
       days_since_last_activity,
       ROUND(failed_payment_rate, 3) AS failed_payment_rate,
       support_ticket_count,
       ROUND(risk_score, 4)                   AS churn_risk_score,
       ROUND(monthly_price * risk_score, 2)   AS at_risk_revenue,
       RANK() OVER (ORDER BY monthly_price * risk_score DESC) AS at_risk_rank
FROM scored
ORDER BY monthly_price * risk_score DESC, customer_id
LIMIT 50;


-- Q32  Top 5 complaint subcategories per country in the most recent COMPLETED quarter,
--      with average resolution time and average satisfaction
-- The quarter is derived from the data: if the data ends on a quarter's last day, that quarter counts.
WITH ref_date AS (
    SELECT DATE_ADD(MAX(ticket_date), INTERVAL 1 DAY) AS d FROM support_tickets
),
last_quarter AS (
    SELECT DATE_SUB(x.q_start, INTERVAL 3 MONTH) AS q_from, x.q_start AS q_to
    FROM (SELECT DATE_ADD(MAKEDATE(YEAR(d), 1), INTERVAL (QUARTER(d) - 1) * 3 MONTH) AS q_start
          FROM ref_date) x
),
subcat AS (
    SELECT c.country, t.issue_subcategory,
           COUNT(*) AS tickets,
           ROUND(AVG(t.resolution_time_hours), 1)        AS avg_resolution_hours,
           ROUND(AVG(t.customer_satisfaction_score), 2)  AS avg_csat
    FROM support_tickets t
    JOIN customers c ON c.customer_id = t.customer_id
    CROSS JOIN last_quarter q
    WHERE t.ticket_date >= q.q_from AND t.ticket_date < q.q_to
    GROUP BY c.country, t.issue_subcategory
),
ranked AS (
    SELECT country, issue_subcategory, tickets, avg_resolution_hours, avg_csat,
           ROW_NUMBER() OVER (PARTITION BY country ORDER BY tickets DESC, issue_subcategory) AS rn
    FROM subcat
)
SELECT r.country, r.rn AS complaint_rank, r.issue_subcategory, r.tickets,
       r.avg_resolution_hours, r.avg_csat, q.q_from AS quarter_start
FROM ranked r
CROSS JOIN last_quarter q
WHERE r.rn <= 5
ORDER BY r.country, r.rn;


-- Q33  Win-back candidates: churned customers in the top quartile of lifetime value
-- Lifetime value = successful payments made on or before the churn date.
-- Engagement level = watch minutes in the 30 days up to the churn date:
--   0 = Inactive, under 45 = Low, under 90 = Medium, otherwise High.
WITH churned AS (
    SELECT cl.customer_id, cl.churn_date, cl.churn_reason, c.country
    FROM churn_labels cl
    JOIN customers c ON c.customer_id = cl.customer_id
    WHERE cl.churned = 1
),
ltv AS (
    SELECT ch.customer_id, ch.country, ch.churn_date, ch.churn_reason,
           COALESCE(SUM(p.amount_clean), 0) AS lifetime_value
    FROM churned ch
    LEFT JOIN payments p ON p.customer_id = ch.customer_id
                        AND p.payment_status = 'Success'
                        AND p.payment_date <= ch.churn_date
    GROUP BY ch.customer_id, ch.country, ch.churn_date, ch.churn_reason
),
ranked AS (
    SELECT customer_id, country, churn_date, churn_reason, lifetime_value,
           NTILE(4) OVER (ORDER BY lifetime_value DESC, customer_id) AS ltv_quartile
    FROM ltv
),
top_ltv AS (
    SELECT * FROM ranked WHERE ltv_quartile = 1
),
eng AS (
    SELECT t.customer_id, COALESCE(SUM(v.watch_duration_minutes), 0) AS watch_last_30d
    FROM top_ltv t
    LEFT JOIN viewing_activity v ON v.customer_id = t.customer_id
                                AND v.viewing_date <= t.churn_date
                                AND v.viewing_date >  DATE_SUB(t.churn_date, INTERVAL 30 DAY)
    GROUP BY t.customer_id
),
last_seen AS (
    SELECT t.customer_id, MAX(v.viewing_date) AS last_viewing_date
    FROM top_ltv t
    LEFT JOIN viewing_activity v ON v.customer_id = t.customer_id AND v.viewing_date <= t.churn_date
    GROUP BY t.customer_id
)
SELECT t.customer_id, t.country,
       sp.plan_name AS last_plan,
       ROUND(t.lifetime_value, 2) AS lifetime_value,
       t.churn_date, t.churn_reason,
       e.watch_last_30d AS watch_minutes_last_30d,
       CASE WHEN e.watch_last_30d = 0  THEN 'Inactive'
            WHEN e.watch_last_30d < 45 THEN 'Low'
            WHEN e.watch_last_30d < 90 THEN 'Medium'
            ELSE 'High' END AS last_engagement_level,
       l.last_viewing_date
FROM top_ltv t
JOIN eng e        ON e.customer_id = t.customer_id
JOIN last_seen l  ON l.customer_id = t.customer_id
JOIN subscriptions s       ON s.customer_id = t.customer_id AND s.subscription_status <> 'Plan Changed'
JOIN subscription_plans sp ON sp.plan_id = s.plan_id
ORDER BY t.lifetime_value DESC, t.customer_id;


-- Q34  Plan migration paths (customers with more than one subscription row)
-- Same-plan rows (a re-subscription that keeps the plan) are not migrations and are excluded here.
WITH seq AS (
    SELECT customer_id, plan_id,
           LAG(plan_id) OVER (PARTITION BY customer_id ORDER BY subscription_start_date) AS prev_plan_id
    FROM subscriptions
)
SELECT pf.plan_name AS from_plan,
       pt.plan_name AS to_plan,
       CASE WHEN pt.monthly_price > pf.monthly_price THEN 'Upgrade' ELSE 'Downgrade' END AS migration_type,
       COUNT(*) AS customers,
       ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_of_migrations,
       RANK() OVER (ORDER BY COUNT(*) DESC) AS popularity_rank
FROM seq q
JOIN subscription_plans pf ON pf.plan_id = q.prev_plan_id
JOIN subscription_plans pt ON pt.plan_id = q.plan_id
WHERE q.prev_plan_id IS NOT NULL AND q.prev_plan_id <> q.plan_id
GROUP BY pf.plan_name, pt.plan_name, pf.monthly_price, pt.monthly_price
ORDER BY popularity_rank, from_plan, to_plan;


-- Q34b Do upgraders churn differently from downgraders? (latest migration per customer)
WITH seq AS (
    SELECT customer_id, plan_id,
           LAG(plan_id) OVER (PARTITION BY customer_id ORDER BY subscription_start_date) AS prev_plan_id,
           ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY subscription_start_date DESC) AS rn_desc
    FROM subscriptions
),
latest AS (
    SELECT q.customer_id,
           CASE WHEN pt.monthly_price > pf.monthly_price THEN 'Upgrade'
                WHEN pt.monthly_price < pf.monthly_price THEN 'Downgrade'
                ELSE 'Same plan' END AS migration_type
    FROM seq q
    JOIN subscription_plans pf ON pf.plan_id = q.prev_plan_id
    JOIN subscription_plans pt ON pt.plan_id = q.plan_id
    WHERE q.prev_plan_id IS NOT NULL AND q.rn_desc = 1
),
typed AS (
    SELECT cl.customer_id, COALESCE(l.migration_type, 'No plan change') AS migration_type, cl.churned
    FROM churn_labels cl
    LEFT JOIN latest l ON l.customer_id = cl.customer_id
)
SELECT migration_type,
       COUNT(*)                        AS customers,
       SUM(churned)                    AS churned,
       ROUND(100 * AVG(churned), 2)    AS churn_rate_pct
FROM typed
GROUP BY migration_type
ORDER BY churn_rate_pct DESC, migration_type;


-- Q35  WAU, MAU and stickiness (WAU / MAU) for the last 6 months
-- MAU  = distinct viewers in the calendar month.
-- WAU  = average distinct viewers per complete Monday-Sunday week whose Monday falls in that month.
WITH ref_date AS (
    SELECT CAST(DATE_FORMAT(MAX(viewing_date), '%Y-%m-01') AS DATE) AS last_month,
           MAX(viewing_date) AS as_of
    FROM viewing_activity
),
mau AS (
    SELECT DATE_FORMAT(viewing_date, '%Y-%m') AS ym, COUNT(DISTINCT customer_id) AS mau
    FROM viewing_activity
    GROUP BY DATE_FORMAT(viewing_date, '%Y-%m')
),
weekly AS (
    SELECT DATE_SUB(viewing_date, INTERVAL WEEKDAY(viewing_date) DAY) AS week_start,
           COUNT(DISTINCT customer_id) AS weekly_active
    FROM viewing_activity
    GROUP BY DATE_SUB(viewing_date, INTERVAL WEEKDAY(viewing_date) DAY)
),
wau AS (
    SELECT DATE_FORMAT(w.week_start, '%Y-%m') AS ym,
           AVG(w.weekly_active) AS wau,
           COUNT(*)             AS weeks_counted
    FROM weekly w
    CROSS JOIN ref_date r
    WHERE DATE_ADD(w.week_start, INTERVAL 6 DAY) <= r.as_of
    GROUP BY DATE_FORMAT(w.week_start, '%Y-%m')
)
SELECT m.ym AS activity_month,
       ROUND(w.wau, 1)         AS wau,
       m.mau                   AS mau,
       ROUND(w.wau / m.mau, 3) AS stickiness_wau_mau,
       w.weeks_counted
FROM mau m
JOIN wau w ON w.ym = m.ym
CROSS JOIN ref_date r
WHERE m.ym >= DATE_FORMAT(DATE_SUB(r.last_month, INTERVAL 5 MONTH), '%Y-%m')
ORDER BY m.ym;


-- Q36  Retention-outreach list: ACTIVE customers who left negative feedback within 14 days
--      (before or after) of a failed payment or of a support ticket rated CSAT <= 2
-- Negative = corrected sentiment label (the supplied label is ~5% mislabeled).
WITH neg AS (
    SELECT customer_id, feedback_id, feedback_date
    FROM customer_feedback
    WHERE sentiment_corrected = 'Negative' AND feedback_date IS NOT NULL
),
trigger_events AS (
    SELECT customer_id, payment_date AS event_date, 'failed_payment' AS trigger_type
    FROM payments
    WHERE payment_status = 'Failed'
    UNION ALL
    SELECT customer_id, ticket_date, 'low_csat_ticket'
    FROM support_tickets
    WHERE customer_satisfaction_score <= 2 AND ticket_date IS NOT NULL
),
matched AS (
    SELECT n.customer_id, n.feedback_id, e.trigger_type,
           ABS(DATEDIFF(n.feedback_date, e.event_date)) AS days_apart
    FROM neg n
    JOIN trigger_events e ON e.customer_id = n.customer_id
                         AND ABS(DATEDIFF(n.feedback_date, e.event_date)) <= 14
)
SELECT m.customer_id,
       COUNT(DISTINCT m.feedback_id)              AS negative_feedbacks,
       SUM(m.trigger_type = 'failed_payment')     AS near_failed_payment,
       SUM(m.trigger_type = 'low_csat_ticket')    AS near_low_csat_ticket,
       MIN(m.days_apart)                          AS closest_days
FROM matched m
JOIN churn_labels cl ON cl.customer_id = m.customer_id AND cl.churned = 0
GROUP BY m.customer_id
ORDER BY negative_feedbacks DESC, closest_days, m.customer_id;


-- Q37  Customer health score (0-100) for every ACTIVE customer, ranked by risk
-- risk_score_0_100 = 100 x weighted sum of min-max normalised components (1 = worst):
--   recency of last viewing 30% | payment failure rate 25% | support satisfaction 15% (low = risky)
--   tenure 15% (short = risky)  | plan 15% (Basic 1.0, Standard 0.5, Premium 0.0)
-- Customers with no rated tickets get the overall average satisfaction (neutral).
-- health_score = 100 - risk_score_0_100.
WITH ref_date AS (
    SELECT MAX(viewing_date) AS as_of, MIN(viewing_date) AS first_day FROM viewing_activity
),
active AS (
    SELECT s.customer_id, sp.plan_name, c.registration_date
    FROM subscriptions s
    JOIN subscription_plans sp ON sp.plan_id = s.plan_id
    JOIN customers c           ON c.customer_id = s.customer_id
    WHERE s.subscription_status = 'Active'
),
last_view AS (
    SELECT customer_id, MAX(viewing_date) AS last_view_date FROM viewing_activity GROUP BY customer_id
),
pay AS (
    SELECT customer_id, COUNT(*) AS payments, SUM(payment_status = 'Failed') AS failed
    FROM payments GROUP BY customer_id
),
csat AS (
    SELECT customer_id, AVG(customer_satisfaction_score) AS avg_csat
    FROM support_tickets
    WHERE customer_satisfaction_score IS NOT NULL
    GROUP BY customer_id
),
feat AS (
    SELECT a.customer_id, a.plan_name,
           CAST(DATEDIFF(r.as_of, COALESCE(lv.last_view_date, DATE_SUB(r.first_day, INTERVAL 1 DAY))) AS DOUBLE) AS days_since_last_activity,
           COALESCE(CAST(p.failed AS DOUBLE) / NULLIF(p.payments, 0), 0) AS failed_payment_rate,
           CAST(COALESCE(cs.avg_csat, (SELECT AVG(customer_satisfaction_score) FROM support_tickets)) AS DOUBLE) AS avg_csat,
           CAST(DATEDIFF(r.as_of, a.registration_date) AS DOUBLE) AS tenure_days,
           CASE a.plan_name WHEN 'Basic' THEN 1.0 WHEN 'Standard' THEN 0.5 ELSE 0.0 END AS plan_risk
    FROM active a
    CROSS JOIN ref_date r
    LEFT JOIN last_view lv ON lv.customer_id = a.customer_id
    LEFT JOIN pay p        ON p.customer_id  = a.customer_id
    LEFT JOIN csat cs      ON cs.customer_id = a.customer_id
),
scored AS (
    SELECT customer_id, plan_name, days_since_last_activity, failed_payment_rate, avg_csat, tenure_days,
           100 * (0.30 * COALESCE((days_since_last_activity - MIN(days_since_last_activity) OVER ())
                                  / NULLIF(MAX(days_since_last_activity) OVER () - MIN(days_since_last_activity) OVER (), 0), 0)
                + 0.25 * COALESCE((failed_payment_rate - MIN(failed_payment_rate) OVER ())
                                  / NULLIF(MAX(failed_payment_rate) OVER () - MIN(failed_payment_rate) OVER (), 0), 0)
                + 0.15 * (1 - COALESCE((avg_csat - MIN(avg_csat) OVER ())
                                  / NULLIF(MAX(avg_csat) OVER () - MIN(avg_csat) OVER (), 0), 0))
                + 0.15 * (1 - COALESCE((tenure_days - MIN(tenure_days) OVER ())
                                  / NULLIF(MAX(tenure_days) OVER () - MIN(tenure_days) OVER (), 0), 0))
                + 0.15 * plan_risk) AS risk_score
    FROM feat
)
SELECT customer_id, plan_name AS current_plan,
       days_since_last_activity,
       ROUND(failed_payment_rate, 3) AS failed_payment_rate,
       ROUND(avg_csat, 2)            AS avg_support_csat,
       tenure_days,
       ROUND(risk_score, 1)          AS risk_score_0_100,
       ROUND(100 - risk_score, 1)    AS health_score_0_100,
       RANK() OVER (ORDER BY risk_score DESC) AS risk_rank
FROM scored
ORDER BY risk_rank, customer_id;