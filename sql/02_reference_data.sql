-- Property Indicator Scorecard - reference data (indicators, weights, thresholds)
-- Safe to re-run: existing rows are left untouched (edit weights with UPDATE).
SET search_path = scorecard;

INSERT INTO indicators (indicator_no, indicator_key, indicator_name, scoring_bands) VALUES
 (1,  'job_growth',          'Job growth',              '>=3% 10 | 2-3% 8 | 1-2% 6 | 0-1% 4 | -1-0% 2 | <-1% 0; -1 if local unemployment > US by >1 pt (same month, NSA)'),
 (2,  'wage_growth',         'Wage growth',             '>=5% 10 | 4-5% 8 | 3-4% 6 | 2-3% 4 | 0-2% 2 | <0 0'),
 (3,  'net_migration',       'Net migration',           'per 1,000: >=10 10 | 5-10 8 | 2-5 6 | 0-2 4 | -2-0 2 | <-2 0; town mode +/-2'),
 (4,  'economic_diversity',  'Economic diversity',      'largest supersector share: <=15% 10 | 15-20% 8 | 20-25% 6 | 25-35% 4 | 35-50% 2 | >50% 0; -2 if one employer >10%'),
 (5,  'price_to_income',     'Price-to-income',         '<=3 10 | 3-4 8 | 4-5 6 | 5-6 4 | 6-8 2 | >8 0'),
 (6,  'days_on_market',      'Days on market',          '<=20 10 | 21-30 8 | 31-45 6 | 46-60 4 | 61-90 2 | >90 0; -2 if up >25% YoY, +1 if down >10% YoY'),
 (7,  'months_of_supply',    'Months of supply',        '4-6 10 | 3-4 8 | 6-7 7 | 2-3 6 | 7-9 4 | <2 4 | >9 1'),
 (8,  'price_trend',         'Price trend',             'long-run CAGR: 3-7% 10 | 2-3% or 7-9% 7 | 0-2% 4 | 9-12% 4 | <0 1 | >12% 1; -3 parabolic, -2 if ZIP ZHVI 1-yr < -5%'),
 (9,  'rent_to_price',       'Rent-to-price',           'monthly gross: >=1.0% 10 | 0.8-1.0% 8 | 0.7-0.8% 6 | 0.6-0.7% 4 | 0.5-0.6% 2 | <0.5% 0'),
 (10, 'mortgage_stability',  'Mortgage-rate stability', '12-mo range: <=0.50 10 | 0.50-0.75 8 | 0.75-1.00 6 | 1.00-1.50 4 | 1.50-2.00 2 | >2.00 0'),
 (11, 'infrastructure',      'Infrastructure',          '3+ funded/under construction 10 | 2 8 | 1 6 | proposed only 4 | none 2 | negative signals 0'),
 (12, 'active_construction', 'Active construction',     'permits per 1,000: 6-10 10 | 4-6 or 10-14 8 | 2-4 6 | >14 5 | 1-2 3 | <1 1')
ON CONFLICT (indicator_no) DO NOTHING;

INSERT INTO weights (lens, indicator_no, weight) VALUES
 ('Rental',1,12),('Rental',2,6),('Rental',3,12),('Rental',4,8),('Rental',5,6),('Rental',6,6),
 ('Rental',7,6),('Rental',8,8),('Rental',9,20),('Rental',10,4),('Rental',11,6),('Rental',12,6),
 ('Primary',1,10),('Primary',2,8),('Primary',3,8),('Primary',4,8),('Primary',5,18),('Primary',6,6),
 ('Primary',7,8),('Primary',8,14),('Primary',9,4),('Primary',10,6),('Primary',11,6),('Primary',12,4)
ON CONFLICT (lens, indicator_no) DO NOTHING;

INSERT INTO verdict_thresholds (verdict, min_score) VALUES ('Buy',70), ('Watch',50)
ON CONFLICT (verdict) DO NOTHING;
