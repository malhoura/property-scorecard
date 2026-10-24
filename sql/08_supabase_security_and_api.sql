-- Supabase only: security and the web app's API (run after 01-03).
--
-- * Views run with the caller's permissions (security_invoker), so row-level
--   security on the tables applies to them.
-- * Signed-in users can READ, and only if their email is in scorecard.app_users.
--   Nobody can write through the web API; the skill writes with the database
--   connection (Supabase connector), which bypasses these rules.
-- * The web app calls four functions in the public schema (exposed by Supabase's
--   REST API as /rest/v1/rpc/<name>): app_overview, app_ranking, app_zip, app_listings.

-- ---------------------------------------------------------------- allowlist
CREATE TABLE IF NOT EXISTS scorecard.app_users (
    email     text PRIMARY KEY CHECK (email = lower(email)),
    added_at  timestamptz NOT NULL DEFAULT now(),
    note      text
);
ALTER TABLE scorecard.app_users ENABLE ROW LEVEL SECURITY;   -- no policies: not readable through the API

CREATE OR REPLACE FUNCTION scorecard.is_app_user()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM scorecard.app_users u
    WHERE u.email = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;
REVOKE ALL ON FUNCTION scorecard.is_app_user() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION scorecard.is_app_user() TO authenticated;

-- ---------------------------------------------------------------- views run as the caller
ALTER VIEW scorecard.v_scores            SET (security_invoker = true);
ALTER VIEW scorecard.v_monthly           SET (security_invoker = true);
ALTER VIEW scorecard.v_lens_compare      SET (security_invoker = true);
ALTER VIEW scorecard.v_indicator_changes SET (security_invoker = true);
ALTER VIEW scorecard.v_evaluation_wide   SET (security_invoker = true);
ALTER VIEW scorecard.v_listings          SET (security_invoker = true);

-- ---------------------------------------------------------------- row-level security: read-only for allowlisted users
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['indicators','weights','verdict_thresholds','zips','runs','evaluations',
                           'listings','indicator_values','sources','validations']
  LOOP
    EXECUTE format('ALTER TABLE scorecard.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS app_users_read ON scorecard.%I', t);
    EXECUTE format('CREATE POLICY app_users_read ON scorecard.%I FOR SELECT TO authenticated USING ((SELECT scorecard.is_app_user()))', t);
  END LOOP;
END $$;

REVOKE ALL ON SCHEMA scorecard FROM anon;
REVOKE ALL ON ALL TABLES IN SCHEMA scorecard FROM anon;
GRANT USAGE ON SCHEMA scorecard TO authenticated;
GRANT SELECT ON ALL TABLES IN SCHEMA scorecard TO authenticated;   -- tables and views; rows still filtered by RLS
REVOKE SELECT ON scorecard.app_users FROM authenticated;

-- ---------------------------------------------------------------- API functions (same queries as webapp/app.py)
CREATE OR REPLACE FUNCTION public.app_overview()
RETURNS json LANGUAGE sql STABLE SECURITY INVOKER
SET search_path = scorecard, public
AS $$
SELECT json_build_object(
  'allowed', scorecard.is_app_user(),
  'months', (SELECT coalesce(json_agg(m ORDER BY m DESC), '[]'::json)
             FROM (SELECT DISTINCT to_char(period_month, 'YYYY-MM') AS m FROM evaluations) x),
  'lenses', (SELECT coalesce(json_agg(lens ORDER BY lens DESC), '[]'::json) FROM (SELECT DISTINCT lens FROM weights) x),
  'zips', (SELECT count(*) FROM zips),
  'active_zips', (SELECT count(*) FROM zips WHERE active),
  'evaluations', (SELECT count(*) FROM evaluations),
  'listings', (SELECT count(*) FROM listings),
  'db_user', coalesce(auth.jwt() ->> 'email', current_user),
  'db_name', 'Supabase');
$$;

CREATE OR REPLACE FUNCTION public.app_ranking(p_month text, p_lens text)
RETURNS json LANGUAGE sql STABLE SECURITY INVOKER
SET search_path = scorecard, public
AS $$
WITH m AS (
  SELECT * FROM v_monthly
  WHERE period_month = to_date(p_month, 'YYYY-MM') AND lens = p_lens)
SELECT json_build_object(
  'rows', (SELECT coalesce(json_agg(t ORDER BY t.rank_in_month, t.zip), '[]'::json) FROM (
      SELECT m.zip, m.city, m.state, m.overall_score, m.verdict, m.confidence, m.rank_in_month,
             m.zips_in_month, to_char(m.prev_month, 'YYYY-MM') AS prev_month, m.prev_overall_score,
             m.score_change, m.prev_verdict, m.verdict_changed, NULLIF(m.caps_active, '') AS caps_active,
             m.evaluation_id, e.est_monthly_rent, z.county_name, z.town_mode, z.active,
             o.lens AS other_lens, o.overall_score AS other_score, o.verdict AS other_verdict, o.rank_in_month AS other_rank,
             (SELECT count(*) FROM listings l WHERE l.zip = m.zip AND l.status = 'Active') AS active_listings
      FROM m JOIN evaluations e ON e.evaluation_id = m.evaluation_id JOIN zips z ON z.zip = m.zip
      LEFT JOIN v_monthly o ON o.zip = m.zip AND o.period_month = m.period_month AND o.lens <> m.lens) t),
  'grid', (SELECT coalesce(json_agg(g), '[]'::json) FROM (
      SELECT m.zip, iv.indicator_no, iv.score, iv.value_text
      FROM m JOIN indicator_values iv ON iv.evaluation_id = m.evaluation_id) g),
  'indicators', (SELECT coalesce(json_agg(x ORDER BY x.indicator_no), '[]'::json) FROM (
      SELECT i.indicator_no, i.indicator_name, w.weight
      FROM indicators i JOIN weights w ON w.indicator_no = i.indicator_no AND w.lens = p_lens) x),
  'thresholds', (SELECT json_object_agg(verdict, min_score) FROM verdict_thresholds));
$$;

CREATE OR REPLACE FUNCTION public.app_zip(p_zip text, p_month text, p_lens text)
RETURNS json LANGUAGE sql STABLE SECURITY INVOKER
SET search_path = scorecard, public
AS $$
WITH ev AS (
  SELECT m.*, e.est_monthly_rent, e.top_strengths, e.confidence_reason, e.na_indicators,
         e.input_as_given, e.eval_date
  FROM v_monthly m JOIN evaluations e ON e.evaluation_id = m.evaluation_id
  WHERE m.zip = p_zip AND m.period_month = to_date(p_month, 'YYYY-MM') AND m.lens = p_lens)
SELECT json_build_object(
  'zip', (SELECT row_to_json(z) FROM zips z WHERE z.zip = p_zip),
  'evaluation', (SELECT row_to_json(ev) FROM ev),
  'indicators', (SELECT coalesce(json_agg(t ORDER BY t.indicator_no), '[]'::json) FROM (
      SELECT iv.indicator_no, i.indicator_name, iv.value_text, iv.value_num, iv.unit, iv.score,
             iv.geography_level, iv.period_label, w.weight, c.prev_score, c.score_change,
             (SELECT x.weight FROM weights x WHERE x.lens = 'Rental'  AND x.indicator_no = iv.indicator_no) AS rental_weight,
             (SELECT x.weight FROM weights x WHERE x.lens = 'Primary' AND x.indicator_no = iv.indicator_no) AS primary_weight
      FROM ev
      JOIN indicator_values iv ON iv.evaluation_id = ev.evaluation_id
      JOIN indicators i ON i.indicator_no = iv.indicator_no
      JOIN weights w ON w.lens = ev.lens AND w.indicator_no = iv.indicator_no
      LEFT JOIN v_indicator_changes c ON c.zip = ev.zip
           AND c.period_month = ev.period_month AND c.indicator_no = iv.indicator_no) t),
  'sources', (SELECT coalesce(json_agg(s ORDER BY s.indicator_no NULLS LAST, s.source_id), '[]'::json) FROM (
      SELECT s.source_id, s.indicator_no, s.indicator_label, s.value_text, s.geography_level,
             s.period_label, s.source_title, s.source_tier, s.url
      FROM sources s JOIN ev ON ev.evaluation_id = s.evaluation_id) s),
  'validation', (SELECT row_to_json(v) FROM validations v JOIN ev ON ev.evaluation_id = v.evaluation_id),
  'lenses', (SELECT coalesce(json_agg(x ORDER BY x.lens DESC), '[]'::json) FROM (
      SELECT lens, overall_score, verdict, rank_in_month, zips_in_month, NULLIF(caps_active, '') AS caps_active
      FROM v_monthly WHERE zip = p_zip AND period_month = to_date(p_month, 'YYYY-MM')) x),
  'history', (SELECT coalesce(json_agg(h ORDER BY h.month), '[]'::json) FROM (
      SELECT to_char(period_month, 'YYYY-MM') AS month, overall_score, verdict, rank_in_month, zips_in_month
      FROM v_monthly WHERE zip = p_zip AND lens = p_lens) h));
$$;

CREATE OR REPLACE FUNCTION public.app_listings()
RETURNS json LANGUAGE sql STABLE SECURITY INVOKER
SET search_path = scorecard, public
AS $$
SELECT coalesce(json_agg(l ORDER BY l.list_price NULLS LAST), '[]'::json) FROM (
  SELECT listing_id, zip, city, state, address, property_type, list_price, beds, baths, sqft,
         lot_sqft, year_built, hoa_monthly, est_monthly_rent, days_on_market, status, source,
         listing_url, first_seen, last_seen, notes,
         zip_score_month, zip_rental_score, zip_rental_verdict, zip_rental_rank,
         zip_primary_score, zip_primary_verdict, zip_primary_rank,
         CASE WHEN list_price > 0 AND est_monthly_rent IS NOT NULL
              THEN round(est_monthly_rent / list_price * 100, 2) END AS rent_to_price
  FROM v_listings) l;
$$;

REVOKE ALL ON FUNCTION public.app_overview()                 FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.app_ranking(text, text)        FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.app_zip(text, text, text)      FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.app_listings()                 FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.app_overview()              TO authenticated;
GRANT EXECUTE ON FUNCTION public.app_ranking(text, text)     TO authenticated;
GRANT EXECUTE ON FUNCTION public.app_zip(text, text, text)   TO authenticated;
GRANT EXECUTE ON FUNCTION public.app_listings()              TO authenticated;
