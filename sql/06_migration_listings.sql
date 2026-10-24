-- Migration (Oct 23, 2026): move listing details out of evaluations into a new listings table.
-- Already applied to realestate.scorecard. Only needed for a database built before this date;
-- a fresh build from 01-03 already has this layout.
BEGIN;
SET search_path = scorecard;
DROP VIEW IF EXISTS v_listings, v_evaluation_wide, v_indicator_changes, v_monthly, v_scores;
ALTER TABLE evaluations DROP COLUMN IF EXISTS listing_url, DROP COLUMN IF EXISTS list_price, DROP COLUMN IF EXISTS beds_baths_sqft;
CREATE TABLE IF NOT EXISTS listings (
    listing_id         serial PRIMARY KEY,
    zip                text NOT NULL REFERENCES zips(zip),
    listing_url        text UNIQUE,
    address            text,
    property_type      text,             -- Single family, Condo, Townhouse, Multi-family, Land, ...
    list_price         numeric,
    beds               numeric,
    baths              numeric,
    sqft               integer,
    lot_sqft           integer,
    year_built         integer,
    hoa_monthly        numeric,
    est_monthly_rent   numeric,
    days_on_market     integer,
    status             text CHECK (status IN ('Active','Pending','Sold','Off market')),
    source             text,             -- Zillow, Redfin, Realtor.com, RentCast, ...
    first_seen         date NOT NULL DEFAULT current_date,
    last_seen          date,
    notes              text,
    created_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS listings_zip_idx ON listings (zip);
-- Property Indicator Scorecard - views
-- Overall score, verdict and caps are calculated here from indicator_values and weights,
-- so editing a weight or a score recalculates everything (like the Excel formulas).

-- ---------------------------------------------------------------
-- v_scores: one row per evaluation with overall score, verdict and caps
-- ---------------------------------------------------------------
CREATE OR REPLACE VIEW v_scores AS
WITH heaviest AS (       -- the heaviest-weighted indicator per lens (Rental: rent-to-price, Primary: price-to-income)
    SELECT DISTINCT ON (lens) lens, indicator_no AS heaviest_indicator
    FROM weights
    ORDER BY lens, weight DESC, indicator_no
),
agg AS (
    SELECT e.evaluation_id,
           sum(iv.score * w.weight) FILTER (WHERE iv.score IS NOT NULL)        AS weighted_sum,
           sum(w.weight)            FILTER (WHERE iv.score IS NOT NULL)        AS weight_with_data,
           count(*)                 FILTER (WHERE iv.score IS NOT NULL)        AS indicators_scored,
           bool_or(iv.indicator_no IN (1,3,8) AND iv.score = 0)                AS zero_on_core,
           string_agg(i.indicator_name, ', ' ORDER BY i.indicator_no)
                FILTER (WHERE iv.indicator_no IN (1,3,8) AND iv.score = 0)     AS zero_core_names
    FROM evaluations e
    JOIN weights w           ON w.lens = e.lens
    LEFT JOIN indicator_values iv ON iv.evaluation_id = e.evaluation_id AND iv.indicator_no = w.indicator_no
    JOIN indicators i        ON i.indicator_no = w.indicator_no
    GROUP BY e.evaluation_id
),
base AS (
    SELECT e.*,
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
    JOIN heaviest h ON h.lens = e.lens
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
       b.top_strengths, b.red_flags, b.na_indicators
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
-- v_indicator_changes: each indicator's score vs the ZIP's previous month
-- (shows which indicators moved)
-- ---------------------------------------------------------------
CREATE OR REPLACE VIEW v_indicator_changes AS
SELECT m.period_month, m.lens, m.zip, i.indicator_no, i.indicator_name,
       iv.value_text, iv.score,
       lag(iv.value_text) OVER w AS prev_value_text,
       lag(iv.score)      OVER w AS prev_score,
       iv.score - lag(iv.score) OVER w AS score_change
FROM v_monthly m
JOIN indicator_values iv ON iv.evaluation_id = m.evaluation_id
JOIN indicators i        ON i.indicator_no = iv.indicator_no
WINDOW w AS (PARTITION BY m.zip, m.lens, iv.indicator_no ORDER BY m.period_month);

-- ---------------------------------------------------------------
-- v_evaluation_wide: one row per evaluation in the Excel tracker's column order,
-- for exporting to a spreadsheet
-- ---------------------------------------------------------------
CREATE OR REPLACE VIEW v_evaluation_wide AS
SELECT e.evaluation_id, e.eval_date AS "Date", e.period_month AS "Month", e.input_as_given AS "Input (as given)",
       e.area_label AS "Address / Area", e.lens AS "Lens", e.est_monthly_rent AS "Est. monthly rent",
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
       s.overall_score AS "Overall score", s.verdict AS "Verdict", e.confidence AS "Confidence",
       e.top_strengths AS "Top strengths", e.red_flags AS "Red flags", e.na_indicators AS "n/a indicators",
       v.rentcast_median_rent AS "RentCast median rent", v.rentcast_rental_listings AS "RentCast rental listings",
       v.rentcast_sale_listings_yoy_pct AS "RentCast sale listings (YoY %)", v.rentcast_sale_median_dom AS "RentCast median DOM (sale)",
       v.notes AS "Validation notes"
FROM evaluations e
JOIN v_scores s               ON s.evaluation_id = e.evaluation_id
LEFT JOIN indicator_values iv ON iv.evaluation_id = e.evaluation_id
LEFT JOIN validations v       ON v.evaluation_id = e.evaluation_id
GROUP BY e.evaluation_id, s.overall_score, s.verdict, v.evaluation_id;

-- ---------------------------------------------------------------
-- v_listings: each listing with its ZIP's latest score and verdict
-- (filter listings by ZIP, verdict, or score)
-- ---------------------------------------------------------------
CREATE OR REPLACE VIEW v_listings AS
SELECT l.*, z.city, z.state,
       m.period_month AS zip_score_month, m.lens AS zip_lens,
       m.overall_score AS zip_overall_score, m.verdict AS zip_verdict, m.rank_in_month AS zip_rank_in_month
FROM listings l
JOIN zips z ON z.zip = l.zip
LEFT JOIN LATERAL (
    SELECT * FROM v_monthly vm
    WHERE vm.zip = l.zip
    ORDER BY vm.period_month DESC, (vm.lens = COALESCE(z.default_lens, 'Rental')) DESC
    LIMIT 1
) m ON true;

COMMIT;
