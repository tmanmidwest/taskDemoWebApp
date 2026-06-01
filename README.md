# TaskFlow — taskDemoWebApp

A small multi-role **task-management** web app, built as a clean provisioning
target for **Saviynt IAM** demos. It exists so you can show Saviynt's AI browser
agent onboarding a web-only application: creating, updating, disabling, and
removing users — either through the web UI or through a built-in REST API.

It is deliberately simple: FastAPI + server-rendered HTML + SQLite, packaged in
a single container. The UI uses plain, stable, semantic HTML with predictable
routes and stable element IDs so a browser-automation agent can navigate it
reliably.

---

## What it does

- **Login** with username + password (sessions via signed cookies).
- **Dashboard** (`/dashboard`) — the logged-in user's own assigned tasks.
- **Tasks** (`/tasks`) — create, assign, edit, change status, delete (role-gated).
- **Users** (`/users`) — full user lifecycle for Administrators.
- **REST provisioning API** (`/api/users`) — for connector-style integrations,
  auto-documented at `/docs`.
- **Default administrator** seeded automatically on first boot.

When adding a user you only need **first name**, **last name**, and **email**.
A username is derived from the email local-part (de-duplicated if needed) and a
temporary password is generated and surfaced. The model is intentionally easy to
extend with more fields later.

---

## Roles

| Role | Can do |
|---|---|
| **Administrator** | Full user management (create / update / disable / delete) + all tasks |
| **Manager** | View all tasks, create and assign tasks, view users (read-only) |
| **Sales Rep** | See and update only their own assigned tasks |
| **Technical Support** | See and update only their own assigned tasks |

A safety guard prevents deleting, demoting, or deactivating the **last active
Administrator**, so a demo can't lock itself out.

---

## Run locally

```bash
pip install -r requirements.txt
python -m app.main
```

Then open http://localhost:8000/. Default login:

| Field | Value |
|---|---|
| Username | `robbytheadmin` |
| Password | `N0nPr0dF0r$@viynt8` |

Set `TASKAPP_SEED_SAMPLE=true` to also seed a few sample users and tasks.

## Run with Docker

```bash
docker build -t taskflow .
docker run -p 8000:8000 -v "$PWD/data:/data" taskflow
```

The SQLite database lives at `TASKAPP_DB_PATH` (default `/data/taskflow.db`), so
mounting `/data` persists data across restarts.

---

## Configuration (environment variables)

| Variable | Default | Purpose |
|---|---|---|
| `TASKAPP_BIND_HOST` | `0.0.0.0` | Bind address |
| `TASKAPP_BIND_PORT` | `8000` | Port |
| `TASKAPP_DB_PATH` | `/data/taskflow.db` | SQLite file location |
| `TASKAPP_LOG_LEVEL` | `INFO` | Log verbosity |
| `TASKAPP_SECRET_KEY` | (dev default) | Session-cookie signing key — set a real value in production |
| `TASKAPP_ADMIN_USERNAME` | `robbytheadmin` | Seeded admin username |
| `TASKAPP_ADMIN_PASSWORD` | `N0nPr0dF0r$@viynt8` | Seeded admin password |
| `TASKAPP_ADMIN_EMAIL` | `admin@taskflow.demo` | Seeded admin email |
| `TASKAPP_SEED_SAMPLE` | `false` | If `true`, also seed sample users/tasks |

---

## REST API (for the Saviynt connector flow)

All `/api/users` endpoints use **HTTP Basic auth** and require an Administrator
account. Interactive docs: `/docs`.

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/api/users` | List users |
| `GET` | `/api/users/{id}` | Read one user |
| `POST` | `/api/users` | Create a user (returns a generated `temporaryPassword`) |
| `PATCH` | `/api/users/{id}` | Update fields, role, or active status |
| `DELETE` | `/api/users/{id}` | Remove a user |

Example — create a user:

```bash
curl -u robbytheadmin:'N0nPr0dF0r$@viynt8' \
  -X POST http://localhost:8000/api/users \
  -H 'Content-Type: application/json' \
  -d '{"firstName":"Jordan","lastName":"Rivera","email":"jordan.rivera@example.com","role":"Sales Rep"}'
```

Example — disable a user (deactivate rather than delete):

```bash
curl -u robbytheadmin:'N0nPr0dF0r$@viynt8' \
  -X PATCH http://localhost:8000/api/users/5 \
  -H 'Content-Type: application/json' \
  -d '{"active": false}'
```

Deleting or disabling the final active Administrator returns `409 Conflict`.

---

## Using it in a Saviynt demo

TaskFlow gives you two ways to demonstrate onboarding the same web-only app:

1. **Browser automation** — Saviynt's AI browser agent logs in as an
   Administrator and drives the **Users** page: *Add User* (first name, last
   name, email, role), *Edit*, *Deactivate / Activate*, *Reset Password*, and
   *Delete*. Each control has a stable ID (e.g. `add-user-btn`,
   `edit-user-{id}`, `deactivate-user-{id}`, `delete-user-{id}`) so the recorded
   flow stays reliable.
2. **REST connector** — point a Saviynt REST connector at `/api/users` for
   create / read / update / disable / delete, mapping the provisioning lifecycle
   to the HTTP verbs above.

This lets you show the full IAM lifecycle — **provision, update, disable
(deprovision-soft), and delete (deprovision-hard)** — against a realistic target.

---

## Deployment to AWS

See [`deploy/README.md`](deploy/README.md). In short: `./setup.sh` to check
prerequisites, then `./deploy.sh` to build from this repo and run it on AWS ECS
Fargate behind a load balancer, with data persisted on EFS.

---

## Project layout

```
app/
  main.py          FastAPI app, routes, sessions, startup seed
  api.py           /api/users REST provisioning endpoints
  db.py            SQLite access, schema, password hashing, CRUD
  permissions.py   Role-based access helpers
  seed.py          Seeds the default admin (and optional sample data)
  templates/       Jinja2 templates (login, dashboard, tasks, users, forms)
  static/style.css Minimal, automation-friendly styling
Dockerfile         python:3.12-slim, non-root, healthcheck on /health
requirements.txt
deploy/            AWS ECS Fargate scripts + their README
```
