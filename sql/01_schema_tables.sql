-- Property Indicator Scorecard - tables
-- Database: realestate   Schema: scorecard   Owner: scorecard_writer
-- Safe to re-run: every object is created only if missing.

SET search_path = scorecard;

-- ---------------------------------------------------------------
-- Reference: the 12 indicators
-- ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS indicators (
    indicator_no   smallint PRIMARY KEY CHECK (indicator_no BETWEEN 1 AND 12),
    indicator_key  text NOT NULL UNIQUE,
    indicator_name text NOT NULL,
    scoring_bands  text
);

-- ---------------------------------------------------------------
-- Weights per lens (edit these to retune; views recalculate)
-- ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS weights (
    lens         text     NOT NULL CHECK (lens IN ('Rental','Primary')),
    indicator_no smallint NOT NULL REFERENCES indicators(indicator_no),
    weight       numeric  NOT NULL CHECK (weight >= 0),
    PRIMARY KEY (lens, indicator_no)
);

-- ---------------------------------------------------------------
-- Verdict thresholds (Buy if overall >= 70, Watch if >= 50, else Avoid)
-- ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS verdict_thresholds (
    verdict   text PRIMARY KEY CHECK (verdict IN ('Buy','Watch')),
    min_score numeric NOT NULL
);

-- ---------------------------------------------------------------
-- ZIP registry: resolved once, reused every month.
-- Adding an active row here adds the ZIP to scheduled runs.
-- ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS zips (
    zip                     text PRIMARY KEY CHECK (zip ~ '^[0-9]{5}$'),
    city                    text,
    state                   text,
    county_name             text,
    county_fips             text CHECK (county_fips ~ '^[0-9]{5}$'),
    cbsa_code               text,
    cbsa_name               text,
    town_mode               boolean NOT NULL DEFAULT false,
    town_name               text,
    quickfacts_town_slug    text,
    default_lens            text CHECK (default_lens IN ('Rental','Primary')),
    zillow_home_values_url  text,
    zillow_rental_url       text,
    bls_eag_url             text,
    fred_series             jsonb NOT NULL DEFAULT '{}'::jsonb,  -- e.g. {"dom":"MEDDAYONMAR1101","unemployment":"ALMONT1URN"}
    active                  boolean NOT NULL DEFAULT true,
    added_at                timestamptz NOT NULL DEFAULT now(),
    notes                   text
);

-- ---------------------------------------------------------------
-- One row per batch run
-- ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS runs (
    run_id             serial PRIMARY KEY,
    run_date           date NOT NULL DEFAULT current_date,
    started_at         timestamptz NOT NULL DEFAULT now(),
    finished_at        timestamptz,
    zips_planned       integer,
    zips_completed     integer,
    firecrawl_credits  integer,
    exa_searches       integer,
    rentcast_requests  integer,
    notes              text
);

-- ---------------------------------------------------------------
-- One row per ZIP evaluation (a re-run in the same month adds a new
-- row; the monthly view uses the latest one per ZIP, month and lens)
-- ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS evaluations (
    evaluation_id      serial PRIMARY KEY,
    run_id             integer REFERENCES runs(run_id) ON DELETE SET NULL,
    zip                text NOT NULL REFERENCES zips(zip),
    eval_date          date NOT NULL DEFAULT current_date,
    period_month       date NOT NULL,          -- first day of the month the row represents
    lens               text NOT NULL CHECK (lens IN ('Rental','Primary')),
    input_as_given     text,
    area_label         text,
    est_monthly_rent   numeric,
    confidence         text NOT NULL CHECK (confidence IN ('High','Medium','Low')),
    confidence_reason  text,
    top_strengths      text,
    red_flags          text,
    na_indicators      text,
    created_at         timestamptz NOT NULL DEFAULT now(),
    CHECK (period_month = date_trunc('month', period_month)::date)
);
CREATE INDEX IF NOT EXISTS evaluations_zip_month_idx ON evaluations (zip, period_month, lens);

-- ---------------------------------------------------------------
-- One row per individual listing (for-sale property), tied to a ZIP
-- in zips so listings can be filtered by ZIP and by the ZIP's score
-- ---------------------------------------------------------------
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

-- ---------------------------------------------------------------
-- One row per indicator per evaluation. score NULL = n/a.
-- ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS indicator_values (
    evaluation_id    integer  NOT NULL REFERENCES evaluations(evaluation_id) ON DELETE CASCADE,
    indicator_no     smallint NOT NULL REFERENCES indicators(indicator_no),
    value_text       text,              -- the human-readable value cell, with units
    value_num        numeric,           -- the main number used for scoring, when there is one
    unit             text,
    score            numeric CHECK (score IS NULL OR score BETWEEN 0 AND 10),
    geography_level  text,
    period_label     text,
    PRIMARY KEY (evaluation_id, indicator_no)
);

-- ---------------------------------------------------------------
-- One row per figure, with its source (mirrors the Sources sheet)
-- ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sources (
    source_id        serial PRIMARY KEY,
    evaluation_id    integer NOT NULL REFERENCES evaluations(evaluation_id) ON DELETE CASCADE,
    indicator_no     smallint REFERENCES indicators(indicator_no),   -- NULL for shared/other lines
    indicator_label  text NOT NULL,
    value_text       text,
    geography_level  text,
    period_label     text,
    source_title     text,
    source_tier      text CHECK (source_tier IN ('Primary','Backup','Open search','Validation')),
    url              text
);
CREATE INDEX IF NOT EXISTS sources_eval_idx ON sources (evaluation_id);

-- ---------------------------------------------------------------
-- RentCast validation, one row per evaluation
-- ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS validations (
    evaluation_id                  integer PRIMARY KEY REFERENCES evaluations(evaluation_id) ON DELETE CASCADE,
    rentcast_last_updated          date,
    rentcast_median_rent           numeric,
    rentcast_average_rent          numeric,
    rentcast_rental_listings       integer,
    rentcast_rental_median_dom     numeric,
    rentcast_median_rent_yoy_pct   numeric,
    rentcast_sale_listings         integer,
    rentcast_sale_listings_yoy_pct numeric,
    rentcast_sale_median_dom       numeric,
    rentcast_median_list_price     numeric,
    flags                          text[] NOT NULL DEFAULT '{}',
    notes                          text,
    skipped_reason                 text
);
