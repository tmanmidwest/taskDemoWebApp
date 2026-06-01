"""
permissions.py — the RBAC model the Saviynt demo revolves around.

The whole point of this app is that *which role a user has changes what they
can see and do*. Keep this table simple and explicit so the demo is easy to
narrate: grant 'Administrator' and user management appears; revoke it and it
disappears.
"""

# Roles allowed to manage other users (the user-provisioning surface).
USER_MANAGER_ROLES = {"Administrator"}

# Roles allowed to view the user directory (read-only for managers).
USER_VIEWER_ROLES = {"Administrator", "Manager"}

# Roles allowed to see/create/assign all tasks (not just their own).
TASK_MANAGER_ROLES = {"Administrator", "Manager"}


def can_manage_users(role: str) -> bool:
    return role in USER_MANAGER_ROLES


def can_view_users(role: str) -> bool:
    return role in USER_VIEWER_ROLES


def can_manage_tasks(role: str) -> bool:
    return role in TASK_MANAGER_ROLES
