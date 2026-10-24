-- Property Indicator Scorecard - views
-- Overall score, verdict and caps are calculated here from indicator_values and weights,
-- so editing a weight or a score recalculates everything (like the Excel formulas).
--
-- Every evaluation is scored under EVERY lens in `weights` (Rental and Primary).
-- The 12 indicator scores are the same for both lenses; only the weights differ.
-- evaluations.lens is the lens the user asked for (shown as requested_lens).
SET search_path = scorecard;

-- ---------------------------------------------------------------
-- v_scores: one row per evaluation PER LENS with overall score, verdict and caps
-- ---------------------------------------------------------------
CREATE OR REPLACE VIEW v_scores AS
WITH lenses AS (
    SELECT DISTINCT lens FROM weights
),
heaviest AS (       -- the heaviest-weighted indicator per lens (Rental: rent-to-price, Primary: price-to-income)
    SELECT DISTINCT ON (lens) lens, indicator_no AS heaviest_indicator
    FROM weights
    ORDER BY lens, weight DESC, indicator_no
),
agg AS (
    SELECT e.evaluation_id, l.lens,
           sum(iv.score * w.weight) FILTER (WHERE iv.score IS NOT NULL)        AS weighted_sum,
           sum(w.weight)            FILTER (WHERE iv.score IS NOT NULL)        AS weight_with_data,
           count(*)                 FILTER (WHERE iv.score IS NOT NULL)        AS indicators_scored,
           bool_or(iv.indicator_no IN (1,3,8) AND iv.score = 0)                AS zero_on_core,
           string_agg(i.indicator_name, ', ' ORDER BY i.indicator_no)
                FILTER (WHERE iv.indicator_no IN (1,3,8) AND iv.score = 0)     AS zero_core_names
    FROM evaluations e
    CROSS JOIN lenses l
    JOIN weights w           ON w.lens = l.lens
    LEFT JOIN indicator_values iv ON iv.evaluation_id = e.evaluation_id AND iv.indicator_no = w.indicator_no
    JOIN indicators i        ON i.indicator_no = w.indicator_no
    GROUP BY e.evaluation_id, l.lens
),
base AS (
    SELECT e.evaluation_id, e.run_id, e.zip, e.eval_date, e.period_month,
           a.lens, e.lens AS requested_lens,
           e.area_label, e.confidence, e.top_strengths, e.red_flags, e.na_indicators,
           a.indicators_scored,
           round(a.weighted_sum / NULLIF(a.weight_with_data, 0) * 10, 1)       AS overall_score,
           COALESCE(a.zero_on_core, false)                                      AS cap_zero_core,
           a.zero_core_names,
           NOT EXISTS (SELECT 1 FROM indicator_values x
                       WHERE x.evaluation_id = e.evaluation_id
                         AND x.indicator_no = h.heaviest_indicator
                         AND x.score IS NOT NULL)                               AS cap_heaviest_na,
           (e.confidence = 'Low')                                               AS cap_low_confidence,
           h.heaviest_indicator
    FROM evaluations e
    JOIN agg a      ON a.evaluation_id = e.evaluation_id
    JOIN heaviest h ON h.lens = a.lens
)
SELECT b.evaluation_id, b.run_id, b.zip, b.eval_date, b.period_month, b.lens,
       b.area_label, b.confidence, b.indicators_scored, b.overall_score,
       CASE WHEN b.overall_score IS NULL THEN NULL
            WHEN b.overall_score >= (SELECT min_score FROM verdict_thresholds WHERE verdict='Buy')   THEN 'Buy'
            WHEN b.overall_score >= (SELECT min_score FROM verdict_thresholds WHERE verdict='Watch') THEN 'Watch'
            ELSE 'Avoid' END                                                    AS uncapped_verdict,
       CASE WHEN b.overall_score IS NULL THEN NULL
            WHEN b.overall_score >= (SELECT min_score FROM verdict_thresholds WHERE verdict='Buy')
                 AND (b.cap_zero_core OR b.cap_heaviest_na OR b.cap_low_confidence) THEN 'Watch'
            WHEN b.overall_score >= (SELECT min_score FROM verdict_thresholds WHERE verdict='Buy')   THEN 'Buy'
            WHEN b.overall_score >= (SELECT min_score FROM verdict_thresholds WHERE verdict='Watch') THEN 'Watch'
            ELSE 'Avoid' END                                                    AS verdict,
       concat_ws('; ',
            CASE WHEN b.cap_zero_core      THEN 'score of 0 on ' || b.zero_core_names END,
            CASE WHEN b.cap_heaviest_na    THEN 'heaviest indicator for lens is n/a' END,
            CASE WHEN b.cap_low_confidence THEN 'low confidence' END)          AS caps_active,
       b.top_strengths, b.red_flags, b.na_indicators,
       b.requested_lens
FROM base b;

-- ---------------------------------------------------------------
-- v_monthly: latest evaluation per ZIP, month and lens, ranked within
-- the month, with change since the ZIP's previous month
-- ---------------------------------------------------------------
CREATE OR REPLACE VIEW v_monthly AS
WITH latest AS (
    SELECT DISTINCT ON (zip, period_month, lens) *
    FROM v_scores
    ORDER BY zip, period_month, lens, eval_date DESC, evaluation_id DESC
)
SELECT l.period_month, l.lens, l.zip, z.city, z.state, l.area_label,
       l.overall_score, l.verdict, l.confidence,
       rank() OVER (PARTITION BY l.period_month, l.lens ORDER BY l.overall_score DESC NULLS LAST) AS rank_in_month,
       count(*) OVER (PARTITION BY l.period_month, l.lens)                                         AS zips_in_month,
       lag(l.period_month)  OVER w                                                                 AS prev_month,
       lag(l.overall_score) OVER w                                                                 AS prev_overall_score,
       round(l.overall_score - lag(l.overall_score) OVER w, 1)                                     AS score_change,
       lag(l.verdict)       OVER w                                                                 AS prev_verdict,
       (lag(l.verdict) OVER w IS DISTINCT FROM l.verdict AND lag(l.verdict) OVER w IS NOT NULL)    AS verdict_changed,
       l.caps_active, l.red_flags, l.evaluation_id
FROM latest l
JOIN zips z ON z.zip = l.zip
WINDOW w AS (PARTITION BY l.zip, l.lens ORDER BY l.period_month);

-- ---------------------------------------------------------------
-- v_lens_compare: one row per ZIP and month with both lenses side by side
-- ---------------------------------------------------------------
CREATE OR REPLACE VIEW v_lens_compare AS
SELECT r.period_month, r.zip, r.city, r.state,
       r.overall_score AS rental_score,  r.verdict AS rental_verdict,  r.rank_in_month AS rental_rank,
       p.overall_score AS primary_score, p.verdict AS primary_verdict, p.rank_in_month AS primary_rank,
       round(p.overall_score - r.overall_score, 1) AS primary_minus_rental,
       r.evaluation_id
FROM v_monthly r
JOIN v_monthly p ON p.zip = r.zip AND p.period_month = r.period_month
                AND r.lens = 'Rental' AND p.lens = 'Primary';

-- ---------------------------------------------------------------
-- v_indicator_changes: each indicator's score vs the ZIP's previous month
-- (shows which indicators moved). Scores don't depend on the lens, so this
-- uses one row per ZIP and month.
-- ---------------------------------------------------------------
CREATE OR REPLACE VIEW v_indicator_changes AS
WITH m AS (
    SELECT DISTINCT ON (zip, period_month) period_month, zip, evaluation_id
    FROM v_monthly
    ORDER BY zip, period_month, evaluation_id DESC
)
SELECT m.period_month, m.zip, i.indicator_no, i.indicator_name,
       iv.value_text, iv.score,
       lag(iv.value_text) OVER w AS prev_value_text,
       lag(iv.score)      OVER w AS prev_score,
       iv.score - lag(iv.score) OVER w AS score_change
FROM m
JOIN indicator_values iv ON iv.evaluation_id = m.evaluation_id
JOIN indicators i        ON i.indicator_no = iv.indicator_no
WINDOW w AS (PARTITION BY m.zip, iv.indicator_no ORDER BY m.period_month);

-- ---------------------------------------------------------------
-- v_evaluation_wide: one row per evaluation in the Excel tracker's column order,
-- for exporting to a spreadsheet (both lenses' scores and verdicts)
-- ---------------------------------------------------------------
CREATE OR REPLACE VIEW v_evaluation_wide AS
SELECT e.evaluation_id, e.eval_date AS "Date", e.period_month AS "Month", e.input_as_given AS "Input (as given)",
       e.area_label AS "Address / Area", e.lens AS "Requested lens", e.est_monthly_rent AS "Est. monthly rent",
       max(iv.value_text) FILTER (WHERE iv.indicator_no=1)  AS "Job growth value",              max(iv.score) FILTER (WHERE iv.indicator_no=1)  AS "Job growth score",
       max(iv.value_text) FILTER (WHERE iv.indicator_no=2)  AS "Wage growth value",             max(iv.score) FILTER (WHERE iv.indicator_no=2)  AS "Wage growth score",
       max(iv.value_text) FILTER (WHERE iv.indicator_no=3)  AS "Net migration value",           max(iv.score) FILTER (WHERE iv.indicator_no=3)  AS "Net migration score",
       max(iv.value_text) FILTER (WHERE iv.indicator_no=4)  AS "Economic diversity value",      max(iv.score) FILTER (WHERE iv.indicator_no=4)  AS "Economic diversity score",
       max(iv.value_text) FILTER (WHERE iv.indicator_no=5)  AS "Price-to-income value",         max(iv.score) FILTER (WHERE iv.indicator_no=5)  AS "Price-to-income score",
       max(iv.value_text) FILTER (WHERE iv.indicator_no=6)  AS "Days on market value",          max(iv.score) FILTER (WHERE iv.indicator_no=6)  AS "Days on market score",
       max(iv.value_text) FILTER (WHERE iv.indicator_no=7)  AS "Months of supply value",        max(iv.score) FILTER (WHERE iv.indicator_no=7)  AS "Months of supply score",
       max(iv.value_text) FILTER (WHERE iv.indicator_no=8)  AS "Price trend value",             max(iv.score) FILTER (WHERE iv.indicator_no=8)  AS "Price trend score",
       max(iv.value_text) FILTER (WHERE iv.indicator_no=9)  AS "Rent-to-price value",           max(iv.score) FILTER (WHERE iv.indicator_no=9)  AS "Rent-to-price score",
       max(iv.value_text) FILTER (WHERE iv.indicator_no=10) AS "Mortgage-rate stability value", max(iv.score) FILTER (WHERE iv.indicator_no=10) AS "Mortgage-rate stability score",
       max(iv.value_text) FILTER (WHERE iv.indicator_no=11) AS "Infrastructure value",          max(iv.score) FILTER (WHERE iv.indicator_no=11) AS "Infrastructure score",
       max(iv.value_text) FILTER (WHERE iv.indicator_no=12) AS "Active construction value",     max(iv.score) FILTER (WHERE iv.indicator_no=12) AS "Active construction score",
       sr.overall_score AS "Rental score",  sr.verdict AS "Rental verdict",
       sp.overall_score AS "Primary score", sp.verdict AS "Primary verdict",
       e.confidence AS "Confidence",
       e.top_strengths AS "Top strengths", e.red_flags AS "Red flags", e.na_indicators AS "n/a indicators",
       v.rentcast_median_rent AS "RentCast median rent", v.rentcast_rental_listings AS "RentCast rental listings",
       v.rentcast_sale_listings_yoy_pct AS "RentCast sale listings (YoY %)", v.rentcast_sale_median_dom AS "RentCast median DOM (sale)",
       v.notes AS "Validation notes"
FROM evaluations e
LEFT JOIN v_scores sr         ON sr.evaluation_id = e.evaluation_id AND sr.lens = 'Rental'
LEFT JOIN v_scores sp         ON sp.evaluation_id = e.evaluation_id AND sp.lens = 'Primary'
LEFT JOIN indicator_values iv ON iv.evaluation_id = e.evaluation_id
LEFT JOIN validations v       ON v.evaluation_id = e.evaluation_id
GROUP BY e.evaluation_id, sr.overall_score, sr.verdict, sp.overall_score, sp.verdict, v.evaluation_id;

-- ---------------------------------------------------------------
-- v_listings: each listing with its ZIP's latest score and verdict under
-- both lenses (filter listings by ZIP, verdict, or score)
-- ---------------------------------------------------------------
CREATE OR REPLACE VIEW v_listings AS
SELECT l.*, z.city, z.state,
       c.period_month  AS zip_score_month,
       c.rental_score  AS zip_rental_score,  c.rental_verdict  AS zip_rental_verdict,  c.rental_rank  AS zip_rental_rank,
       c.primary_score AS zip_primary_score, c.primary_verdict AS zip_primary_verdict, c.primary_rank AS zip_primary_rank
FROM listings l
JOIN zips z ON z.zip = l.zip
LEFT JOIN LATERAL (
    SELECT * FROM v_lens_compare vc
    WHERE vc.zip = l.zip
    ORDER BY vc.period_month DESC
    LIMIT 1
) c ON true;
