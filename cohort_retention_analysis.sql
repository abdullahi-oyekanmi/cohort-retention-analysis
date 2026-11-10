-- =====================================================================
-- Customer Retention Analysis (CloudDesk case study)
-- Tool: PostgreSQL | Run order: top to bottom
-- =====================================================================
-- SETUP
--   Source data: three CSVs (accounts, billing, onboarding_calls).
--   Create the three tables and load each CSV first (e.g. COPY ... CSV HEADER).
--   Expected columns (check types against your own tables):
--     accounts(account_id, plan, channel, signup_date DATE)
--     billing(account_id, billing_month TEXT 'YYYY-MM', mrr NUMERIC, status TEXT)
--     onboarding_calls(account_id, call_date DATE)
--
-- CONSTANTS USED BELOW (hardcoded; change them here if the data changes)
--   Last data month ........ 2026-09-01  (a month is "observable" only if it is on or before this)
--   Old/new cohort cutoff .. 2026-03-01  (old = Oct-Feb signups, new = Mar-Jun signups)
--   Plan prices ............ Basic 29.00, Pro 79.00, Business 199.00 (MRR is fixed per plan)
--
-- KEY DEFINITIONS
--   Month 0 = signup month.
--   Churned = no billing row in 2026-09. Active = has a billing row in 2026-09.
--   Failed payments count as active (see section 7 for the supporting evidence).
--   Eligible for month N = signup month + N <= 2026-09.
--   Retained at month N = has a billing row exactly N months after the signup month.
--   Retention rate = retained / eligible.
-- =====================================================================


-- =====================================================================
-- 0. RESET (drops views so the file can be re-run from scratch)
-- =====================================================================
DROP VIEW IF EXISTS acct_calls;
DROP VIEW IF EXISTS acct_flags;
DROP VIEW IF EXISTS billing_cleaned;
DROP VIEW IF EXISTS accounts_cleaned;


-- =====================================================================
-- 1. PROFILING (raw tables) -- each check lists the result it should return
-- =====================================================================

-- 1.1 accounts ---------------------------------------------------------
SELECT COUNT(*) AS accounts FROM accounts;                                   -- expect 600

SELECT COUNT(*) - COUNT(DISTINCT account_id) AS duplicate_account_ids
FROM accounts;                                                               -- expect 0

SELECT plan, COUNT(*) AS accounts FROM accounts GROUP BY plan ORDER BY plan; -- inconsistent labels: Basic/BASIC, Pro/pro, Business
SELECT channel, COUNT(*) AS accounts FROM accounts GROUP BY channel ORDER BY channel; -- 4 clean values

SELECT MIN(signup_date) AS first_signup, MAX(signup_date) AS last_signup
FROM accounts;                                                               -- 2025-10-01 to 2026-06-27

-- 1.2 billing ----------------------------------------------------------
SELECT COUNT(*) AS billing_rows FROM billing;                                -- expect 3591

-- Exact duplicate rows
SELECT (SELECT COUNT(*) FROM billing)
     - (SELECT COUNT(*) FROM (SELECT DISTINCT * FROM billing) t) AS duplicate_rows;   -- expect 12

-- Duplicates that conflict (same account and month, different values)?
SELECT (SELECT COUNT(*) FROM (SELECT DISTINCT * FROM billing) t)
     - (SELECT COUNT(*) FROM (SELECT DISTINCT account_id, billing_month FROM billing) t) AS conflicting_duplicates;  -- expect 0 (duplicates are exact copies)

-- Orphan rows: billing rows whose account_id is not in accounts
SELECT COUNT(*) AS orphan_billing_rows
FROM billing
WHERE account_id NOT IN (SELECT account_id FROM accounts);                   -- expect 5

SELECT MIN(billing_month) AS first_month, MAX(billing_month) AS last_month
FROM billing;                                                                -- 2025-10 to 2026-09

SELECT status, COUNT(*) AS billing_rows FROM billing GROUP BY status;        -- Paid / Failed only

-- Billing before signup
SELECT COUNT(*) AS billing_before_signup
FROM billing b JOIN accounts a USING (account_id)
WHERE b.billing_month < TO_CHAR(a.signup_date, 'YYYY-MM');                   -- expect 0

-- Does every account's first bill fall in its signup month? (supports "month 0 = signup month")
SELECT COUNT(*) FILTER (WHERE first_bill = TO_CHAR(signup_date, 'YYYY-MM')) AS first_bill_in_signup_month,
       COUNT(*) AS accounts
FROM (
  SELECT a.account_id, a.signup_date, MIN(b.billing_month) AS first_bill
  FROM accounts a JOIN billing b USING (account_id)
  GROUP BY a.account_id, a.signup_date
) t;                                                                         -- expect 600 and 600

-- MRR: zero/negative values, nulls, and the price per plan
SELECT COUNT(*) AS non_positive_mrr FROM billing WHERE mrr <= 0;             -- expect 0
SELECT COUNT(*) AS null_mrr FROM billing WHERE mrr IS NULL;                  -- expect 10

SELECT INITCAP(a.plan) AS plan, b.mrr, COUNT(*) AS billing_rows
FROM billing b JOIN accounts a USING (account_id)
GROUP BY 1, 2 ORDER BY 1, 2;                                                 -- one price per plan (29 / 79 / 199), plus null rows

-- 1.3 onboarding_calls -------------------------------------------------
SELECT COUNT(*) AS calls FROM onboarding_calls;                              -- expect 330

SELECT COUNT(*) - COUNT(DISTINCT account_id) AS duplicate_call_accounts
FROM onboarding_calls;                                                       -- expect 0 (at most one call per account)

SELECT COUNT(*) AS orphan_calls
FROM onboarding_calls
WHERE account_id NOT IN (SELECT account_id FROM accounts);                   -- expect 0

SELECT COUNT(*) AS calls_on_or_before_signup
FROM onboarding_calls o JOIN accounts a USING (account_id)
WHERE o.call_date <= a.signup_date;                                          -- expect 0

-- How soon after signup do calls happen? (relevant to survivorship bias)
SELECT MIN(o.call_date - a.signup_date) AS min_days,
       MAX(o.call_date - a.signup_date) AS max_days
FROM onboarding_calls o JOIN accounts a USING (account_id);                  -- calls happen within about two weeks of signup


-- =====================================================================
-- 2. CLEANING (views; the raw tables are left untouched)
-- =====================================================================

-- 2.1 accounts: standardize plan labels (BASIC -> Basic, pro -> Pro)
CREATE VIEW accounts_cleaned AS
SELECT account_id,
       INITCAP(plan) AS plan,
       channel,
       signup_date
FROM accounts;

-- 2.2 billing:
--   * DISTINCT removes the 12 exact duplicate rows
--   * the inner join to accounts removes the 5 orphan rows (no matching account)
--   * null MRR is filled with the plan's fixed price (all nulls are Paid rows;
--     MRR does not affect the retention results)
CREATE VIEW billing_cleaned AS
WITH billing_dedup AS (
  SELECT DISTINCT b.account_id, b.billing_month, b.mrr, b.status
  FROM billing b
  JOIN accounts a USING (account_id)
)
SELECT d.account_id,
       d.billing_month,
       COALESCE(d.mrr,
                CASE LOWER(a.plan)
                  WHEN 'basic'    THEN 29.00
                  WHEN 'pro'      THEN 79.00
                  WHEN 'business' THEN 199.00
                END) AS mrr,
       d.status
FROM billing_dedup d
JOIN accounts a USING (account_id);

-- 2.3 onboarding_calls: no cleaning needed, used as is.

-- 2.4 Verify the cleaning
SELECT COUNT(*) AS accounts_cleaned_rows FROM accounts_cleaned;              -- expect 600
SELECT plan, COUNT(*) AS accounts FROM accounts_cleaned GROUP BY plan;       -- expect 3 plans: Basic 288, Pro 218, Business 94
SELECT COUNT(*) AS billing_cleaned_rows FROM billing_cleaned;                -- expect 3574 (3591 - 12 duplicates - 5 orphans)
SELECT COUNT(*) AS null_mrr_after FROM billing_cleaned WHERE mrr IS NULL;    -- expect 0

-- Skipped months: any account whose billed months are not consecutive?
SELECT COUNT(*) AS accounts_with_skipped_months
FROM (
  SELECT account_id
  FROM billing_cleaned
  GROUP BY account_id
  HAVING MAX(LEFT(billing_month, 4)::INT * 12 + RIGHT(billing_month, 2)::INT)
       - MIN(LEFT(billing_month, 4)::INT * 12 + RIGHT(billing_month, 2)::INT) + 1 <> COUNT(*)
) t;                                                                         -- expect 0 (so "billed at month N" = "last billed month >= N")

-- Calls made after an account's last billed month (kept in the data; see the note)
SELECT COUNT(*) AS calls_after_last_bill
FROM onboarding_calls o
JOIN (SELECT account_id, MAX(billing_month) AS last_bill
      FROM billing_cleaned GROUP BY account_id) l USING (account_id)
WHERE TO_CHAR(o.call_date, 'YYYY-MM') > l.last_bill;                         -- expect 2


-- =====================================================================
-- 3. COHORT RETENTION TABLE (question 1)
-- =====================================================================

-- 3.1 Wide format (cohorts as rows, months since signup as columns), for reading.
--     NULL means the cohort has not reached that month yet (not 0%).
WITH
  cohort_base AS (
    SELECT a.account_id,
           DATE_TRUNC('month', signup_date)::DATE AS signup_month,
           billing_month
    FROM accounts_cleaned a LEFT JOIN billing_cleaned USING (account_id)
  ),
  retention_calc AS (
    SELECT account_id,
           signup_month,
           -- months since signup (month 0, 1, 2, ...)
           (LEFT(billing_month, 4)::NUMERIC - EXTRACT(YEAR FROM signup_month)) * 12 +
           (RIGHT(billing_month, 2)::NUMERIC - EXTRACT(MONTH FROM signup_month)) AS months_since_signup
    FROM cohort_base
  ),
  cohort_sizes AS (
    SELECT signup_month,
           COUNT(DISTINCT account_id) AS total_cohort_size
    FROM cohort_base
    GROUP BY signup_month
  ),
  cohort_matrix AS (
    SELECT r.signup_month,
           s.total_cohort_size,
           r.months_since_signup,
           COUNT(DISTINCT r.account_id) AS active_accounts
    FROM retention_calc r
    JOIN cohort_sizes s ON r.signup_month = s.signup_month
    GROUP BY r.signup_month, s.total_cohort_size, r.months_since_signup
  )
SELECT TO_CHAR(signup_month, 'YYYY-MM') AS cohort,
       total_cohort_size AS size,
       ROUND(SUM(CASE WHEN months_since_signup = 0  THEN active_accounts END) * 1.0 / total_cohort_size, 2) AS month_0,
       ROUND(SUM(CASE WHEN months_since_signup = 1  THEN active_accounts END) * 1.0 / total_cohort_size, 2) AS month_1,
       ROUND(SUM(CASE WHEN months_since_signup = 2  THEN active_accounts END) * 1.0 / total_cohort_size, 2) AS month_2,
       ROUND(SUM(CASE WHEN months_since_signup = 3  THEN active_accounts END) * 1.0 / total_cohort_size, 2) AS month_3,
       ROUND(SUM(CASE WHEN months_since_signup = 4  THEN active_accounts END) * 1.0 / total_cohort_size, 2) AS month_4,
       ROUND(SUM(CASE WHEN months_since_signup = 5  THEN active_accounts END) * 1.0 / total_cohort_size, 2) AS month_5,
       ROUND(SUM(CASE WHEN months_since_signup = 6  THEN active_accounts END) * 1.0 / total_cohort_size, 2) AS month_6,
       ROUND(SUM(CASE WHEN months_since_signup = 7  THEN active_accounts END) * 1.0 / total_cohort_size, 2) AS month_7,
       ROUND(SUM(CASE WHEN months_since_signup = 8  THEN active_accounts END) * 1.0 / total_cohort_size, 2) AS month_8,
       ROUND(SUM(CASE WHEN months_since_signup = 9  THEN active_accounts END) * 1.0 / total_cohort_size, 2) AS month_9,
       ROUND(SUM(CASE WHEN months_since_signup = 10 THEN active_accounts END) * 1.0 / total_cohort_size, 2) AS month_10,
       ROUND(SUM(CASE WHEN months_since_signup = 11 THEN active_accounts END) * 1.0 / total_cohort_size, 2) AS month_11
FROM cohort_matrix
GROUP BY signup_month, total_cohort_size
ORDER BY signup_month;
-- (the long-format version of this table, used for Tableau, is in section 8)


-- =====================================================================
-- 4. ACCOUNT-LEVEL FLAGS (views used by the analysis below)
-- =====================================================================

-- 4.1 One row per account: period (old/new), and for N = 3 and N = 6
--     whether the account is eligible (month N has happened) and retained.
CREATE VIEW acct_flags AS
WITH acct AS (
  SELECT account_id, plan, channel,
         DATE_TRUNC('month', signup_date) AS signup_month,
         CASE WHEN signup_date < DATE '2026-03-01'
              THEN 'old (Oct-Feb)' ELSE 'new (Mar-Jun)' END AS period
  FROM accounts_cleaned
),
bill AS (
  -- one row per account per billed month, as a real date
  SELECT DISTINCT account_id,
         TO_DATE(billing_month || '-01', 'YYYY-MM-DD') AS bill_month
  FROM billing_cleaned
)
SELECT a.account_id, a.plan, a.channel, a.period,
       -- N = 3
       (a.signup_month + INTERVAL '3 months' <= DATE '2026-09-01') AS eligible_3,
       EXISTS (SELECT 1 FROM bill b
               WHERE b.account_id = a.account_id
                 AND b.bill_month = a.signup_month + INTERVAL '3 months') AS retained_3,
       -- N = 6
       (a.signup_month + INTERVAL '6 months' <= DATE '2026-09-01') AS eligible_6,
       EXISTS (SELECT 1 FROM bill b
               WHERE b.account_id = a.account_id
                 AND b.bill_month = a.signup_month + INTERVAL '6 months') AS retained_6
FROM acct a;

-- 4.2 Attach whether the account had an onboarding call.
--     One row per account, because onboarding_calls has no duplicate account IDs
--     (checked in 1.3). If it ever did, this join would multiply rows.
CREATE VIEW acct_calls AS
SELECT f.*, (o.account_id IS NOT NULL) AS had_call
FROM acct_flags f
LEFT JOIN onboarding_calls o ON o.account_id = f.account_id;

-- 4.3 Sanity check
SELECT COUNT(*)                                          AS accounts,        -- expect 600
       COUNT(*) FILTER (WHERE eligible_3)                AS eligible_3,      -- expect 600
       COUNT(*) FILTER (WHERE eligible_3 AND retained_3) AS retained_3,      -- expect 448
       COUNT(*) FILTER (WHERE eligible_6)                AS eligible_6,      -- expect 389
       COUNT(*) FILTER (WHERE had_call)                  AS with_call        -- expect 330
FROM acct_calls;


-- =====================================================================
-- 5. QUESTION 1: DO NEWER COHORTS RETAIN WORSE?
-- =====================================================================

-- 5.1 Pooled month-3 retention, older vs newer signups
SELECT period,
       COUNT(*) FILTER (WHERE eligible_3)                AS denominator,
       COUNT(*) FILTER (WHERE eligible_3 AND retained_3) AS retained,
       ROUND(100.0 * COUNT(*) FILTER (WHERE eligible_3 AND retained_3)
             / COUNT(*) FILTER (WHERE eligible_3), 1)    AS retention_pct
FROM acct_flags
GROUP BY period
ORDER BY period;                                         -- expect new 197/289 = 68.2, old 251/311 = 80.7

-- 5.2 Did the plan or channel mix change between periods? (share of each period)
SELECT period, plan,
       COUNT(*) AS accounts,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY period), 1) AS pct_of_period
FROM acct_flags
GROUP BY period, plan
ORDER BY period, plan;

SELECT period, channel,
       COUNT(*) AS accounts,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY period), 1) AS pct_of_period
FROM acct_flags
GROUP BY period, channel
ORDER BY period, channel;

-- 5.3 Month-3 retention by plan and by channel within each period
SELECT period, plan,
       COUNT(*) FILTER (WHERE eligible_3)                AS denominator,
       COUNT(*) FILTER (WHERE eligible_3 AND retained_3) AS retained,
       ROUND(100.0 * COUNT(*) FILTER (WHERE eligible_3 AND retained_3)
             / COUNT(*) FILTER (WHERE eligible_3), 1)    AS retention_pct
FROM acct_flags
GROUP BY period, plan
ORDER BY plan, period;

SELECT period, channel,
       COUNT(*) FILTER (WHERE eligible_3)                AS denominator,
       COUNT(*) FILTER (WHERE eligible_3 AND retained_3) AS retained,
       ROUND(100.0 * COUNT(*) FILTER (WHERE eligible_3 AND retained_3)
             / COUNT(*) FILTER (WHERE eligible_3), 1)    AS retention_pct
FROM acct_flags
GROUP BY period, channel
ORDER BY channel, period;


-- =====================================================================
-- 6. QUESTION 2: WHERE IS CHURN CONCENTRATED? (plan, channel)
-- =====================================================================

-- 6.1 Retention by plan: N = 3 (main) and N = 6 (check)
SELECT plan,
       COUNT(*) FILTER (WHERE eligible_3)                AS denominator,
       COUNT(*) FILTER (WHERE eligible_3 AND retained_3) AS retained,
       ROUND(100.0 * COUNT(*) FILTER (WHERE eligible_3 AND retained_3)
             / COUNT(*) FILTER (WHERE eligible_3), 1)    AS retention_pct
FROM acct_flags
GROUP BY plan
ORDER BY retention_pct;

SELECT plan,
       COUNT(*) FILTER (WHERE eligible_6)                AS denominator,
       COUNT(*) FILTER (WHERE eligible_6 AND retained_6) AS retained,
       ROUND(100.0 * COUNT(*) FILTER (WHERE eligible_6 AND retained_6)
             / COUNT(*) FILTER (WHERE eligible_6), 1)    AS retention_pct
FROM acct_flags
GROUP BY plan
ORDER BY retention_pct;

-- 6.2 Retention by channel: N = 3 and N = 6
SELECT channel,
       COUNT(*) FILTER (WHERE eligible_3)                AS denominator,
       COUNT(*) FILTER (WHERE eligible_3 AND retained_3) AS retained,
       ROUND(100.0 * COUNT(*) FILTER (WHERE eligible_3 AND retained_3)
             / COUNT(*) FILTER (WHERE eligible_3), 1)    AS retention_pct
FROM acct_flags
GROUP BY channel
ORDER BY retention_pct;

SELECT channel,
       COUNT(*) FILTER (WHERE eligible_6)                AS denominator,
       COUNT(*) FILTER (WHERE eligible_6 AND retained_6) AS retained,
       ROUND(100.0 * COUNT(*) FILTER (WHERE eligible_6 AND retained_6)
             / COUNT(*) FILTER (WHERE eligible_6), 1)    AS retention_pct
FROM acct_flags
GROUP BY channel
ORDER BY retention_pct;

-- 6.3 Cross-check: plan x channel at N = 3 (is the Paid Ads gap independent of plan?)
SELECT channel, plan,
       COUNT(*) FILTER (WHERE eligible_3)                AS denominator,
       COUNT(*) FILTER (WHERE eligible_3 AND retained_3) AS retained,
       ROUND(100.0 * COUNT(*) FILTER (WHERE eligible_3 AND retained_3)
             / COUNT(*) FILTER (WHERE eligible_3), 1)    AS retention_pct
FROM acct_flags
GROUP BY channel, plan
ORDER BY channel, plan;


-- =====================================================================
-- 7. QUESTION 3: DO ONBOARDING CALLS HELP?
-- =====================================================================

-- 7.1 Were calls handed out evenly? (share of accounts with a call)
SELECT 'plan' AS dimension, plan AS grp,
       COUNT(*) AS accounts,
       COUNT(*) FILTER (WHERE had_call) AS with_call,
       ROUND(100.0 * COUNT(*) FILTER (WHERE had_call) / COUNT(*), 1) AS pct_with_call
FROM acct_calls GROUP BY plan
UNION ALL
SELECT 'channel', channel, COUNT(*),
       COUNT(*) FILTER (WHERE had_call),
       ROUND(100.0 * COUNT(*) FILTER (WHERE had_call) / COUNT(*), 1)
FROM acct_calls GROUP BY channel
UNION ALL
SELECT 'period', period, COUNT(*),
       COUNT(*) FILTER (WHERE had_call),
       ROUND(100.0 * COUNT(*) FILTER (WHERE had_call) / COUNT(*), 1)
FROM acct_calls GROUP BY period
ORDER BY dimension, grp;

-- 7.2 Retention with a call vs without: N = 3 (main) and N = 6 (check)
SELECT had_call,
       COUNT(*) FILTER (WHERE eligible_3)                AS denominator,
       COUNT(*) FILTER (WHERE eligible_3 AND retained_3) AS retained,
       ROUND(100.0 * COUNT(*) FILTER (WHERE eligible_3 AND retained_3)
             / COUNT(*) FILTER (WHERE eligible_3), 1)    AS retention_pct
FROM acct_calls
GROUP BY had_call;                                       -- expect with call 273/330 = 82.7, without 175/270 = 64.8

SELECT had_call,
       COUNT(*) FILTER (WHERE eligible_6)                AS denominator,
       COUNT(*) FILTER (WHERE eligible_6 AND retained_6) AS retained,
       ROUND(100.0 * COUNT(*) FILTER (WHERE eligible_6 AND retained_6)
             / COUNT(*) FILTER (WHERE eligible_6), 1)    AS retention_pct
FROM acct_calls
GROUP BY had_call;

-- 7.3 Same comparison within each plan, so plan cannot explain the gap
SELECT plan, had_call,
       COUNT(*) FILTER (WHERE eligible_3)                AS denominator,
       ROUND(100.0 * COUNT(*) FILTER (WHERE eligible_3 AND retained_3)
             / COUNT(*) FILTER (WHERE eligible_3), 1)    AS retention_pct
FROM acct_calls
GROUP BY plan, had_call
ORDER BY plan, had_call;

SELECT plan, had_call,
       COUNT(*) FILTER (WHERE eligible_6)                AS denominator,
       ROUND(100.0 * COUNT(*) FILTER (WHERE eligible_6 AND retained_6)
             / COUNT(*) FILTER (WHERE eligible_6), 1)    AS retention_pct
FROM acct_calls
GROUP BY plan, had_call
ORDER BY plan, had_call;


-- =====================================================================
-- 8. SUPPORTING CHECKS (evidence for the definitions)
-- =====================================================================

-- 8.1 Active vs churned at the end of the data (churned = no billing row in 2026-09)
SELECT COUNT(*) FILTER (WHERE last_bill = '2026-09') AS active,    -- expect 343
       COUNT(*) FILTER (WHERE last_bill <> '2026-09') AS churned   -- expect 257
FROM (SELECT account_id, MAX(billing_month) AS last_bill
      FROM billing_cleaned GROUP BY account_id) t;

-- 8.2 Failed payments: what happens next? (supports "Failed counts as active")
WITH nxt AS (
  SELECT account_id, billing_month, status,
         LEAD(status) OVER (PARTITION BY account_id ORDER BY billing_month) AS next_status
  FROM billing_cleaned
)
SELECT COUNT(*)                                    AS failed_rows,        -- expect 143
       COUNT(*) FILTER (WHERE next_status = 'Paid') AS followed_by_paid,  -- expect 116
       COUNT(*) FILTER (WHERE next_status IS NULL)  AS final_row          -- expect 22
FROM nxt
WHERE status = 'Failed';

-- 8.3 Accounts whose final billing row is Failed
--     (final month 2026-09 = counted as active; earlier = counted as churned)
SELECT (billing_month = '2026-09') AS in_last_data_month,
       COUNT(*) AS accounts                         -- expect 10 in the last month, 12 earlier
FROM (
  SELECT DISTINCT ON (account_id) account_id, billing_month, status
  FROM billing_cleaned
  ORDER BY account_id, billing_month DESC
) last_row
WHERE status = 'Failed'
GROUP BY 1;

-- 8.4 EXPLORATORY (not reported in the findings): month-3 retention counting only
--     Paid rows as retained, to compare with the 448 retained of 600 above.
WITH a AS (
  SELECT account_id, DATE_TRUNC('month', signup_date) AS sm
  FROM accounts_cleaned
)
SELECT COUNT(*) AS eligible,
       COUNT(*) FILTER (WHERE EXISTS (
         SELECT 1 FROM billing_cleaned b
         WHERE b.account_id = a.account_id
           AND TO_DATE(b.billing_month || '-01', 'YYYY-MM-DD') = a.sm + INTERVAL '3 months'
           AND b.status = 'Paid'
       )) AS retained_paid_only                     -- 429 when run on this data
FROM a
WHERE a.sm + INTERVAL '3 months' <= DATE '2026-09-01';


-- =====================================================================
-- 9. EXPORT QUERIES FOR TABLEAU (one per dashboard)
-- =====================================================================

-- 9.1 Q1: cohort retention, long format (one row per cohort per month).
--     Months that have not happened yet have no row, so they stay blank in Tableau.
WITH acct AS (
  SELECT account_id,
         DATE_TRUNC('month', signup_date) AS signup_month
  FROM accounts_cleaned
),
bill AS (
  SELECT DISTINCT account_id,
         TO_DATE(billing_month || '-01', 'YYYY-MM-DD') AS bill_month
  FROM billing_cleaned
),
cohort_size AS (
  SELECT signup_month, COUNT(*) AS cohort_size
  FROM acct
  GROUP BY signup_month
),
active AS (
  SELECT a.signup_month,
         -- whole months between signup month and billing month
         ((EXTRACT(YEAR  FROM b.bill_month) - EXTRACT(YEAR  FROM a.signup_month)) * 12
         + EXTRACT(MONTH FROM b.bill_month) - EXTRACT(MONTH FROM a.signup_month))::INT AS month_n,
         COUNT(DISTINCT a.account_id) AS retained
  FROM acct a
  JOIN bill b ON b.account_id = a.account_id
  GROUP BY a.signup_month, month_n
)
SELECT TO_CHAR(c.signup_month, 'YYYY-MM') AS cohort,
       c.cohort_size,
       x.month_n,
       x.retained,
       ROUND(100.0 * x.retained / c.cohort_size, 1) AS retention_pct
FROM cohort_size c
JOIN active x ON x.signup_month = c.signup_month
ORDER BY cohort, month_n;                            -- expect 72 rows

-- 9.2 Q2: plan and channel retention at N = 3 and N = 6, with denominators,
--     churned counts, share of accounts and share of churners.
WITH long AS (
  SELECT 'plan' AS dimension, plan AS grp,
         eligible_3, retained_3, eligible_6, retained_6
  FROM acct_flags
  UNION ALL
  SELECT 'channel', channel,
         eligible_3, retained_3, eligible_6, retained_6
  FROM acct_flags
),
n3 AS (
  SELECT dimension, grp, 3 AS n_months,
         COUNT(*) FILTER (WHERE eligible_3)                AS denominator,
         COUNT(*) FILTER (WHERE eligible_3 AND retained_3) AS retained
  FROM long GROUP BY dimension, grp
),
n6 AS (
  SELECT dimension, grp, 6 AS n_months,
         COUNT(*) FILTER (WHERE eligible_6)                AS denominator,
         COUNT(*) FILTER (WHERE eligible_6 AND retained_6) AS retained
  FROM long GROUP BY dimension, grp
),
combined AS (
  SELECT * FROM n3
  UNION ALL
  SELECT * FROM n6
)
SELECT dimension, grp, n_months, denominator, retained,
       denominator - retained AS churned,
       ROUND(100.0 * retained / denominator, 1) AS retention_pct,
       -- share of all measurable accounts in this dimension
       ROUND(100.0 * denominator / SUM(denominator)
             OVER (PARTITION BY dimension, n_months), 1) AS share_of_accounts,
       -- share of all lost accounts in this dimension
       ROUND(100.0 * (denominator - retained) / SUM(denominator - retained)
             OVER (PARTITION BY dimension, n_months), 1) AS share_of_churners
FROM combined
ORDER BY dimension, n_months, retention_pct;

-- 9.3 Q3: call vs no call, within each plan and for all plans together,
--     at N = 3 and N = 6. In Tableau, keep "All plans" out of the by-plan chart.
WITH x AS (
  SELECT plan, had_call, eligible_3, retained_3, eligible_6, retained_6
  FROM acct_calls
  UNION ALL
  SELECT 'All plans', had_call, eligible_3, retained_3, eligible_6, retained_6
  FROM acct_calls
),
n3 AS (
  SELECT plan, had_call, 3 AS n_months,
         COUNT(*) FILTER (WHERE eligible_3)                AS denominator,
         COUNT(*) FILTER (WHERE eligible_3 AND retained_3) AS retained
  FROM x GROUP BY plan, had_call
),
n6 AS (
  SELECT plan, had_call, 6 AS n_months,
         COUNT(*) FILTER (WHERE eligible_6)                AS denominator,
         COUNT(*) FILTER (WHERE eligible_6 AND retained_6) AS retained
  FROM x GROUP BY plan, had_call
)
SELECT plan, had_call, n_months, denominator, retained,
       ROUND(100.0 * retained / denominator, 1) AS retention_pct
FROM (SELECT * FROM n3 UNION ALL SELECT * FROM n6) t
ORDER BY n_months, plan, had_call;
