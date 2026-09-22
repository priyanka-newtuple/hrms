"""
Dev-only mock login so the app is runnable/testable before real Google OAuth
credentials exist. Hard-disabled outside development/staging — see the
`ENV != production` guard in api/v1/routes/auth.py, which is the actual
enforcement point (this module just centralizes the check for reuse).
"""

from __future__ import annotations

from app.config import get_settings


def dev_login_allowed() -> bool:
    return not get_settings().is_production
