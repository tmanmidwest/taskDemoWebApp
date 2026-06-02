# TaskFlow (taskDemoWebApp) — AWS ECS Fargate Scripts

Deploy, manage, update, and teardown TaskFlow on your own AWS account.
Each person runs these scripts against their own AWS account — fully isolated instances.

TaskFlow is a small multi-role task-management web app built as a provisioning
target for **Saviynt IAM** demos. Saviynt's AI browser agent can create, update,
disable, and remove users either through the web UI or through the built-in REST
API at `/api/users` (auto-documented at `/docs`).

---

## What you need

- **AWS account** with permissions for ECS, ECR, EFS, EC2, ELB, and IAM
- **AWS CLI v2** — https://aws.amazon.com/cli/
- **Docker Desktop** — https://www.docker.com/products/docker-desktop/
- **Git** — on Mac run `xcode-select --install`

---

## Quick start (new deployment)

```bash
# Make all scripts executable (one time only)
chmod +x setup.sh deploy.sh manage.sh update.sh teardown.sh fix-image.sh restore-state.sh

# 1. Check all prerequisites are in place
./setup.sh

# 2. Deploy — takes about 10 minutes, prints your app URL when done
./deploy.sh
```

That's it. The scripts pull the app source from GitHub, build it, push it to
your own ECR, and deploy it to Fargate — everything in your own AWS account.
When it finishes it prints the app URL, the API docs URL, and the default admin
login.

---

## Pushing an update

When changes have been merged to the main branch on GitHub and you want to
deploy them live:

```bash
./update.sh
```

Shows you the exact commit being deployed, asks for confirmation, then
rebuilds the image and redeploys automatically.

---

## Day-to-day management

```bash
./manage.sh status     # Is it running? What's the URL?
./manage.sh stop       # Pause the app — data kept, Fargate charges stop
./manage.sh start      # Resume after stopping
./manage.sh restart    # Restart without a code change
./manage.sh logs       # Stream live logs (Ctrl+C to stop)
./manage.sh url        # Print the app URL
```

---

## Managing from a second machine

The management scripts (`manage.sh`, `update.sh`, `teardown.sh`) read a local
`.task-demo-state` file that `deploy.sh` writes on the machine you deployed from.
It holds the IDs of your AWS resources but is **not** synced anywhere, so a
second laptop won't have it — you'll see `No state file found` if you try to
manage from there.

To manage an existing deployment from another machine, regenerate the file by
rediscovering your resources from AWS (this creates nothing — it's read-only):

```bash
chmod +x restore-state.sh
./restore-state.sh             # uses your default AWS region
./restore-state.sh us-west-2   # or pass the region you deployed to
```

Once it finishes you can run `./manage.sh status` (and the rest) normally.
The file contains only AWS resource IDs — no secrets — so copying it between
your own machines is also fine if you prefer.

> Note: this assumes one `task-demo` deployment per AWS account, which matches the
> isolation model below. The lookups are by resource name, so running two in the
> same account and region is not supported.

---

## If the app won't pull its image or a deploy got stuck

```bash
./fix-image.sh
```

Rebuilds the image straight from GitHub source into your ECR, re-registers a
clean task definition pinned to that image, and forces a fresh deployment.
Use it to recover from an interrupted deploy or a bad task definition.

---

## Remove everything

```bash
./teardown.sh
```

Deletes all AWS resources. Type `delete` to confirm.
Stops all charges. Data is permanently deleted.

---

## How instances are isolated

Every person runs `deploy.sh` against their own AWS account. Each deployment creates:
- Its own ECR repository (image built from the same GitHub source)
- Its own ECS cluster, EFS filesystem, ALB, and security groups
- Its own `.task-demo-state` file tracking all resource IDs

This state file lives only on the machine you deployed from. To operate the same
deployment from another machine, run `./restore-state.sh` there to rebuild it
(see *Managing from a second machine*).

Nobody shares infrastructure. Tearing down your instance has no effect on anyone else's.

---

## Administrator login

A default administrator is seeded the first time the app boots. Its **password
is set when you run `deploy.sh`** — the script prompts for it (entered twice,
hidden), enforces an 8-character minimum, and offers to generate a strong random
one if you leave it blank. The password is passed to the container as an
environment variable and is **never written to this repo or the state file**.

| Field | Value |
|---|---|
| Username | `robbytheadmin` |
| Password | _set interactively at deploy time_ |
| Role | Administrator |

For an unattended/scripted deploy, set the password (and optionally username and
email) in the environment beforehand instead of being prompted:

```bash
export TASKAPP_ADMIN_PASSWORD='your-strong-password'
export TASKAPP_ADMIN_USERNAME='robbytheadmin'   # optional
export TASKAPP_ADMIN_EMAIL='admin@taskflow.demo' # optional
./deploy.sh
```

The seed only runs against an empty database (first boot). Once users exist on
the EFS volume, changing these values has no effect — use the in-app **Change
Password** link (`/account/password`) to rotate the admin password after deploy.

---

## Roles

| Role | Can do |
|---|---|
| **Administrator** | Full user management (create / update / disable / delete) + all tasks |
| **Manager** | View all tasks, create and assign tasks, view users (read-only) |
| **Sales Rep** | See and update only their own assigned tasks |
| **Technical Support** | See and update only their own assigned tasks |

---

## Saviynt demo surfaces

- **Browser UI** — the AI browser agent logs in as an Administrator and uses the
  **Users** page (`/users`) to add, edit, deactivate, and delete users. Stable
  element IDs and predictable routes make the flow reliable to automate.
- **REST API** — for a connector-style integration, Saviynt can call
  `/api/users` (HTTP Basic auth as any Administrator):
  - `GET    /api/users` — list users
  - `GET    /api/users/{id}` — read a user
  - `POST   /api/users` — create (returns a generated temporary password)
  - `PATCH  /api/users/{id}` — update fields / role / status
  - `DELETE /api/users/{id}` — remove a user
  - Interactive docs at `/docs`.

---

## Script reference

| Script | Purpose |
|---|---|
| `setup.sh` | Check all prerequisites before deploying |
| `deploy.sh` | Full deployment from scratch (~10 min) |
| `update.sh` | Rebuild and redeploy from latest GitHub source |
| `manage.sh` | Stop, start, restart, logs, status |
| `restore-state.sh` | Rebuild `.task-demo-state` from AWS (e.g. on a second machine) |
| `fix-image.sh` | Rebuild the image and recover a stuck/broken deployment |
| `teardown.sh` | Delete all AWS resources |
