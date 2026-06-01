"""
main.py — TaskFlow demo web app.

A deliberately conventional, server-rendered app meant to be an easy target
for an AI browser agent (e.g. Saviynt) to provision and manage users in.
Stable routes, stable form field names, plain HTML.

Run locally:  python -m app.main
"""

import os
import logging

import uvicorn
from fastapi import FastAPI, Request, Form, Depends, HTTPException
from fastapi.responses import HTMLResponse, RedirectResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from starlette.middleware.sessions import SessionMiddleware

from . import db
from .api import router as api_router
from .permissions import can_manage_users, can_view_users, can_manage_tasks
from .seed import seed

LOG_LEVEL = os.environ.get("TASKAPP_LOG_LEVEL", "INFO").upper()
SECRET_KEY = os.environ.get("TASKAPP_SECRET_KEY", "taskflow-demo-not-secret-change-me")
MIN_PASSWORD_LEN = 8

logging.basicConfig(level=LOG_LEVEL)
log = logging.getLogger("taskflow")

BASE_DIR = os.path.dirname(__file__)
templates = Jinja2Templates(directory=os.path.join(BASE_DIR, "templates"))

app = FastAPI(title="TaskFlow Demo API", docs_url="/docs", redoc_url=None)
app.add_middleware(SessionMiddleware, secret_key=SECRET_KEY, max_age=8 * 3600)
app.mount("/static", StaticFiles(directory=os.path.join(BASE_DIR, "static")), name="static")
app.include_router(api_router)


@app.on_event("startup")
def _startup():
    seed()
    log.info("TaskFlow started. DB at %s", db.DB_PATH)


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
    user = db.get_user_by_username(username.strip())
    if not user or not db.verify_password(password, user["password_hash"]):
        return render(request, "login.html", None,
                      error="Invalid username or password.")
    if user["status"] != "active":
        return render(request, "login.html", None,
                      error="This account is deactivated. Contact an administrator.")
    request.session["user_id"] = user["id"]
    return RedirectResponse("/dashboard", 303)


@app.get("/logout")
def logout(request: Request):
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
        return render(request, "change_password.html", user,
                      error="Your current password is incorrect.")
    if len(new_password) < MIN_PASSWORD_LEN:
        return render(request, "change_password.html", user,
                      error=f"New password must be at least {MIN_PASSWORD_LEN} characters.")
    if new_password != confirm_password:
        return render(request, "change_password.html", user,
                      error="New password and confirmation do not match.")
    db.set_password(user["id"], new_password)
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
    db.create_task(title, description, aid, priority, due_date, user["id"])
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
        flash(request, "Status updated.", "success")
    dest = "/tasks" if can_manage_tasks(user["role"]) else "/dashboard"
    return RedirectResponse(dest, 303)


@app.post("/tasks/{task_id}/delete")
def task_delete(request: Request, task_id: int):
    user = current_user(request)
    if not user or not can_manage_tasks(user["role"]):
        return RedirectResponse("/dashboard", 302)
    db.delete_task(task_id)
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
            flash(request,
                  f"Password set for '{target['username']}'.", "success")
        else:
            temp = db.generate_temp_password()
            db.set_password(user_id, temp)
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
        flash(request, f"User '{target['username']}' deleted.", "success")
    return RedirectResponse("/users", 303)


if __name__ == "__main__":
    uvicorn.run(
        "app.main:app",
        host=os.environ.get("TASKAPP_BIND_HOST", "0.0.0.0"),
        port=int(os.environ.get("TASKAPP_BIND_PORT", "8000")),
        log_level=LOG_LEVEL.lower(),
    )
