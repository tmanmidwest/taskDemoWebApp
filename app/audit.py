"""
audit.py — activity-log plumbing for the TaskFlow demo.

Two ways activity gets recorded:

  1. `log_ui(request, actor, ...)` — called explicitly from UI/auth routes for
     rich, human-readable events ("Robby created user jordan.rivera"). This is
     the "user activity" surface: logins, and every add / update / remove.

  2. `ApiAuditMiddleware` — logs EVERY request under /api automatically (method,
     path, status, caller). This is the "any and all API activity" surface, and
     it covers read-only calls too, without instrumenting each endpoint.

Neither path ever records passwords, temporary passwords, request bodies, or
password hashes. The Basic-auth caller's *username* is recorded; the password
is never touched.
"""

import base64

from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request

from . import db


# ── request context ─────────────────────────────────────────────────────────────
def client_ip(request: Request):
    """Real client IP, honoring X-Forwarded-For (first hop) behind the ALB."""
    xff = request.headers.get("x-forwarded-for")
    if xff:
        return xff.split(",")[0].strip()
    return request.client.host if request.client else None


def _context(request: Request):
    return {
        "ip": client_ip(request),
        "user_agent": request.headers.get("user-agent"),
    }


# ── UI / auth events (explicit, rich) ───────────────────────────────────────────
def log_ui(request: Request, actor, *, category, event_type, outcome="success",
           target_type=None, target_id=None, target_label=None, message="",
           detail=None):
    """Record a UI or auth event. `actor` is a user row (or None for anonymous,
    e.g. a failed login before we know who they are)."""
    ctx = _context(request)
    body = {"user_agent": ctx["user_agent"]}
    if detail:
        body.update(detail)
    db.record_event(
        category=category,
        event_type=event_type,
        outcome=outcome,
        actor_type="user" if actor else "anonymous",
        actor_label=actor["username"] if actor else None,
        actor_id=actor["id"] if actor else None,
        target_type=target_type,
        target_id=target_id,
        target_label=target_label,
        surface="ui",
        message=message,
        ip_address=ctx["ip"],
        detail=body,
    )


# ── API middleware (blanket coverage of /api) ────────────────────────────────────
def _api_actor(request: Request):
    """Best-effort caller identity from the Basic-auth header — username only,
    never the password. Returns (actor_type, actor_label, actor_id)."""
    auth = request.headers.get("authorization", "")
    if not auth.lower().startswith("basic "):
        return "anonymous", None, None
    try:
        decoded = base64.b64decode(auth.split(" ", 1)[1]).decode()
        username = decoded.split(":", 1)[0].strip() or None
    except Exception:
        return "api_client", None, None
    actor_id = None
    if username:
        try:
            row = db.get_user_by_username(username)
            if row:
                actor_id = row["id"]
        except Exception:
            pass
    return "api_client", username, actor_id


class ApiAuditMiddleware(BaseHTTPMiddleware):
    """Logs one activity row per /api/* request, after it completes."""

    async def dispatch(self, request: Request, call_next):
        response = await call_next(request)
        try:
            if request.url.path.startswith("/api"):
                self._record(request, response)
        except Exception:
            pass  # auditing must never break the response path
        return response

    @staticmethod
    def _record(request: Request, response):
        actor_type, actor_label, actor_id = _api_actor(request)
        status = response.status_code
        outcome = "success" if status < 400 else "failure"
        ctx = _context(request)
        query = request.url.query
        db.record_event(
            category="api",
            event_type=f"api.{request.method.lower()}",
            outcome=outcome,
            actor_type=actor_type,
            actor_label=actor_label,
            actor_id=actor_id,
            target_type="endpoint",
            target_id=request.url.path,
            surface="api",
            message=f"{request.method} {request.url.path} → {status}",
            ip_address=ctx["ip"],
            detail={
                "status": status,
                "query": query or None,
                "user_agent": ctx["user_agent"],
            },
        )
