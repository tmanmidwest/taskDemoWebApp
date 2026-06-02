"""
seed.py — create the default administrator on first boot.

Runs every startup but only creates the admin if no Administrator exists yet,
so it is safe across restarts and redeploys (EFS keeps the DB).

The admin password is REQUIRED and must be supplied via the environment:
    TASKAPP_ADMIN_PASSWORD   (required when the admin must be created)
    TASKAPP_ADMIN_USERNAME   (optional, default: robbytheadmin)
    TASKAPP_ADMIN_EMAIL      (optional, default: admin@taskflow.demo)

There is no hard-coded password. When deploying, deploy.sh prompts for it (or
reads it from the environment). To run locally, set it yourself, e.g.:
    TASKAPP_ADMIN_PASSWORD='your-password' python -m app.main

If no Administrator exists and no password is provided, startup fails with a
clear error rather than creating an account with a guessable password.

Set TASKAPP_SEED_SAMPLE=true to also create a few example users + tasks so the
dashboard isn't empty during a walkthrough. Leave it off for a clean
provisioning demo where Saviynt creates every user.
"""

import os
from . import db

DEFAULT_ADMIN_USER = os.environ.get("TASKAPP_ADMIN_USERNAME", "robbytheadmin")
DEFAULT_ADMIN_EMAIL = os.environ.get("TASKAPP_ADMIN_EMAIL", "admin@taskflow.demo")
# No default — empty/unset means "not provided".
ADMIN_PASSWORD = os.environ.get("TASKAPP_ADMIN_PASSWORD", "").strip()

MIN_ADMIN_PASSWORD_LEN = 8


def seed():
    db.init_db()

    if db.count_admins() == 0 and not db.get_user_by_username(DEFAULT_ADMIN_USER):
        if not ADMIN_PASSWORD:
            raise RuntimeError(
                "No administrator exists and TASKAPP_ADMIN_PASSWORD is not set. "
                "Set it before starting the app, e.g. "
                "TASKAPP_ADMIN_PASSWORD='your-password' python -m app.main "
                "(deploy.sh prompts for this automatically when deploying)."
            )
        if len(ADMIN_PASSWORD) < MIN_ADMIN_PASSWORD_LEN:
            raise RuntimeError(
                f"TASKAPP_ADMIN_PASSWORD is too short "
                f"(minimum {MIN_ADMIN_PASSWORD_LEN} characters)."
            )
        db.create_user(
            first_name="Robby",
            last_name="Admin",
            email=DEFAULT_ADMIN_EMAIL,
            role="Administrator",
            password=ADMIN_PASSWORD,
            username=DEFAULT_ADMIN_USER,
        )
        print(f"[seed] Created administrator '{DEFAULT_ADMIN_USER}'")

    if os.environ.get("TASKAPP_SEED_SAMPLE", "false").lower() == "true":
        _seed_sample()


def _seed_sample():
    samples = [
        ("Maria", "Lopez", "maria.lopez@taskflow.demo", "Manager"),
        ("Devon", "Carter", "devon.carter@taskflow.demo", "Sales Rep"),
        ("Aisha", "Khan", "aisha.khan@taskflow.demo", "Technical Support"),
    ]
    created = {}
    for first, last, email, role in samples:
        if not db.get_user_by_email(email):
            uid, _, _ = db.create_user(first, last, email, role)
            created[role] = uid

    if created and not db.list_tasks():
        admin = db.get_user_by_username(DEFAULT_ADMIN_USER)
        creator = admin["id"] if admin else None
        examples = [
            ("Follow up with Acme Corp lead", "Send the updated quote.",
             created.get("Sales Rep"), "High"),
            ("Reset VPN for new hire", "Ticket #4821 — provision access.",
             created.get("Technical Support"), "Medium"),
            ("Q3 pipeline review", "Prep the deck for the team sync.",
             created.get("Manager"), "Medium"),
        ]
        for title, desc, assignee, prio in examples:
            if assignee:
                db.create_task(title, desc, assignee, prio, None, creator)
        print("[seed] Created sample users and tasks")
