"""
api.py — REST user-provisioning API (auto-documented at /docs).

This is the SCIM-flavored connector surface: a Saviynt REST connector can
create / read / update / disable / delete users here using HTTP Basic auth
with any Administrator account. The browser UI and this API operate on the
same database, so you can demo either provisioning style.
"""

import base64
import secrets

from fastapi import APIRouter, Depends, HTTPException, status, Header
from pydantic import BaseModel, EmailStr, Field

from . import db
from .permissions import can_manage_users

router = APIRouter(prefix="/api", tags=["provisioning"])


# ── auth ────────────────────────────────────────────────────────────────────────
def require_admin(authorization: str | None = Header(default=None)):
    if not authorization or not authorization.lower().startswith("basic "):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Basic auth required",
            headers={"WWW-Authenticate": "Basic"},
        )
    try:
        decoded = base64.b64decode(authorization.split(" ", 1)[1]).decode()
        username, _, password = decoded.partition(":")
    except Exception:
        raise HTTPException(status_code=400, detail="Malformed Authorization header")

    user = db.get_user_by_username(username)
    if (
        not user
        or user["status"] != "active"
        or not db.verify_password(password, user["password_hash"])
        or not can_manage_users(user["role"])
    ):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid credentials or insufficient role",
            headers={"WWW-Authenticate": "Basic"},
        )
    return user


# ── schemas ───────────────────────────────────────────────────────────────────
class UserIn(BaseModel):
    firstName: str = Field(..., examples=["Jordan"])
    lastName: str = Field(..., examples=["Rivera"])
    email: EmailStr = Field(..., examples=["jordan.rivera@taskflow.demo"])
    role: str = Field("Sales Rep", examples=db.ROLES)


class UserPatch(BaseModel):
    firstName: str | None = None
    lastName: str | None = None
    email: EmailStr | None = None
    role: str | None = None
    status: str | None = Field(None, examples=["active", "inactive"])


class UserOut(BaseModel):
    id: int
    username: str
    firstName: str
    lastName: str
    email: str
    role: str
    status: str


class UserCreated(UserOut):
    temporaryPassword: str


def _to_out(row) -> UserOut:
    return UserOut(
        id=row["id"], username=row["username"], firstName=row["first_name"],
        lastName=row["last_name"], email=row["email"], role=row["role"],
        status=row["status"],
    )


# ── endpoints ───────────────────────────────────────────────────────────────────
@router.get("/users", response_model=list[UserOut])
def list_users(_: dict = Depends(require_admin)):
    return [_to_out(u) for u in db.list_users()]


@router.get("/users/{user_id}", response_model=UserOut)
def get_user(user_id: int, _: dict = Depends(require_admin)):
    row = db.get_user(user_id)
    if not row:
        raise HTTPException(404, "User not found")
    return _to_out(row)


@router.post("/users", response_model=UserCreated, status_code=201)
def create_user(body: UserIn, _: dict = Depends(require_admin)):
    if body.role not in db.ROLES:
        raise HTTPException(422, f"role must be one of {db.ROLES}")
    if db.get_user_by_email(body.email):
        raise HTTPException(409, "A user with that email already exists")
    uid, username, temp_password = db.create_user(
        body.firstName, body.lastName, body.email, body.role
    )
    row = db.get_user(uid)
    return UserCreated(
        id=row["id"], username=row["username"], firstName=row["first_name"],
        lastName=row["last_name"], email=row["email"], role=row["role"],
        status=row["status"], temporaryPassword=temp_password,
    )


@router.patch("/users/{user_id}", response_model=UserOut)
def patch_user(user_id: int, body: UserPatch, _: dict = Depends(require_admin)):
    row = db.get_user(user_id)
    if not row:
        raise HTTPException(404, "User not found")
    if body.role and body.role not in db.ROLES:
        raise HTTPException(422, f"role must be one of {db.ROLES}")
    if body.status and body.status not in ("active", "inactive"):
        raise HTTPException(422, "status must be 'active' or 'inactive'")
    db.update_user(
        user_id,
        body.firstName if body.firstName is not None else row["first_name"],
        body.lastName if body.lastName is not None else row["last_name"],
        body.email if body.email is not None else row["email"],
        body.role or row["role"],
        body.status or row["status"],
    )
    return _to_out(db.get_user(user_id))


@router.delete("/users/{user_id}", status_code=204)
def delete_user(user_id: int, _: dict = Depends(require_admin)):
    row = db.get_user(user_id)
    if not row:
        raise HTTPException(404, "User not found")
    if row["role"] == "Administrator" and db.count_admins() <= 1:
        raise HTTPException(409, "Cannot delete the last active administrator")
    db.delete_user(user_id)
    return None
