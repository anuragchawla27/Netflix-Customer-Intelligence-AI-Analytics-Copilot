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
ORDER BY total_revenue DESC;


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
ORDER BY customers DESC;


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
ORDER BY avg_age DESC;


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
ORDER BY ct.content_type, avg_completion_pct DESC;


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
ORDER BY avg_resolution_hours DESC;


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
ORDER BY total_watch_minutes DESC;


-- Q12  Average rating by sentiment label (label as supplied in the data)
SELECT sentiment_label,
       ROUND(AVG(rating), 2) AS avg_rating,
       COUNT(*)              AS reviews
FROM customer_feedback
GROUP BY sentiment_label
ORDER BY avg_rating DESC;


-- Q12b Same question using the corrected label (the supplied label is ~5% mislabeled)
SELECT sentiment_corrected,
       ROUND(AVG(rating), 2) AS avg_rating,
       COUNT(*)              AS reviews
FROM customer_feedback
GROUP BY sentiment_corrected
ORDER BY avg_rating DESC;


-- Q13  New customers per acquisition channel per calendar year
SELECT YEAR(registration_date) AS signup_year,
       acquisition_channel,
       COUNT(*)                AS customers
FROM customers
GROUP BY YEAR(registration_date), acquisition_channel
ORDER BY signup_year, customers DESC;


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