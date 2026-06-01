"""
seed.py — create the default administrator on first boot.

Runs every startup but only creates the admin if no Administrator exists yet,
so it is safe across restarts and redeploys (EFS keeps the DB).

Credentials come from env (set by deploy.sh) and default to the same demo
values the hrDemoWebApp used, so the runbook stays familiar:
    username: robbytheadmin
    password: N0nPr0dF0r$@viynt8

Set TASKAPP_SEED_SAMPLE=true to also create a few example users + tasks so the
dashboard isn't empty during a walkthrough. Leave it off for a clean
provisioning demo where Saviynt creates every user.
"""

import os
from . import db

DEFAULT_ADMIN_USER = os.environ.get("TASKAPP_ADMIN_USERNAME", "robbytheadmin")
DEFAULT_ADMIN_PASS = os.environ.get("TASKAPP_ADMIN_PASSWORD", "N0nPr0dF0r$@viynt8")
DEFAULT_ADMIN_EMAIL = os.environ.get("TASKAPP_ADMIN_EMAIL", "admin@taskflow.demo")


def seed():
    db.init_db()

    if db.count_admins() == 0 and not db.get_user_by_username(DEFAULT_ADMIN_USER):
        db.create_user(
            first_name="Robby",
            last_name="Admin",
            email=DEFAULT_ADMIN_EMAIL,
            role="Administrator",
            password=DEFAULT_ADMIN_PASS,
            username=DEFAULT_ADMIN_USER,
        )
        print(f"[seed] Created default administrator '{DEFAULT_ADMIN_USER}'")

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
            uid, _, _ = db.create_user(first, last, email, role, password="Demo-Pass1")
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
