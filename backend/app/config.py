from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    ENV: str = "development"  # development | staging | production
    APP_NAME: str = "Newtuple HRMS"

    DATABASE_URL: str = "postgresql+asyncpg://hrms:hrms@localhost:5432/hrms"

    # Sessions are issued as our own JWT after either Google SSO or dev-login succeeds.
    JWT_SECRET: str = "dev-only-insecure-secret-change-me"
    JWT_ALGORITHM: str = "HS256"
    JWT_EXPIRE_MINUTES: int = 60 * 12
    SESSION_COOKIE_NAME: str = "hrms_session"

    # Google Workspace SSO — restricted to this domain server-side, not just via `hd` param.
    GOOGLE_CLIENT_ID: str = ""
    GOOGLE_CLIENT_SECRET: str = ""
    GOOGLE_REDIRECT_URI: str = "http://localhost:8000/api/v1/auth/google/callback"
    ALLOWED_EMAIL_DOMAIN: str = "newtuple.com"

    FRONTEND_URL: str = "http://localhost:5173"
    CORS_ORIGINS: list[str] = ["http://localhost:5173", "http://localhost:3000"]

    # Outbound email (onboarding handoffs, invitations). When EMAIL_ENABLED is
    # false or SMTP_HOST is empty, "sending" logs the message and marks it sent,
    # so the whole flow is testable without a mail server.
    EMAIL_ENABLED: bool = False
    SMTP_HOST: str = ""
    SMTP_PORT: int = 587
    SMTP_USERNAME: str = ""
    SMTP_PASSWORD: str = ""
    EMAIL_FROM: str = "Newtuple HRMS <no-reply@newtuple.com>"
    OUTBOX_FLUSH_INTERVAL_SECONDS: int = 20

    # New-hire HRMS invitations
    INVITATION_EXPIRE_DAYS: int = 14

    # Employee document uploads (relative to the backend working directory,
    # which is the ./backend bind mount in docker-compose — survives restarts).
    DOCUMENT_STORAGE_DIR: str = "storage/documents"

    # Used once on a fresh production database to create the first account.
    # The bootstrap is idempotent, so keeping these values configured is safe.
    BOOTSTRAP_SUPERADMIN_EMAIL: str = ""
    BOOTSTRAP_SUPERADMIN_FIRST_NAME: str = ""
    BOOTSTRAP_SUPERADMIN_LAST_NAME: str = ""
    BOOTSTRAP_SUPERADMIN_EMPLOYEE_CODE: str = "NT0001"

    # Explicitly enables the fixed production demo personas and their one-click
    # role login. Keep false in real production environments with live data.
    SEED_PRODUCTION_DEMO_DATA: bool = False

    # Flowtuple workflow system — already deployed separately; embedded via iframe.
    FLOWTUPLE_BASE_URL: str = "https://flowtuple.newtuple.internal"
    FLOWTUPLE_ENABLED: bool = False

    @property
    def is_production(self) -> bool:
        return self.ENV == "production"


@lru_cache
def get_settings() -> Settings:
    return Settings()
