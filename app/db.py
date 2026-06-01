"""
db.py — SQLite data layer for the TaskFlow demo app.

Deliberately dependency-free (stdlib sqlite3 + hashlib) so the container
stays small and the build stays fast. The database file lives at
TASKAPP_DB_PATH (default /data/taskflow.db) which is the EFS-backed volume
in the AWS deployment, so data survives restarts and redeploys.
"""

import os
import sqlite3
import hashlib
import secrets
from datetime import datetime, timezone

DB_PATH = os.environ.get("TASKAPP_DB_PATH", "/data/taskflow.db")

# The four roles this demo provisions. Order matters for dropdown display.
ROLES = ["Administrator", "Manager", "Sales Rep", "Technical Support"]
TASK_STATUSES = ["Open", "In Progress", "Blocked", "Done"]
TASK_PRIORITIES = ["Low", "Medium", "High"]


# ── connection ────────────────────────────────────────────────────────────────
def get_conn():
    """One connection per call; callers use `with get_conn() as conn`."""
    os.makedirs(os.path.dirname(DB_PATH) or ".", exist_ok=True)
    conn = sqlite3.connect(DB_PATH, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    return conn


def _now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")


def init_db():
    with get_conn() as conn:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS users (
                id            INTEGER PRIMARY KEY AUTOINCREMENT,
                username      TEXT    UNIQUE NOT NULL,
                first_name    TEXT    NOT NULL,
                last_name     TEXT    NOT NULL,
                email         TEXT    UNIQUE NOT NULL,
                role          TEXT    NOT NULL,
                status        TEXT    NOT NULL DEFAULT 'active',
                password_hash TEXT    NOT NULL,
                created_at    TEXT    NOT NULL,
                updated_at    TEXT    NOT NULL
            );

            CREATE TABLE IF NOT EXISTS tasks (
                id            INTEGER PRIMARY KEY AUTOINCREMENT,
                title         TEXT    NOT NULL,
                description   TEXT    NOT NULL DEFAULT '',
                status        TEXT    NOT NULL DEFAULT 'Open',
                priority      TEXT    NOT NULL DEFAULT 'Medium',
                assignee_id   INTEGER REFERENCES users(id) ON DELETE SET NULL,
                created_by_id INTEGER REFERENCES users(id) ON DELETE SET NULL,
                due_date      TEXT,
                created_at    TEXT    NOT NULL,
                updated_at    TEXT    NOT NULL
            );
            """
        )


# ── password hashing (stdlib pbkdf2) ────────────────────────────────────────────
def hash_password(password: str) -> str:
    salt = secrets.token_hex(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt.encode(), 200_000)
    return f"pbkdf2_sha256$200000${salt}${digest.hex()}"


def verify_password(password: str, stored: str) -> bool:
    try:
        algo, iters, salt, digest = stored.split("$")
        check = hashlib.pbkdf2_hmac(
            "sha256", password.encode(), salt.encode(), int(iters)
        )
        return secrets.compare_digest(check.hex(), digest)
    except Exception:
        return False


# ── username / temp password helpers ────────────────────────────────────────────
def derive_username(email: str, first_name: str, last_name: str) -> str:
    """username = local part of email; fall back to first.last; ensure unique."""
    base = (email.split("@")[0] if "@" in email else "").strip().lower()
    if not base:
        base = f"{first_name}.{last_name}".strip(".").lower()
    base = "".join(c for c in base if c.isalnum() or c in ".-_") or "user"
    candidate, n = base, 1
    while get_user_by_username(candidate):
        n += 1
        candidate = f"{base}{n}"
    return candidate


def generate_temp_password() -> str:
    # Readable temp password for demos: e.g. Task-7F3A2B
    return "Task-" + secrets.token_hex(3).upper()


# ── user queries ────────────────────────────────────────────────────────────────
def list_users():
    with get_conn() as conn:
        return conn.execute(
            "SELECT * FROM users ORDER BY last_name, first_name"
        ).fetchall()


def get_user(user_id: int):
    with get_conn() as conn:
        return conn.execute("SELECT * FROM users WHERE id = ?", (user_id,)).fetchone()


def get_user_by_username(username: str):
    with get_conn() as conn:
        return conn.execute(
            "SELECT * FROM users WHERE username = ?", (username,)
        ).fetchone()


def get_user_by_email(email: str):
    with get_conn() as conn:
        return conn.execute(
            "SELECT * FROM users WHERE email = ?", (email.lower(),)
        ).fetchone()


def create_user(first_name, last_name, email, role, password=None,
                username=None, status="active"):
    email = email.strip().lower()
    if not username:
        username = derive_username(email, first_name, last_name)
    temp_password = password or generate_temp_password()
    now = _now()
    with get_conn() as conn:
        cur = conn.execute(
            """INSERT INTO users
               (username, first_name, last_name, email, role, status,
                password_hash, created_at, updated_at)
               VALUES (?,?,?,?,?,?,?,?,?)""",
            (username, first_name.strip(), last_name.strip(), email, role,
             status, hash_password(temp_password), now, now),
        )
        user_id = cur.lastrowid
    return user_id, username, temp_password


def update_user(user_id, first_name, last_name, email, role, status):
    with get_conn() as conn:
        conn.execute(
            """UPDATE users SET first_name=?, last_name=?, email=?, role=?,
               status=?, updated_at=? WHERE id=?""",
            (first_name.strip(), last_name.strip(), email.strip().lower(),
             role, status, _now(), user_id),
        )


def set_user_status(user_id, status):
    with get_conn() as conn:
        conn.execute(
            "UPDATE users SET status=?, updated_at=? WHERE id=?",
            (status, _now(), user_id),
        )


def set_password(user_id, password):
    with get_conn() as conn:
        conn.execute(
            "UPDATE users SET password_hash=?, updated_at=? WHERE id=?",
            (hash_password(password), _now(), user_id),
        )


def delete_user(user_id):
    with get_conn() as conn:
        conn.execute("DELETE FROM users WHERE id=?", (user_id,))


def count_admins():
    with get_conn() as conn:
        return conn.execute(
            "SELECT COUNT(*) c FROM users WHERE role='Administrator' AND status='active'"
        ).fetchone()["c"]


# ── task queries ────────────────────────────────────────────────────────────────
def list_tasks(assignee_id=None):
    sql = """
        SELECT t.*,
               u.first_name AS a_first, u.last_name AS a_last, u.username AS a_user
        FROM tasks t LEFT JOIN users u ON t.assignee_id = u.id
    """
    params = ()
    if assignee_id is not None:
        sql += " WHERE t.assignee_id = ?"
        params = (assignee_id,)
    sql += " ORDER BY CASE t.status WHEN 'Done' THEN 1 ELSE 0 END, t.id DESC"
    with get_conn() as conn:
        return conn.execute(sql, params).fetchall()


def get_task(task_id: int):
    with get_conn() as conn:
        return conn.execute("SELECT * FROM tasks WHERE id=?", (task_id,)).fetchone()


def create_task(title, description, assignee_id, priority, due_date, created_by_id):
    now = _now()
    with get_conn() as conn:
        cur = conn.execute(
            """INSERT INTO tasks
               (title, description, status, priority, assignee_id,
                created_by_id, due_date, created_at, updated_at)
               VALUES (?,?,?,?,?,?,?,?,?)""",
            (title.strip(), description.strip(), "Open", priority,
             assignee_id or None, created_by_id, due_date or None, now, now),
        )
        return cur.lastrowid


def update_task(task_id, title, description, assignee_id, status, priority, due_date):
    with get_conn() as conn:
        conn.execute(
            """UPDATE tasks SET title=?, description=?, assignee_id=?, status=?,
               priority=?, due_date=?, updated_at=? WHERE id=?""",
            (title.strip(), description.strip(), assignee_id or None, status,
             priority, due_date or None, _now(), task_id),
        )


def set_task_status(task_id, status):
    with get_conn() as conn:
        conn.execute(
            "UPDATE tasks SET status=?, updated_at=? WHERE id=?",
            (status, _now(), task_id),
        )


def delete_task(task_id):
    with get_conn() as conn:
        conn.execute("DELETE FROM tasks WHERE id=?", (task_id,))
