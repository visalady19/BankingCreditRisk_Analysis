-- Credit Risk & Default Analysis
-- Dataset: Home Credit Default Risk (Kaggle)
-- Builds master_credit_risk: 1 row per applicant (307,511 rows)


-- 1. Master table
-- aggregate bureau, previous apps and installments per applicant first,
-- then left join to application_train so row count stays the same

DROP TABLE IF EXISTS master_credit_risk;

CREATE TABLE master_credit_risk AS

WITH bureau_summary AS (
    SELECT
        sk_id_curr,
        COUNT(sk_id_bureau) AS total_external_loans,
        SUM(CASE WHEN credit_active = 'Active' THEN 1 ELSE 0 END) AS active_external_loans,
        COALESCE(SUM(amt_credit_sum_debt), 0) AS total_external_debt
    FROM bureau
    GROUP BY sk_id_curr
),

prev_app_summary AS (
    SELECT
        sk_id_curr,
        COUNT(sk_id_prev) AS total_prev_applications,
        SUM(CASE WHEN name_contract_status = 'Approved' THEN 1 ELSE 0 END) AS prev_approved_count,
        SUM(CASE WHEN name_contract_status = 'Refused' THEN 1 ELSE 0 END) AS prev_refused_count
    FROM previous_application
    GROUP BY sk_id_curr
),

installment_summary AS (
    SELECT
        sk_id_curr,
        COUNT(*) AS total_installments,
        SUM(CASE WHEN days_entry_payment > days_instalment THEN 1 ELSE 0 END) AS late_payments_count,
        ROUND(AVG(CASE WHEN days_entry_payment > days_instalment
                  THEN (days_entry_payment - days_instalment) ELSE 0 END)::numeric, 2) AS avg_days_late
    FROM installments_payments
    GROUP BY sk_id_curr
)

SELECT
    a.sk_id_curr,
    a.target,
    a.name_contract_type AS contract_type,
    a.code_gender AS gender,
    a.name_income_type AS income_type,
    a.name_education_type AS education_type,
    a.occupation_type,
    ABS(ROUND((a.days_birth / 365.0)::numeric, 0)) AS age_years,
    a.amt_income_total AS income_total,
    a.amt_credit AS credit_amount,
    a.amt_annuity AS annuity_amount,

    -- risk ratios
    ROUND(((a.amt_annuity / NULLIF(a.amt_income_total, 0)) * 100)::numeric, 2) AS dti_ratio_pct,
    ROUND((a.amt_credit / NULLIF(a.amt_income_total, 0))::numeric, 2) AS credit_to_income_ratio,

    -- bureau / SLIK
    COALESCE(b.total_external_loans, 0) AS total_external_loans,
    COALESCE(b.active_external_loans, 0) AS active_external_loans,
    COALESCE(b.total_external_debt, 0) AS total_external_debt,

    -- previous applications
    COALESCE(p.total_prev_applications, 0) AS total_prev_applications,
    COALESCE(p.prev_approved_count, 0) AS prev_approved_count,
    COALESCE(p.prev_refused_count, 0) AS prev_refused_count,

    -- payment history
    COALESCE(i.total_installments, 0) AS total_installments,
    COALESCE(i.late_payments_count, 0) AS late_payments_count,
    ROUND(((COALESCE(i.late_payments_count, 0) * 100.0) / NULLIF(i.total_installments, 0))::numeric, 2) AS late_payment_rate_pct,
    COALESCE(i.avg_days_late, 0) AS avg_days_late

FROM application_train a
LEFT JOIN bureau_summary b      ON a.sk_id_curr = b.sk_id_curr
LEFT JOIN prev_app_summary p    ON a.sk_id_curr = p.sk_id_curr
LEFT JOIN installment_summary i ON a.sk_id_curr = i.sk_id_curr;


-- 2. Quick check on the portfolio baseline

SELECT
    COUNT(*) AS total_applications,
    SUM(target) AS total_defaults,
    ROUND(AVG(target) * 100, 2) AS default_rate_pct,
    ROUND(SUM(credit_amount)::numeric / 1e9, 2) AS total_credit_bn,
    ROUND(SUM(CASE WHEN target = 1 THEN credit_amount ELSE 0 END)::numeric / 1e9, 2) AS defaulted_exposure_bn,
    ROUND((SUM(CASE WHEN target = 1 THEN credit_amount ELSE 0 END) / SUM(credit_amount))::numeric * 100, 2) AS exposure_rate_pct
FROM master_credit_risk;


-- 3. Early warning signals

-- previous refusals (5+ grouped)
SELECT LEAST(prev_refused_count, 5) AS refusal_bucket,
       COUNT(*) AS apps,
       ROUND(AVG(target) * 100, 2) AS default_rate_pct
FROM master_credit_risk
GROUP BY 1 ORDER BY 1;

-- active bureau loans (8+ grouped)
SELECT LEAST(active_external_loans, 8) AS bureau_bucket,
       COUNT(*) AS apps,
       ROUND(AVG(target) * 100, 2) AS default_rate_pct
FROM master_credit_risk
GROUP BY 1 ORDER BY 1;

-- both signals combined
SELECT
  CASE WHEN prev_refused_count >= 2 THEN 'B. 2+ refusals' ELSE 'A. 0-1 refusals' END AS refusal_group,
  CASE WHEN active_external_loans >= 5 THEN 'B. 5+ active loans' ELSE 'A. 0-4 active loans' END AS bureau_group,
  COUNT(*) AS apps,
  ROUND(AVG(target) * 100, 2) AS default_rate_pct
FROM master_credit_risk
GROUP BY 1, 2
ORDER BY 1, 2;


-- 4. Policy simulation

-- old rule: DTI > 25% and more than 3 late payments
WITH flagged AS (
  SELECT *, (dti_ratio_pct > 25 AND late_payments_count > 3) AS blocked
  FROM master_credit_risk
)
SELECT
  SUM(CASE WHEN blocked THEN 1 ELSE 0 END)                    AS blocked_apps,
  ROUND(AVG(CASE WHEN blocked THEN target END) * 100, 2)      AS blocked_bad_rate_pct,
  SUM(CASE WHEN blocked AND target = 0 THEN 1 ELSE 0 END)     AS good_rejected,
  ROUND(AVG(CASE WHEN NOT blocked THEN target END) * 100, 2)  AS remaining_default_rate_pct
FROM flagged;

-- new rule: 2+ refusals and 5+ active bureau loans
WITH flagged AS (
  SELECT *, (prev_refused_count >= 2 AND active_external_loans >= 5) AS blocked
  FROM master_credit_risk
)
SELECT
  SUM(CASE WHEN blocked THEN 1 ELSE 0 END)                    AS blocked_apps,
  ROUND(AVG(CASE WHEN blocked THEN target END) * 100, 2)      AS blocked_bad_rate_pct,
  SUM(CASE WHEN blocked AND target = 0 THEN 1 ELSE 0 END)     AS good_rejected,
  ROUND(AVG(CASE WHEN NOT blocked THEN target END) * 100, 2)  AS remaining_default_rate_pct
FROM flagged;
