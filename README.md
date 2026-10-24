# Property Scorecard

Scores ZIP codes on 12 market indicators (jobs, wages, migration, affordability, days on market, supply, price trend, rent-to-price, mortgage rates, infrastructure, construction) under two lenses, **Rental** and **Primary home**, and ranks them month by month as Buy / Watch / Avoid.

The evaluations themselves are produced by a Claude skill and stored in Postgres. This repo holds the database schema, the scoring views and the web app. **No evaluation data is stored here**: the hosted app reads it from Supabase after you sign in.

## What's here

| Path | What it is |
|---|---|
| `sql/01_schema_tables.sql` | Tables in schema `scorecard` |
| `sql/02_reference_data.sql` | The 12 indicators, weights for both lenses, verdict thresholds |
| `sql/03_views.sql` | Views that calculate scores, verdicts, caps and monthly rankings (both lenses) |
| `sql/05_useful_queries.sql` | Ready-made queries |
| `sql/06_…`, `sql/07_…` | One-time migrations for databases built before Oct 23–24, 2026 |
| `sql/08_supabase_security_and_api.sql` | Supabase only: row-level security, the email allowlist and the four API functions the hosted app calls |
| `webapp/` | Local app: `python3 webapp/app.py` reads a local Postgres (see `webapp/README.md`) |
| `site/build.py` | Builds the hosted page from `webapp/static/index.html` |
| `docs/index.html` | The hosted page (GitHub Pages serves this folder) |

## Hosted app (GitHub Pages + Supabase)

- Static page, no server. It calls Supabase with the project's public anon key.
- Signed-out visitors get nothing: the API functions are only executable by signed-in users.
- Signed-in users see data only if their email is in `scorecard.app_users` (row-level security on every table). The allowlist itself can't be read through the API.
- Nothing can be written through the web API.

Give someone access (Supabase SQL editor):
```sql
INSERT INTO scorecard.app_users (email, note) VALUES ('person@example.com', 'why');
```
Remove access: `DELETE FROM scorecard.app_users WHERE email = 'person@example.com';`

After changing `webapp/static/index.html`, rebuild the hosted page with `python3 site/build.py` and commit `docs/index.html`.

### Supabase settings
- **Authentication → URL Configuration → Site URL**: the GitHub Pages address, so confirmation emails link back to the app.
- **Authentication → Sign In / Providers → Allow new users to sign up**: turn off once everyone who needs an account has one (the allowlist still protects the data either way).

## Build a database from scratch
```bash
psql "$DATABASE_URL" -f sql/01_schema_tables.sql
psql "$DATABASE_URL" -f sql/02_reference_data.sql
psql "$DATABASE_URL" -f sql/03_views.sql
psql "$DATABASE_URL" -f sql/08_supabase_security_and_api.sql   # Supabase only
```

This is a screening tool, not financial advice.
