import os
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent.parent

SECRET_KEY = os.environ.get("DJANGO_SECRET_KEY", "dev-insecure-key-change-in-production")
DEBUG = os.environ.get("DEBUG", "0") == "1"
ALLOWED_HOSTS = ["*"]

INSTALLED_APPS = [
    "django.contrib.staticfiles",
    "trionyx_ui",
]

MIDDLEWARE = [
    "django.middleware.security.SecurityMiddleware",
    "whitenoise.middleware.WhiteNoiseMiddleware",
    "django.middleware.csrf.CsrfViewMiddleware",
    "django.middleware.common.CommonMiddleware",
    "trionyx_ui.middleware.RequestLoggingMiddleware",
    "trionyx_ui.middleware.PromptRateLimitMiddleware",
]

ROOT_URLCONF = "trionyx_ui.urls"

TEMPLATES = [
    {
        "BACKEND": "django.template.backends.django.DjangoTemplates",
        "DIRS": [BASE_DIR / "trionyx_ui" / "templates"],
        "APP_DIRS": True,
        "OPTIONS": {
            "context_processors": [
                "django.template.context_processors.request",
            ],
        },
    },
]

WSGI_APPLICATION = "trionyx_ui.wsgi.application"

DATABASES = {}

STATIC_URL = "/static/"
STATIC_ROOT = BASE_DIR / "staticfiles"
STATICFILES_DIRS = [BASE_DIR / "trionyx_ui" / "static"]

GATEWAY_URL = os.environ.get("GATEWAY_URL", "http://localhost:4000")
GATEWAY_EXTERNAL_URL = os.environ.get("GATEWAY_EXTERNAL_URL", "http://localhost:4000")

DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"

LOGGING = {
    "version": 1,
    "disable_existing_loggers": False,
    "formatters": {
        "standard": {
            "format": "%(asctime)s [%(levelname)s] %(name)s: %(message)s",
            "datefmt": "%Y-%m-%dT%H:%M:%S%z",
        },
    },
    "handlers": {
        "console": {
            "class": "logging.StreamHandler",
            "formatter": "standard",
        },
    },
    "root": {
        "handlers": ["console"],
        "level": "INFO",
    },
    "loggers": {
        "django": {
            "level": "INFO" if not DEBUG else "DEBUG",
            "propagate": True,
        },
        "django.request": {
            "level": "WARNING",
            "propagate": False,
            "handlers": ["console"],
        },
        "trionyx_ui": {
            "level": "DEBUG" if DEBUG else "INFO",
            "propagate": True,
        },
        "trionyx_ui.gateway": {
            "level": "DEBUG" if DEBUG else "INFO",
            "propagate": True,
        },
    },
}

PROMPT_RATE_LIMIT_SECONDS = float(os.environ.get("PROMPT_RATE_LIMIT", "1.0"))
