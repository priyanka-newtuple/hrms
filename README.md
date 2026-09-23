# Newtuple HRMS

Implementation-ready HRMS prototype for Newtuple: React + FastAPI + PostgreSQL,
Google Workspace SSO (restricted to `@newtuple.com`), a data-driven
role/scope/data-profile permission engine based on
`HRMS_Roles_Permissions_Access_Control.xlsx`, and six modules: Employees,
Projects & Allocations, Timesheets, Asset Management, Help Desk, and Employee
Onboarding (with a Flowtuple iframe embed point).

The signed-in landing page is **My Work**, with assigned onboarding actions and
document approvals. HR owns the onboarding module; other participants work through
task-specific pages. See [workflow access and deployment notes](backend/WORKFLOW_ACCESS.md).

## Quick start (local, Docker)

```bash
docker compose up --build
```

This starts Postgres, the FastAPI backend (auto-runs migrations + seeds
sample data on first boot), the Vite dev server, and an Nginx reverse proxy.

- App: http://localhost (via Nginx) or http://localhost:5180 (Vite directly)
- API docs: http://localhost:8010/docs
- Postgres: localhost:5433 (`hrms` / `hrms`)

Ports are deliberately non-default (`8010`, `5180`, `5433`) so this stack
doesn't collide with other local projects — change them back to `8000`/`5173`/`5432`
in `docker-compose.yml` (and `backend/.env`'s URLs) if you'd rather use the
defaults and nothing else is running on them.

On first boot the backend seeds all 8 roles + their full permission matrix,
and ~25 realistic sample employees, projects, timesheets, assets, tickets and
onboarding records. Log in via the **dev-login picker** on the login screen —
no Google OAuth credentials are required for local development.

## Authentication

Two paths, both wired end-to-end:

1. **Google Workspace SSO** (production path) — set `GOOGLE_CLIENT_ID` /
   `GOOGLE_CLIENT_SECRET` in `backend/.env` (create a Web application OAuth
   client in Google Cloud Console; authorized redirect URI = the value of
   `GOOGLE_REDIRECT_URI`). Only `@newtuple.com` accounts are accepted —
   enforced server-side, not just via Google's `hd` hint. A user must already
   have an Employee record (added via HR) before they can sign in.
2. **Dev login** — `POST /api/v1/auth/dev-login {"email": "..."}`, available
   whenever `ENV != production`. The login page lists every seeded user for
   one-click login as any role, so you can exercise the whole permission
   matrix without any external setup.

## CRUD coverage

Employees, Onboarding/Offboarding, Customers, Projects and Allocations have
full create / read / update / archive endpoints plus the relationship-aware
reads that make the entities navigable (`/projects/{id}/allocations`,
`/employees/{id}/capacity`, `/customers/{id}/projects`, …).

**Nothing is ever hard-deleted.** Removal is a status transition — an `EDIT`, so
every `Manage`-level role can archive within its own scope, while the matrix
reserves the literal `Delete` action for Super Admin. Archives are refused when
they'd orphan data: a customer with open projects, or a project with active
allocations, returns 409 with the offending records attached so the UI can show
what to resolve. Allocations are cancelled rather than deleted (there is no
`DELETE /allocations/{id}`; use `POST /allocations/{id}/cancel`).

### Cross-entity rules worth knowing

- **Allocation capacity is a warning, not a block.** Booking someone past 100%
  across overlapping dates succeeds and returns `over_allocated: true` with the
  committed total and the conflicting rows; the UI shows an amber banner. Brief
  overlaps during handovers are legitimate, so the API reports rather than refuses.
- **Double-booking the same person on the same project *is* an error** (409) —
  that's a data-quality bug, not a capacity judgement.
- Allocations must fall inside their project's date window, the employee must not
  be offboarding/offboarded, and the project must be planned or active.
- Reporting lines are cycle-checked; an employee can't manage themselves.
- **Offboarding is gated by a readiness check.**
  `GET /employees/{id}/offboarding-readiness` lists everything needing a human
  decision — projects they manage, direct reports, unreturned assets, unapproved
  timesheets — and `POST /employees/{id}/offboard` refuses (409) until those are
  cleared. On success it end-dates open allocations, records the exit details, and
  **deactivates the login**. Active allocations are deliberately not a blocker;
  they're closed out automatically.

## Authorization model

Every permission grant is `(Action, RecordScope, DataProfile)` — never a
single flag — matching the workbook's "Permission Definitions" sheet exactly.
Grants live in the database (`role_feature_permissions`,
`role_permission_keys`), seeded from `backend/app/seed/permission_matrix.py`,
which documents how each spreadsheet cell was translated, plus the intentional
HR-only onboarding/offboarding module ownership override. The engine
(`backend/app/authz/engine.py`) and its FastAPI dependency
(`require_permission(feature, action)`) and task-level assignment checks enforce access on the server —
the frontend's `usePermission()` hook only mirrors this for UI affordance and
is never trusted on its own.

To change what a role can do, edit `permission_matrix.py` and re-seed — no
code changes needed elsewhere.

`require_permission(feature, action)` answers "may this role do this at all?"
but never sees a record id, so it cannot answer "…on *this* record?". List
endpoints get that second half from `app/authz/scope_filters.py`; single-record
GET/PATCH/archive endpoints must call `assert_in_scope` from
`app/authz/scope_guard.py`, which 404s (not 403s, so existence isn't leaked)
when the row falls outside the caller's scope. On CREATE, `RecordScope` has no
row to test, so the FK being pointed at is checked instead — that's
`assert_project_writable`, which stops a PM allocating people onto another
manager's project. **Any new single-record endpoint needs one of these; without
it the endpoint is an IDOR.**

## Flowtuple integration

Onboarding/Offboarding routes through a `WorkflowProvider` abstraction
(`backend/app/workflows/`). By default it's `NativeWorkflowProvider` (a
simple in-app checklist). Set `FLOWTUPLE_ENABLED=true` and
`FLOWTUPLE_BASE_URL` in `backend/.env` to switch to
`FlowtupleWorkflowProvider`, which builds an iframe embed URL from
employee/workflow context — the frontend (`OnboardingPage.tsx`) already
renders whatever `embed_url` the API returns. Update
`app/workflows/flowtuple.py`'s `status()`/`embed_url()` once Flowtuple's real
API/SSO details are known; no other code needs to change.

## Repository layout

```
backend/    FastAPI app — models, authz engine, services, API routes, seed data, tests
frontend/   React + TypeScript + Tailwind (brand tokens in tailwind.config.ts)
nginx/      Reverse proxy config (dev + prod)
```

See the inline docstrings in `backend/app/authz/`, `backend/app/seed/permission_matrix.py`,
and `backend/app/workflows/` for the reasoning behind key decisions.

## Running tests

```bash
cd backend
pip install -r requirements-dev.txt
DATABASE_URL=postgresql+asyncpg://hrms:hrms@localhost:5432/hrms_test pytest
```

(Point `DATABASE_URL` at a disposable database — tests drop and recreate the
schema. `docker compose up` already gives you a Postgres instance; create a
`hrms_test` database in it, or use CI's ephemeral service container.)

```bash
cd frontend
npm install
npm run lint
npm run build   # includes tsc --noEmit
```

## Production deployment

Production is deployed through GitHub Actions using immutable GHCR images. The
stack listens on a loopback-only port behind the server's existing reverse
proxy, so it does not conflict with other applications on ports 80/443. See
[DEPLOYMENT.md](DEPLOYMENT.md) for the one-time server and GitHub setup, TLS,
secrets, deployment behavior, rollback, and operating commands. After the
GitHub Environment is configured, Windows users can run
`deploy-production.bat` to launch and follow the complete deployment.

## What's intentionally out of scope for this pass

- Real Google OAuth credentials (bring your own; flow is fully wired).
- Real Flowtuple API/SSO details (iframe placeholder + clean extension point).
- A dedicated Expense Management UI/API (permission rows are seeded since the
  spreadsheet defines them, but no module was requested for this pass).
- Exhaustive test coverage, formal security audit, load testing.
