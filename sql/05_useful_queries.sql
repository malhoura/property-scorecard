-- Useful queries for the property scorecard
-- Run with:  psql -h localhost -U scorecard_writer -d realestate -f this_file.sql
-- or paste one at a time into psql.
SET search_path = scorecard;

-- 1. This month's ranking (change the month and lens as needed)
SELECT rank_in_month, zip, city, state, overall_score, verdict, confidence,
       score_change, prev_verdict, verdict_changed, caps_active
FROM v_monthly
WHERE period_month = date_trunc('month', current_date)::date AND lens = 'Rental'
ORDER BY rank_in_month;

-- 2. One ZIP's history, month by month
SELECT period_month, overall_score, verdict, confidence, score_change
FROM v_monthly WHERE zip = '36116' AND lens = 'Rental' ORDER BY period_month;

-- 3. Which indicators moved for a ZIP since last month
SELECT indicator_name, prev_score, score, score_change, prev_value_text, value_text
FROM v_indicator_changes
WHERE zip = '36116' AND period_month = date_trunc('month', current_date)::date
  AND score_change IS DISTINCT FROM 0
ORDER BY abs(score_change) DESC NULLS LAST;

-- 4. Verdict changes this month (e.g. Watch -> Buy)
SELECT zip, city, prev_verdict, verdict, prev_overall_score, overall_score
FROM v_monthly
WHERE period_month = date_trunc('month', current_date)::date AND verdict_changed;

-- 5. Every source behind one evaluation
SELECT i.indicator_name, s.value_text, s.geography_level, s.period_label, s.source_tier, s.url
FROM sources s LEFT JOIN indicators i USING (indicator_no)
WHERE s.evaluation_id = 2 ORDER BY s.indicator_no NULLS LAST, s.source_id;

-- 6. RentCast validation flags this month
SELECT e.zip, v.flags, v.notes
FROM validations v JOIN evaluations e USING (evaluation_id)
WHERE e.period_month = date_trunc('month', current_date)::date AND cardinality(v.flags) > 0;

-- 7. Add a ZIP to the monthly schedule (the skill fills in the rest on its first run)
-- INSERT INTO zips (zip, city, state, default_lens) VALUES ('30310', 'Atlanta', 'GA', 'Rental');

-- 8. Pause a ZIP without deleting its history
-- UPDATE zips SET active = false WHERE zip = '60610';

-- 9. Try different weights (every score and verdict recalculates)
-- UPDATE weights SET weight = 25 WHERE lens = 'Rental' AND indicator_no = 9;   -- rent-to-price
-- SELECT lens, sum(weight) FROM weights GROUP BY lens;                          -- check totals (renormalized anyway)

-- 11. All 12 indicators for one ZIP and month (value, number, unit, score)
SELECT i.indicator_no, i.indicator_name, iv.value_text, iv.value_num, iv.unit, iv.score,
       iv.geography_level, iv.period_label
FROM indicator_values iv JOIN indicators i USING (indicator_no)
JOIN evaluations e USING (evaluation_id)
WHERE e.zip = '60610' AND e.period_month = '2026-10-01'
ORDER BY i.indicator_no;

-- 12. The whole month in spreadsheet layout (one row per ZIP, a value + score column per indicator)
SELECT * FROM v_evaluation_wide WHERE "Month" = '2026-10-01';

-- 13. Listings in ZIPs rated Buy or Watch (Rental lens), cheapest first
SELECT zip, city, address, list_price, beds, baths, sqft, est_monthly_rent,
       zip_rental_score, zip_rental_verdict, zip_primary_score, zip_primary_verdict, listing_url
FROM v_listings
WHERE status = 'Active' AND zip_rental_verdict IN ('Buy','Watch')   -- or zip_primary_verdict
ORDER BY list_price;

-- 14. Add a listing (the ZIP must already be in zips)
-- INSERT INTO listings (zip, listing_url, address, property_type, list_price, beds, baths, sqft, status, source)
-- VALUES ('36116', 'https://www.zillow.com/homedetails/...', '123 Main St', 'Single family', 150000, 3, 2, 1400, 'Active', 'Zillow');

-- 15. Both lenses side by side for a month (biggest gap first: good homes that are poor rentals, or the reverse)
SELECT zip, city, rental_score, rental_verdict, rental_rank, primary_score, primary_verdict, primary_rank, primary_minus_rental
FROM v_lens_compare WHERE period_month = '2026-10-01'
ORDER BY abs(primary_minus_rental) DESC;

-- 10. Credits and requests used per run
SELECT run_id, run_date, zips_completed, firecrawl_credits, exa_searches, rentcast_requests, notes
FROM runs ORDER BY run_id DESC;
