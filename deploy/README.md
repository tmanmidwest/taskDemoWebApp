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
  (plus ACM if you want HTTPS on a custom domain)
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

Along the way `deploy.sh` asks you three things: which region, what to name this
instance (see *Running more than one instance*), and whether to enable HTTPS on a
custom domain (see below). Press Enter through them to accept the defaults —
`task-demo`, HTTP only.

---

## Running more than one instance

Each instance is a fully isolated stack — its own ECS cluster, EFS filesystem,
load balancer, ECR repository, certificate, and URL — so you can run several in
one AWS account:

```bash
./deploy.sh                    # prompts for an instance name (default: task-demo)
INSTANCE=task-test ./deploy.sh # or name it up front, skipping the prompt
```

Instance names must be lowercase letters, digits, and hyphens; start with a
letter; no trailing hyphen; 28 characters max.

Every management script finds the right instance automatically. With one
deployment it just uses it; with several it lists them and asks. Set `INSTANCE`
to skip the prompt:

```bash
./manage.sh status                    # asks which instance if there's more than one
INSTANCE=task-test ./manage.sh logs   # go straight to that one
INSTANCE=task-test ./teardown.sh
```

> Each running instance has its own load balancer, billed separately (~$16/month
> even when the app is stopped). `deploy.sh` warns you when others already exist.
> Use `./teardown.sh` to remove one you're done with.

---

## HTTPS on a custom domain

By default the app is served over plain HTTP on the generated ALB DNS name.
To serve it over HTTPS on your own domain instead, answer yes when `deploy.sh`
asks, or set it up front:

```bash
ENABLE_HTTPS=true DOMAIN_NAME=tasks.example.com ./deploy.sh
```

The script requests a free AWS-managed (ACM) certificate, adds an HTTPS:443
listener to the load balancer, and redirects HTTP→HTTPS. You add two CNAME
records in Cloudflare when prompted:

1. A one-time certificate-validation record (leave it in place so ACM can
   auto-renew the certificate).
2. A record pointing your domain at the load balancer.

Both should start as **DNS only** (grey cloud). Once it's working you can switch
to Cloudflare's proxy (orange cloud) with SSL/TLS mode **Full (strict)** — the
ACM certificate keeps that hop valid.

Re-running `deploy.sh` reuses an existing certificate for the same domain, so if
validation times out you can just run it again.

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
state file that `deploy.sh` writes on the machine you deployed from — named
`.task-demo-state` for the default instance and `.task-demo-state.<instance>`
for any others. It holds the IDs of your AWS resources but is **not** synced
anywhere, so a second laptop won't have it — you'll see `No deployment found`
if you try to manage from there.

To manage an existing deployment from another machine, regenerate the file by
rediscovering your resources from AWS (this creates nothing — it's read-only):

```bash
chmod +x restore-state.sh
./restore-state.sh             # uses your default AWS region
./restore-state.sh us-west-2   # or pass the region you deployed to
```

It asks which instance name to restore (default `task-demo`), or set `INSTANCE`
to skip the prompt. It also detects whether the deployment uses HTTPS by
inspecting the load balancer's 443 listener, so the restored file matches what
`deploy.sh` wrote.

Once it finishes you can run `./manage.sh status` (and the rest) normally.
The file contains only AWS resource IDs — no secrets — so copying it between
your own machines is also fine if you prefer.

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

Every person runs `deploy.sh` against their own AWS account, and each instance
within an account is isolated too. Every deployment creates:
- Its own ECR repository (image built from the same GitHub source)
- Its own ECS cluster, EFS filesystem, ALB, and security groups
- Its own ACM certificate, if deployed with HTTPS
- Its own `.task-demo-state[.<instance>]` file tracking all resource IDs

Resources are named after the instance (`<instance>-alb`, `<instance>-tg`,
`<instance>-webapp`, and so on), which is what keeps two instances in the same
account from colliding.

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
| `restore-state.sh` | Rebuild a state file from AWS (e.g. on a second machine) |
| `fix-image.sh` | Rebuild the image and recover a stuck/broken deployment |
| `teardown.sh` | Delete all AWS resources for one instance |

All scripts except `setup.sh` accept `INSTANCE=<name>` to select a deployment
without being prompted. `deploy.sh` additionally accepts `ENABLE_HTTPS=true` and
`DOMAIN_NAME=<domain>` for non-interactive HTTPS setup, and
`TASKAPP_ADMIN_PASSWORD` to skip the admin-password prompt.
