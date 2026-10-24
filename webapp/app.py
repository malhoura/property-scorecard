#!/usr/bin/env python3
"""Property Scorecard web app.

A small local web app over the `scorecard` schema in your Postgres database.
It needs nothing beyond Python 3 and the `psql` command you already use:
no pip installs. Every query runs read-only, so the app can never change data.

Run:   python3 app.py            (opens http://127.0.0.1:8765 in your browser)
Stop:  Ctrl+C in the terminal

Settings (optional environment variables):
  PGHOST (default localhost)  PGPORT (5432)  PGUSER (scorecard_writer)
  PGDATABASE (realestate)     PSQL (path to psql, found automatically)
  PORT (8765)                 NO_BROWSER=1 to skip opening the browser
"""
import json
import os
import re
import shutil
import subprocess
import sys
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

HERE = Path(__file__).resolve().parent
PORT = int(os.environ.get("PORT", "8765"))
DB = {
    "host": os.environ.get("PGHOST", "localhost"),
    "port": os.environ.get("PGPORT", "5432"),
    "user": os.environ.get("PGUSER", "scorecard_writer"),
    "dbname": os.environ.get("PGDATABASE", "realestate"),
}


def find_psql():
    candidates = [
        os.environ.get("PSQL"),
        shutil.which("psql"),
        "/opt/homebrew/bin/psql",
        "/opt/homebrew/opt/postgresql@14/bin/psql",
        "/usr/local/bin/psql",
        "/usr/local/opt/postgresql@14/bin/psql",
        "/Applications/Postgres.app/Contents/Versions/latest/bin/psql",
    ]
    for c in candidates:
        if c and Path(c).is_file() and os.access(c, os.X_OK):
            return c
    return None


PSQL = find_psql()


class DbError(Exception):
    pass


def run(sql, **params):
    """Run one SELECT that returns a single JSON value; return it parsed.

    Parameters are passed as psql variables and referenced in SQL as :'name',
    which psql quotes safely as a literal. The session is read-only.
    """
    if not PSQL:
        raise DbError("Couldn't find the psql command. Set PSQL=/path/to/psql and try again.")
    script = (
        "\\set ON_ERROR_STOP on\n"
        "SET default_transaction_read_only = on;\n"
        "SET search_path = scorecard;\n"
        + sql.strip().rstrip(";") + ";\n"
    )
    cmd = [PSQL, "-X", "-q", "-A", "-t",
           "-h", DB["host"], "-p", DB["port"], "-U", DB["user"], "-d", DB["dbname"]]
    for k, v in params.items():
        cmd += ["-v", f"{k}={v}"]
    try:
        out = subprocess.run(cmd, input=script, capture_output=True, text=True, timeout=30)
    except subprocess.TimeoutExpired:
        raise DbError("The database took more than 30 seconds to answer.")
    if out.returncode != 0:
        msg = " ".join(line.strip() for line in (out.stderr or "").strip().splitlines())
        raise DbError(msg.replace("psql: error: ", "").replace("psql:<stdin>:", "line ") or "psql failed")
    text = out.stdout.strip()
    return json.loads(text) if text else None


# ---------------------------------------------------------------- queries
Q_OVERVIEW = """
SELECT json_build_object(
  'months', (SELECT coalesce(json_agg(m ORDER BY m DESC), '[]'::json)
             FROM (SELECT DISTINCT to_char(period_month, 'YYYY-MM') AS m FROM evaluations) x),
  'lenses', (SELECT coalesce(json_agg(lens ORDER BY lens DESC), '[]'::json) FROM (SELECT DISTINCT lens FROM weights) x),
  'zips', (SELECT count(*) FROM zips),
  'active_zips', (SELECT count(*) FROM zips WHERE active),
  'evaluations', (SELECT count(*) FROM evaluations),
  'listings', (SELECT count(*) FROM listings),
  'db_user', current_user,
  'db_name', current_database())
"""

Q_RANKING = """
WITH m AS (
  SELECT * FROM v_monthly
  WHERE period_month = to_date(:'month', 'YYYY-MM') AND lens = :'lens')
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
      FROM indicators i JOIN weights w ON w.indicator_no = i.indicator_no AND w.lens = :'lens') x),
  'thresholds', (SELECT json_object_agg(verdict, min_score) FROM verdict_thresholds))
"""

Q_ZIP = """
WITH ev AS (
  SELECT m.*, e.est_monthly_rent, e.top_strengths, e.confidence_reason, e.na_indicators,
         e.input_as_given, e.eval_date
  FROM v_monthly m JOIN evaluations e ON e.evaluation_id = m.evaluation_id
  WHERE m.zip = :'zip' AND m.period_month = to_date(:'month', 'YYYY-MM') AND m.lens = :'lens')
SELECT json_build_object(
  'zip', (SELECT row_to_json(z) FROM zips z WHERE z.zip = :'zip'),
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
      FROM v_monthly WHERE zip = :'zip' AND period_month = to_date(:'month', 'YYYY-MM')) x),
  'history', (SELECT coalesce(json_agg(h ORDER BY h.month), '[]'::json) FROM (
      SELECT to_char(period_month, 'YYYY-MM') AS month, overall_score, verdict, rank_in_month, zips_in_month
      FROM v_monthly WHERE zip = :'zip' AND lens = :'lens') h))
"""

Q_LISTINGS = """
SELECT coalesce(json_agg(l ORDER BY l.list_price NULLS LAST), '[]'::json) FROM (
  SELECT listing_id, zip, city, state, address, property_type, list_price, beds, baths, sqft,
         lot_sqft, year_built, hoa_monthly, est_monthly_rent, days_on_market, status, source,
         listing_url, first_seen, last_seen, notes,
         zip_score_month, zip_rental_score, zip_rental_verdict, zip_rental_rank,
         zip_primary_score, zip_primary_verdict, zip_primary_rank,
         CASE WHEN list_price > 0 AND est_monthly_rent IS NOT NULL
              THEN round(est_monthly_rent / list_price * 100, 2) END AS rent_to_price
  FROM v_listings) l
"""

ZIP_RE = re.compile(r"^\d{5}$")
MONTH_RE = re.compile(r"^\d{4}-(0[1-9]|1[0-2])$")
LENSES = {"Rental", "Primary"}


def need(qs, name, check):
    v = (qs.get(name) or [""])[0]
    if not check(v):
        raise ValueError(f"Missing or invalid '{name}'")
    return v


def api(path, qs):
    if path == "/api/overview":
        return run(Q_OVERVIEW)
    if path == "/api/ranking":
        return run(Q_RANKING, month=need(qs, "month", MONTH_RE.match), lens=need(qs, "lens", LENSES.__contains__))
    if path == "/api/zip":
        return run(Q_ZIP, zip=need(qs, "zip", ZIP_RE.match), month=need(qs, "month", MONTH_RE.match),
                   lens=need(qs, "lens", LENSES.__contains__))
    if path == "/api/listings":
        return run(Q_LISTINGS)
    raise LookupError(path)


class Handler(BaseHTTPRequestHandler):
    server_version = "Scorecard/1.0"

    def send(self, code, body, ctype):
        data = body if isinstance(body, bytes) else body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        u = urlparse(self.path)
        if u.path in ("/", "/index.html"):
            return self.send(200, (HERE / "static" / "index.html").read_bytes(), "text/html; charset=utf-8")
        if u.path.startswith("/api/"):
            try:
                result = api(u.path, parse_qs(u.query))
                return self.send(200, json.dumps(result, default=str), "application/json")
            except LookupError:
                return self.send(404, json.dumps({"error": "Unknown address"}), "application/json")
            except ValueError as e:
                return self.send(400, json.dumps({"error": str(e)}), "application/json")
            except DbError as e:
                return self.send(502, json.dumps({"error": str(e)}), "application/json")
        return self.send(404, "Not found", "text/plain")

    def log_message(self, fmt, *args):
        if os.environ.get("VERBOSE"):
            sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))


def main():
    print(f"Property Scorecard  ·  database {DB['dbname']} on {DB['host']}:{DB['port']} as {DB['user']}")
    if not PSQL:
        print("psql not found. Install PostgreSQL's client or set PSQL=/path/to/psql.")
        sys.exit(1)
    try:
        info = run(Q_OVERVIEW)
        print(f"Connected: {info['zips']} ZIPs, {info['evaluations']} evaluations, "
              f"months {', '.join(info['months']) or 'none yet'}")
    except DbError as e:
        print(f"Couldn't reach the database: {e}")
        print("Check that Postgres is running:  brew services list   (start it with: brew services start postgresql@14)")
        sys.exit(1)
    url = f"http://127.0.0.1:{PORT}"
    httpd = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"Open {url}   (Ctrl+C to stop)")
    if not os.environ.get("NO_BROWSER"):
        try:
            webbrowser.open(url)
        except Exception:
            pass
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")


if __name__ == "__main__":
    main()
