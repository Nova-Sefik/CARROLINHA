# Carrolinha

Decision-support prototype for **Hack the City 2026, Challenge #1: Passenger Demand and Mobility Patterns**. It turns one week of TML (Transportes Metropolitanos de Lisboa) ticket validations, 31 August to 6 September 2026, into an interactive explorer of passenger demand, load against capacity, transfers, anomalies and journey paths across the Lisbon metropolitan area. It also includes an AI planning assistant that answers questions from the same data.

## Repository layout

This repository packages two projects, each with its own git history and GitHub remote:

| Folder | What it is | Stack | Remote |
|---|---|---|---|
| [`carrolinha-FE/`](carrolinha-FE) | Lisbon Passenger Flow Explorer (web app) | React 19, Vite, Tailwind CSS, Leaflet, Recharts, h3-js | [Nova-Sefik/carrolina-FE](https://github.com/Nova-Sefik/carrolina-FE) |
| [`carrolinha-BE/`](carrolinha-BE) | Carrolinha API: data aggregates and the AI planner | Python 3.13, FastAPI, DuckDB, H3, OpenAI | [Nova-Sefik/carrolinha-BE](https://github.com/Nova-Sefik/carrolinha-BE) |

Both are git submodules. Clone with `git clone --recursive`, or run `git submodule update --init` in an existing clone.

## How it fits together

```
Browser (carrolinha-FE, :5173)
   │  GET  /api/meta, /api/hex, /api/stops, /api/transfers, /api/journey-traffic, …
   │  POST /api/planner, /api/tools/{name}
   ▼
FastAPI (carrolinha-BE, :8000)
   ├── warehouse.duckdb   stop, line and transfer aggregates, anomalies, golden routes (in git)
   ├── journeys.duckdb    journey paths built from raw validations (not in git, server-side only)
   └── OpenAI             used only by the planner; the key stays in the backend environment
```

The backend computes every number. The frontend only formats and draws what the backend returns. The AI planner calls read-only backend tools, and the browser renders the exact result of the tool that ran, so the model never generates chart values.

## Features

- **Demand**: hourly boardings by H3 area or by stop.
- **Load vs capacity**: line profiles, capacity pressure, and a what-if that re-times trips on the same fleet.
- **Anomalies**: demand that is unusually high or low for that time of day.
- **Transfers**: flows between operators, interchange volumes, and how long people wait to transfer.
- **Best routes**: ranked direct-line opportunities, with projected riders and time saved.
- **Journey paths**: journeys along a directed path (from, through, to), shown as a map, a flow diagram and a list, and compared with a typical day.
- **Stop detail and week overview** (`#/overview`).
- **AI planning workspace** (`#/assistant`): preset graphs, filters and a chat-driven planner.

For more detail, see [`carrolinha-FE/README.md`](carrolinha-FE/README.md). The API contracts are in [`carrolinha-FE/docs/`](carrolinha-FE/docs).

## Getting started

Requirements: Node.js with npm, Python 3.13, and [uv](https://docs.astral.sh/uv/) (or pip).

> **Branch note:** the frontend calls `/api/places`, `/api/journey-traffic`, `/api/compare`, `/api/planner` and `/api/tools/{name}`. These exist only on the backend's `feature/journey-traffic` branch. The backend `main` pinned in this repository serves only the explorer endpoints, so the journey-path views and the AI planner will fail against it. Until that branch is merged, check it out:
>
> ```bash
> git -C carrolinha-BE fetch && git -C carrolinha-BE checkout feature/journey-traffic
> ```

### Quick start: both at once

```bash
./dev.sh
```

`dev.sh` starts the backend, waits until `/api/health` responds, then starts the frontend pointed at it. Ctrl+C stops both.

- **Ports:** it uses the first free port at or above 8000 for the backend and 5173 for the frontend. Set `BE_PORT` or `FE_PORT` to start from a different port (for example `BE_PORT=9000 ./dev.sh`).
- **Frontend env:** it sets `VITE_API_URL` and `VITE_AI_ENDPOINT` to the port the backend actually got. These override whatever is in `carrolinha-FE/.env`, such as the Render URL.
- **Backend env:** it adds the frontend's origin to `CARROLINHA_ALLOWED_ORIGINS`, keeping any value you set, so the planner accepts requests from it. If `OPENAI_API_KEY` or `OPENAI_MODEL` is not in your shell or in `carrolinha-BE/.env`, it takes them from `carrolinha-FE/.env`.
- **Warnings:** it tells you when the backend checkout has no `/api/planner`.
- **First run:** it installs frontend dependencies if they're missing. `uv` syncs the backend automatically.

To start each side by hand instead, follow the two steps below.

### 1. Backend

```bash
cd carrolinha-BE
uv sync                                   # or: python -m venv .venv && .venv/bin/pip install -r requirements.txt
uv run uvicorn app.main:app --reload --port 8000
```

Interactive API docs: <http://localhost:8000/docs>. Health check: <http://localhost:8000/api/health>.

To use the AI planner, create `carrolinha-BE/.env` (it is git-ignored):

```bash
OPENAI_API_KEY=sk-...
```

The journey-path endpoints need `journeys.duckdb`, which is built from the raw validation CSVs and is never committed:

```bash
uv run python pipeline/build_journeys.py "/path/to/validations_part_*.csv"
```

Without it, `/api/journey-traffic` returns `503`.

### 2. Frontend

```bash
cd carrolinha-FE
cp .env.example .env                      # VITE_API_URL=http://localhost:8000
npm install
npm run dev                               # http://localhost:5173
```

Before you push a frontend change, run `npm run lint` and `npm run build`.

## Configuration

Backend environment variables (set them in `carrolinha-BE/.env` locally, or in the Render dashboard):

| Variable | Default | Purpose |
|---|---|---|
| `PULSO_DB` | `warehouse.duckdb` | Path to the aggregate warehouse |
| `CARROLINHA_JOURNEYS` | `journeys.duckdb` | Path to the journey table |
| `CARROLINHA_PRIVACY_MIN` | `10` | Smallest journey count that is ever returned for a path |
| `OPENAI_API_KEY` | none | Turns on the AI planner |
| `OPENAI_MODEL` | set in `app/planner.py` | Model the planner uses |
| `CARROLINHA_ALLOWED_ORIGINS` | `localhost` and `127.0.0.1` on ports 5173 and 5174 | Frontend origins allowed to call `/api/planner` |
| `CARROLINHA_PLANNER_PER_MINUTE` / `_PER_DAY` | `8` / `300` | Planner rate limits |

Frontend environment variables (`carrolinha-FE/.env`):

| Variable | Default | Purpose |
|---|---|---|
| `VITE_API_URL` | `http://localhost:8000` | Backend base URL |
| `VITE_AI_ENDPOINT` | `${VITE_API_URL}/api/planner` | Optional override for the planner URL |

Never put a secret in a `VITE_*` variable, because Vite ships those values to the browser.

## Deployment

The backend includes a Render Blueprint (`carrolinha-BE/render.yaml`). In Render, choose **New → Blueprint** and select the backend repo, then set the secrets in the dashboard. On the free tier the service sleeps after 15 minutes idle, so open `/api/health` a few minutes before a demo to wake it up. The frontend is a static Vite build (`npm run build` writes to `dist/`) and can be hosted anywhere. Point its `VITE_API_URL` at the deployed backend.

## Data and privacy

- The dataset covers a single week (31 Aug to 6 Sep 2026). "Typical" means the median of the same hour on the other days of the same type. With only one week, each weekend day has one comparison day, so weekend comparisons are reported as insufficient.
- Journey paths may be built from only part of the raw files. The backend flags hours that are not fully covered and leaves them out of comparisons.
- Transfers and journeys link taps from the same anonymous card. Groups smaller than the privacy threshold count toward totals but are never shown on their own.
- Capacity values are placeholders. Replace them with vehicle capacities from the operators before any operational use.
- Direct-link opportunities are screening signals, not service recommendations.

## Testing

```bash
cd carrolinha-BE && uv run python -m unittest tests.test_journeys tests.test_golden
cd carrolinha-FE  && npm run lint && npm run build
```

`carrolinha-BE/tests/test_api.py` was written for the old mock data and needs a new fixture before it will pass.
