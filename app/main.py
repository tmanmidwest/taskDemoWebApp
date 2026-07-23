"""
main.py — TaskFlow demo web app.

A deliberately conventional, server-rendered app meant to be an easy target
for an AI browser agent (e.g. Saviynt) to provision and manage users in.
Stable routes, stable form field names, plain HTML.

Run locally:  python -m app.main
"""

import os
import io
import csv
import json
import asyncio
import logging
from urllib.parse import urlencode

import uvicorn
from fastapi import FastAPI, Request, Form, Depends, HTTPException, Query
from fastapi.responses import HTMLResponse, RedirectResponse, JSONResponse, Response
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from starlette.middleware.sessions import SessionMiddleware

from . import db
from . import audit
from .api import router as api_router
from .permissions import can_manage_users, can_view_users, can_manage_tasks
from .seed import seed

LOG_LEVEL = os.environ.get("TASKAPP_LOG_LEVEL", "INFO").upper()
SECRET_KEY = os.environ.get("TASKAPP_SECRET_KEY", "taskflow-demo-not-secret-change-me")
MIN_PASSWORD_LEN = 8
# Activity-log rows older than this are pruned daily. 0/negative = keep forever.
AUDIT_RETENTION_DAYS = int(os.environ.get("TASKAPP_AUDIT_RETENTION_DAYS", "90"))
AUDIT_LIMIT_CHOICES = [100, 250, 500, 1000]
AUDIT_EXPORT_CAP = 50_000

logging.basicConfig(level=LOG_LEVEL)
log = logging.getLogger("taskflow")

BASE_DIR = os.path.dirname(__file__)
templates = Jinja2Templates(directory=os.path.join(BASE_DIR, "templates"))

app = FastAPI(title="TaskFlow Demo API", docs_url="/docs", redoc_url=None)
app.add_middleware(SessionMiddleware, secret_key=SECRET_KEY, max_age=8 * 3600)
# Logs every /api/* request to the activity log (any and all API activity).
app.add_middleware(audit.ApiAuditMiddleware)
app.mount("/static", StaticFiles(directory=os.path.join(BASE_DIR, "static")), name="static")
app.include_router(api_router)


@app.on_event("startup")
def _startup():
    seed()
    log.info("TaskFlow started. DB at %s", db.DB_PATH)


@app.on_event("startup")
async def _audit_retention():
    """Prune old activity rows on boot, then once a day."""
    async def loop():
        while True:
            try:
                removed = db.prune_events(AUDIT_RETENTION_DAYS)
                if removed:
                    log.info("Pruned %d old activity events", removed)
            except Exception:
                log.exception("activity retention prune failed")
            await asyncio.sleep(24 * 3600)
    asyncio.create_task(loop())


# ── helpers ───────────────────────────────────────────────────────────────────
def current_user(request: Request):
    uid = request.session.get("user_id")
    if not uid:
        return None
    user = db.get_user(uid)
    if not user or user["status"] != "active":
        request.session.clear()
        return None
    return user


def flash(request: Request, message: str, category: str = "info"):
    request.session.setdefault("_flashes", []).append({"m": message, "c": category})


def pop_flashes(request: Request):
    return request.session.pop("_flashes", [])


def render(request, name, user, **ctx):
    return templates.TemplateResponse(
        name,
        {
            "request": request,
            "user": user,
            "flashes": pop_flashes(request),
            "ROLES": db.ROLES,
            "TASK_STATUSES": db.TASK_STATUSES,
            "TASK_PRIORITIES": db.TASK_PRIORITIES,
            "can_manage_users": can_manage_users(user["role"]) if user else False,
            "can_view_users": can_view_users(user["role"]) if user else False,
            "can_manage_tasks": can_manage_tasks(user["role"]) if user else False,
            **ctx,
        },
    )


# ── health ──────────────────────────────────────────────────────────────────────
@app.get("/health")
def health():
    return JSONResponse({"status": "ok"})


# ── auth ────────────────────────────────────────────────────────────────────────
@app.get("/", response_class=HTMLResponse)
def index(request: Request):
    return RedirectResponse("/dashboard" if current_user(request) else "/login", 302)


@app.get("/login", response_class=HTMLResponse)
def login_form(request: Request):
    if current_user(request):
        return RedirectResponse("/dashboard", 302)
    return render(request, "login.html", None)


@app.post("/login", response_class=HTMLResponse)
def login_submit(request: Request, username: str = Form(...), password: str = Form(...)):
    uname = username.strip()
    user = db.get_user_by_username(uname)
    if not user or not db.verify_password(password, user["password_hash"]):
        audit.log_ui(request, None, category="auth", event_type="auth.login",
                     outcome="failure", target_type="user", target_label=uname,
                     message=f"Failed login for '{uname}'",
                     detail={"reason": "invalid_credentials"})
        return render(request, "login.html", None,
                      error="Invalid username or password.")
    if user["status"] != "active":
        audit.log_ui(request, None, category="auth", event_type="auth.login",
                     outcome="failure", target_type="user", target_id=user["id"],
                     target_label=user["username"],
                     message=f"Blocked login for deactivated account '{user['username']}'",
                     detail={"reason": "inactive_account"})
        return render(request, "login.html", None,
                      error="This account is deactivated. Contact an administrator.")
    request.session["user_id"] = user["id"]
    audit.log_ui(request, user, category="auth", event_type="auth.login",
                 target_type="user", target_id=user["id"],
                 target_label=user["username"],
                 message=f"{user['username']} logged in")
    return RedirectResponse("/dashboard", 303)


@app.get("/logout")
def logout(request: Request):
    user = current_user(request)
    if user:
        audit.log_ui(request, user, category="auth", event_type="auth.logout",
                     target_type="user", target_id=user["id"],
                     target_label=user["username"],
                     message=f"{user['username']} logged out")
    request.session.clear()
    return RedirectResponse("/login", 302)


# ── self-service: change my own password ──────────────────────────────────────
@app.get("/account/password", response_class=HTMLResponse)
def change_password_form(request: Request):
    user = current_user(request)
    if not user:
        return RedirectResponse("/login", 302)
    return render(request, "change_password.html", user)


@app.post("/account/password", response_class=HTMLResponse)
def change_password_submit(
    request: Request,
    current_password: str = Form(...),
    new_password: str = Form(...),
    confirm_password: str = Form(...),
):
    user = current_user(request)
    if not user:
        return RedirectResponse("/login", 302)
    if not db.verify_password(current_password, user["password_hash"]):
        audit.log_ui(request, user, category="account",
                     event_type="account.password_change", outcome="failure",
                     target_type="user", target_id=user["id"],
                     target_label=user["username"],
                     message="Password change failed (wrong current password)")
        return render(request, "change_password.html", user,
                      error="Your current password is incorrect.")
    if len(new_password) < MIN_PASSWORD_LEN:
        return render(request, "change_password.html", user,
                      error=f"New password must be at least {MIN_PASSWORD_LEN} characters.")
    if new_password != confirm_password:
        return render(request, "change_password.html", user,
                      error="New password and confirmation do not match.")
    db.set_password(user["id"], new_password)
    audit.log_ui(request, user, category="account",
                 event_type="account.password_change",
                 target_type="user", target_id=user["id"],
                 target_label=user["username"],
                 message=f"{user['username']} changed their own password")
    flash(request, "Your password has been changed.", "success")
    return RedirectResponse("/dashboard", 303)


# ── dashboard (my tasks) ──────────────────────────────────────────────────────
@app.get("/dashboard", response_class=HTMLResponse)
def dashboard(request: Request):
    user = current_user(request)
    if not user:
        return RedirectResponse("/login", 302)
    tasks = db.list_tasks(assignee_id=user["id"])
    return render(request, "dashboard.html", user, tasks=tasks)


# ── tasks ─────────────────────────────────────────────────────────────────────
@app.get("/tasks", response_class=HTMLResponse)
def tasks_all(request: Request):
    user = current_user(request)
    if not user:
        return RedirectResponse("/login", 302)
    if not can_manage_tasks(user["role"]):
        return RedirectResponse("/dashboard", 302)
    return render(request, "tasks.html", user, tasks=db.list_tasks())


@app.get("/tasks/new", response_class=HTMLResponse)
def task_new_form(request: Request):
    user = current_user(request)
    if not user:
        return RedirectResponse("/login", 302)
    if not can_manage_tasks(user["role"]):
        return RedirectResponse("/dashboard", 302)
    return render(request, "task_form.html", user, task=None,
                  users=db.list_users(), action="/tasks/new")


@app.post("/tasks/new")
def task_new_submit(
    request: Request,
    title: str = Form(...),
    description: str = Form(""),
    assignee_id: str = Form(""),
    priority: str = Form("Medium"),
    due_date: str = Form(""),
):
    user = current_user(request)
    if not user or not can_manage_tasks(user["role"]):
        return RedirectResponse("/dashboard", 302)
    aid = int(assignee_id) if assignee_id.strip().isdigit() else None
    task_id = db.create_task(title, description, aid, priority, due_date, user["id"])
    audit.log_ui(request, user, category="task", event_type="task.created",
                 target_type="task", target_id=task_id, target_label=title,
                 message=f"Created task '{title}'",
                 detail={"assignee_id": aid, "priority": priority,
                         "due_date": due_date or None})
    flash(request, f"Task '{title}' created.", "success")
    return RedirectResponse("/tasks", 303)


@app.get("/tasks/{task_id}/edit", response_class=HTMLResponse)
def task_edit_form(request: Request, task_id: int):
    user = current_user(request)
    if not user:
        return RedirectResponse("/login", 302)
    if not can_manage_tasks(user["role"]):
        return RedirectResponse("/dashboard", 302)
    task = db.get_task(task_id)
    if not task:
        raise HTTPException(404, "Task not found")
    return render(request, "task_form.html", user, task=task,
                  users=db.list_users(), action=f"/tasks/{task_id}/edit")


@app.post("/tasks/{task_id}/edit")
def task_edit_submit(
    request: Request,
    task_id: int,
    title: str = Form(...),
    description: str = Form(""),
    assignee_id: str = Form(""),
    status: str = Form("Open"),
    priority: str = Form("Medium"),
    due_date: str = Form(""),
):
    user = current_user(request)
    if not user or not can_manage_tasks(user["role"]):
        return RedirectResponse("/dashboard", 302)
    aid = int(assignee_id) if assignee_id.strip().isdigit() else None
    db.update_task(task_id, title, description, aid, status, priority, due_date)
    audit.log_ui(request, user, category="task", event_type="task.updated",
                 target_type="task", target_id=task_id, target_label=title,
                 message=f"Updated task '{title}'",
                 detail={"assignee_id": aid, "status": status,
                         "priority": priority, "due_date": due_date or None})
    flash(request, "Task updated.", "success")
    return RedirectResponse("/tasks", 303)


@app.post("/tasks/{task_id}/status")
def task_status(request: Request, task_id: int, status: str = Form(...)):
    """Assignees update their own task status; managers/admins update any."""
    user = current_user(request)
    if not user:
        return RedirectResponse("/login", 302)
    task = db.get_task(task_id)
    if not task:
        raise HTTPException(404, "Task not found")
    if not (can_manage_tasks(user["role"]) or task["assignee_id"] == user["id"]):
        return RedirectResponse("/dashboard", 302)
    if status in db.TASK_STATUSES:
        db.set_task_status(task_id, status)
        audit.log_ui(request, user, category="task",
                     event_type="task.status_changed",
                     target_type="task", target_id=task_id,
                     target_label=task["title"],
                     message=f"Set task '{task['title']}' to {status}",
                     detail={"from": task["status"], "to": status})
        flash(request, "Status updated.", "success")
    dest = "/tasks" if can_manage_tasks(user["role"]) else "/dashboard"
    return RedirectResponse(dest, 303)


@app.post("/tasks/{task_id}/delete")
def task_delete(request: Request, task_id: int):
    user = current_user(request)
    if not user or not can_manage_tasks(user["role"]):
        return RedirectResponse("/dashboard", 302)
    task = db.get_task(task_id)
    db.delete_task(task_id)
    audit.log_ui(request, user, category="task", event_type="task.deleted",
                 target_type="task", target_id=task_id,
                 target_label=task["title"] if task else None,
                 message=f"Deleted task '{task['title']}'" if task
                         else f"Deleted task #{task_id}")
    flash(request, "Task deleted.", "success")
    return RedirectResponse("/tasks", 303)


# ── users (provisioning surface) ────────────────────────────────────────────────
@app.get("/users", response_class=HTMLResponse)
def users_list(request: Request):
    user = current_user(request)
    if not user:
        return RedirectResponse("/login", 302)
    if not can_view_users(user["role"]):
        return RedirectResponse("/dashboard", 302)
    return render(request, "users.html", user, users=db.list_users())


@app.get("/users/new", response_class=HTMLResponse)
def user_new_form(request: Request):
    user = current_user(request)
    if not user:
        return RedirectResponse("/login", 302)
    if not can_manage_users(user["role"]):
        return RedirectResponse("/users", 302)
    return render(request, "user_form.html", user, target=None, action="/users/new")


@app.post("/users/new")
def user_new_submit(
    request: Request,
    first_name: str = Form(...),
    last_name: str = Form(...),
    email: str = Form(...),
    role: str = Form("Sales Rep"),
):
    user = current_user(request)
    if not user or not can_manage_users(user["role"]):
        return RedirectResponse("/users", 302)
    if role not in db.ROLES:
        flash(request, "Invalid role.", "error")
        return RedirectResponse("/users/new", 303)
    if db.get_user_by_email(email):
        flash(request, "A user with that email already exists.", "error")
        return RedirectResponse("/users/new", 303)
    uid, username, temp = db.create_user(first_name, last_name, email, role)
    audit.log_ui(request, user, category="user", event_type="user.created",
                 target_type="user", target_id=uid, target_label=username,
                 message=f"Created user '{username}' ({first_name} {last_name})",
                 detail={"role": role, "email": email})
    flash(request,
          f"User '{first_name} {last_name}' created. "
          f"Username: {username} — Temporary password: {temp}", "success")
    return RedirectResponse("/users", 303)


@app.get("/users/{user_id}/edit", response_class=HTMLResponse)
def user_edit_form(request: Request, user_id: int):
    user = current_user(request)
    if not user:
        return RedirectResponse("/login", 302)
    if not can_manage_users(user["role"]):
        return RedirectResponse("/users", 302)
    target = db.get_user(user_id)
    if not target:
        raise HTTPException(404, "User not found")
    return render(request, "user_form.html", user, target=target,
                  action=f"/users/{user_id}/edit")


@app.post("/users/{user_id}/edit")
def user_edit_submit(
    request: Request,
    user_id: int,
    first_name: str = Form(...),
    last_name: str = Form(...),
    email: str = Form(...),
    role: str = Form(...),
    status: str = Form("active"),
):
    user = current_user(request)
    if not user or not can_manage_users(user["role"]):
        return RedirectResponse("/users", 302)
    target = db.get_user(user_id)
    if not target:
        raise HTTPException(404, "User not found")
    # Don't let the last admin demote/deactivate themselves out of access.
    if target["role"] == "Administrator" and (role != "Administrator" or status != "active") \
            and db.count_admins() <= 1:
        flash(request, "Cannot change the last active administrator.", "error")
        return RedirectResponse(f"/users/{user_id}/edit", 303)
    db.update_user(user_id, first_name, last_name, email, role, status)
    audit.log_ui(request, user, category="user", event_type="user.updated",
                 target_type="user", target_id=user_id,
                 target_label=target["username"],
                 message=f"Updated user '{target['username']}'",
                 detail={"role": role, "status": status, "email": email,
                         "prev_role": target["role"],
                         "prev_status": target["status"]})
    flash(request, "User updated.", "success")
    return RedirectResponse("/users", 303)


@app.post("/users/{user_id}/deactivate")
def user_deactivate(request: Request, user_id: int):
    user = current_user(request)
    if not user or not can_manage_users(user["role"]):
        return RedirectResponse("/users", 302)
    target = db.get_user(user_id)
    if target and target["role"] == "Administrator" and db.count_admins() <= 1:
        flash(request, "Cannot deactivate the last active administrator.", "error")
    elif target:
        db.set_user_status(user_id, "inactive")
        audit.log_ui(request, user, category="user",
                     event_type="user.deactivated",
                     target_type="user", target_id=user_id,
                     target_label=target["username"],
                     message=f"Deactivated user '{target['username']}'")
        flash(request, f"User '{target['username']}' deactivated.", "success")
    return RedirectResponse("/users", 303)


@app.post("/users/{user_id}/activate")
def user_activate(request: Request, user_id: int):
    user = current_user(request)
    if not user or not can_manage_users(user["role"]):
        return RedirectResponse("/users", 302)
    target = db.get_user(user_id)
    if target:
        db.set_user_status(user_id, "active")
        audit.log_ui(request, user, category="user", event_type="user.activated",
                     target_type="user", target_id=user_id,
                     target_label=target["username"],
                     message=f"Activated user '{target['username']}'")
        flash(request, f"User '{target['username']}' activated.", "success")
    return RedirectResponse("/users", 303)


@app.post("/users/{user_id}/reset-password")
def user_reset_password(request: Request, user_id: int,
                        new_password: str = Form("")):
    user = current_user(request)
    if not user or not can_manage_users(user["role"]):
        return RedirectResponse("/users", 302)
    target = db.get_user(user_id)
    if target:
        chosen = new_password.strip()
        if chosen:
            if len(chosen) < MIN_PASSWORD_LEN:
                flash(request,
                      f"Password not changed: must be at least {MIN_PASSWORD_LEN} characters.",
                      "error")
                return RedirectResponse("/users", 303)
            db.set_password(user_id, chosen)
            audit.log_ui(request, user, category="user",
                         event_type="user.password_reset",
                         target_type="user", target_id=user_id,
                         target_label=target["username"],
                         message=f"Set a password for '{target['username']}'",
                         detail={"method": "manual"})
            flash(request,
                  f"Password set for '{target['username']}'.", "success")
        else:
            temp = db.generate_temp_password()
            db.set_password(user_id, temp)
            audit.log_ui(request, user, category="user",
                         event_type="user.password_reset",
                         target_type="user", target_id=user_id,
                         target_label=target["username"],
                         message=f"Reset password for '{target['username']}' "
                                 f"(random temp)",
                         detail={"method": "random"})
            flash(request,
                  f"Password reset for '{target['username']}'. New temp password: {temp}",
                  "success")
    return RedirectResponse("/users", 303)


@app.post("/users/{user_id}/delete")
def user_delete(request: Request, user_id: int):
    user = current_user(request)
    if not user or not can_manage_users(user["role"]):
        return RedirectResponse("/users", 302)
    target = db.get_user(user_id)
    if not target:
        return RedirectResponse("/users", 303)
    if target["role"] == "Administrator" and db.count_admins() <= 1:
        flash(request, "Cannot delete the last active administrator.", "error")
    else:
        db.delete_user(user_id)
        audit.log_ui(request, user, category="user", event_type="user.deleted",
                     target_type="user", target_id=user_id,
                     target_label=target["username"],
                     message=f"Deleted user '{target['username']}'",
                     detail={"role": target["role"], "email": target["email"]})
        flash(request, f"User '{target['username']}' deleted.", "success")
    return RedirectResponse("/users", 303)


# ── activity log (visible to every logged-in user) ──────────────────────────────
def _activity_filters(category, outcome, surface, event_type, actor, q,
                      date_from, date_to):
    """Normalize query params into the filter dict db.list_events expects.
    datetime-local sends 'YYYY-MM-DDTHH:MM'; the stored format uses a space."""
    def clean(v):
        return v.strip() if isinstance(v, str) and v.strip() else None

    return {
        "category": clean(category),
        "outcome": clean(outcome),
        "surface": clean(surface),
        "event_type": clean(event_type),
        "actor": clean(actor),
        "q": clean(q),
        "date_from": (clean(date_from) or "").replace("T", " ") or None,
        "date_to": (clean(date_to) or "").replace("T", " ") or None,
    }


@app.get("/activity", response_class=HTMLResponse)
def activity(
    request: Request,
    category: str = Query(""),
    outcome: str = Query(""),
    surface: str = Query(""),
    event_type: str = Query(""),
    actor: str = Query(""),
    q: str = Query(""),
    date_from: str = Query(""),
    date_to: str = Query(""),
    limit: int = Query(100),
):
    user = current_user(request)
    if not user:
        return RedirectResponse("/login", 302)
    if limit not in AUDIT_LIMIT_CHOICES:
        limit = 100
    filters = _activity_filters(category, outcome, surface, event_type, actor,
                                q, date_from, date_to)
    events, total = db.list_events(filters, limit=limit)
    fields = {"category": category, "outcome": outcome, "surface": surface,
              "event_type": event_type, "actor": actor, "q": q,
              "date_from": date_from, "date_to": date_to}
    export_qs = urlencode({k: v for k, v in fields.items() if v})
    return render(
        request, "activity.html", user,
        events=events, total=total, limit=limit,
        limit_choices=AUDIT_LIMIT_CHOICES,
        categories=db.event_categories(),
        outcomes=["success", "failure", "error"],
        surfaces=["ui", "api", "system"],
        f=fields, export_qs=export_qs,
    )


@app.get("/activity/export.json")
def activity_export_json(
    request: Request,
    category: str = Query(""), outcome: str = Query(""), surface: str = Query(""),
    event_type: str = Query(""), actor: str = Query(""), q: str = Query(""),
    date_from: str = Query(""), date_to: str = Query(""),
):
    user = current_user(request)
    if not user:
        return RedirectResponse("/login", 302)
    filters = _activity_filters(category, outcome, surface, event_type, actor,
                                q, date_from, date_to)
    events, _ = db.list_events(filters, limit=AUDIT_EXPORT_CAP)
    return JSONResponse(
        events,
        headers={"Content-Disposition": "attachment; filename=activity.json"},
    )


@app.get("/activity/export.csv")
def activity_export_csv(
    request: Request,
    category: str = Query(""), outcome: str = Query(""), surface: str = Query(""),
    event_type: str = Query(""), actor: str = Query(""), q: str = Query(""),
    date_from: str = Query(""), date_to: str = Query(""),
):
    user = current_user(request)
    if not user:
        return RedirectResponse("/login", 302)
    filters = _activity_filters(category, outcome, surface, event_type, actor,
                                q, date_from, date_to)
    events, _ = db.list_events(filters, limit=AUDIT_EXPORT_CAP)

    buf = io.StringIO()
    writer = csv.writer(buf)
    writer.writerow(db.AUDIT_FIELDS + ["detail"])
    for e in events:
        row = [e.get(field, "") for field in db.AUDIT_FIELDS]
        row.append(json.dumps(e.get("detail", {})))
        writer.writerow(row)
    return Response(
        content=buf.getvalue(),
        media_type="text/csv",
        headers={"Content-Disposition": "attachment; filename=activity.csv"},
    )


if __name__ == "__main__":
    uvicorn.run(
        "app.main:app",
        host=os.environ.get("TASKAPP_BIND_HOST", "0.0.0.0"),
        port=int(os.environ.get("TASKAPP_BIND_PORT", "8000")),
        log_level=LOG_LEVEL.lower(),
    )
