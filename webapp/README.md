# Property Scorecard web app

A local web app for browsing your scorecard database: the monthly ZIP ranking, each ZIP's 12 indicators, score history, sources, RentCast checks and saved listings. It reads straight from Postgres, so it always shows the latest saved results. It is read-only: it can't change anything in the database.

## Start it

In Terminal:

```bash
cd ~/Documents/"Cowork Playground"/property-scorecard/webapp
python3 app.py
```

Your browser opens at http://127.0.0.1:8765. Leave the Terminal window open while you use the app, and press Ctrl+C there to stop it.

Or double-click `start.command` in Finder. The first time, macOS may block it: right-click it, choose Open, then Open again. If it says it isn't executable, run `chmod +x start.command` once in this folder.

## What you need

- Python 3 (built into macOS with the developer tools; `python3 --version` checks)
- Postgres running with the `realestate` database (`brew services list` shows it; `brew services start postgresql@14` starts it)
- The `psql` command, which comes with Postgres. Nothing to install with pip.

## What's in it

- **ZIP ranking**: pick a month and which lens to rank by. Every ZIP is scored under both lenses, so the table also shows the other lens's score and verdict, and the ZIP detail shows both side by side. Summary tiles, a sortable and searchable ranking with each ZIP's change since its previous month, and a grid of all 12 indicator scores.
- **ZIP detail** (click any ZIP): score history by month, strengths and red flags, the 12 indicators with values, geography, period and month-over-month change, the RentCast check, every source, and links to the ZIP's Zillow and BLS pages.
- **Indicator guide**: hover any indicator name for what it measures and which values count as excellent, good or bad; click it to jump to its full scale, with the selected ZIP's position marked.
- **Listings**: every saved listing with its ZIP's score. Filter by ZIP verdict, status, max price and min beds; sort any column.

## Settings

Defaults match your setup. Override with environment variables if anything changes, e.g. `PORT=9000 python3 app.py`.

| Variable | Default |
|---|---|
| `PGHOST` / `PGPORT` | `localhost` / `5432` |
| `PGUSER` | `scorecard_writer` |
| `PGDATABASE` | `realestate` |
| `PSQL` | found automatically (Homebrew paths included) |
| `PORT` | `8765` |
| `NO_BROWSER=1` | don't open the browser on start |

The app only listens on your own computer (127.0.0.1), so nobody else on your network can open it.

## Files

| File | What it is |
|---|---|
| `app.py` | The server. Runs fixed, read-only SQL through `psql` and serves the page |
| `static/index.html` | The page (no internet needed; nothing loads from outside) |
| `start.command` | Double-click launcher for macOS |
