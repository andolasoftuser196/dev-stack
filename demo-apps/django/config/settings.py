"""Django settings for the ssmd demo.

Everything that varies between machines or instances comes from the process
environment, which ssmd injects. Nothing here names a host, a port or a database:
a settings file that does is a settings file that connects to the wrong
instance the first time somebody runs two.
"""

import os
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent.parent

SECRET_KEY = os.environ.get("DJANGO_SECRET_KEY", "ssmd-demo-not-a-secret")
DEBUG = os.environ.get("APP_DEBUG", "true").lower() == "true"

# Every worktree instance arrives as a different Host through the proxy, so an
# explicit list would have to be edited for each one.
ALLOWED_HOSTS = ["*"]
CSRF_TRUSTED_ORIGINS = ["https://*.%s" % os.environ.get("SSMD_DOMAIN", "localhost")]

INSTALLED_APPS = [
    "django.contrib.contenttypes",
    "django.contrib.staticfiles",
    "demo",
]

MIDDLEWARE = ["django.middleware.common.CommonMiddleware"]
ROOT_URLCONF = "config.urls"
WSGI_APPLICATION = "config.wsgi.application"

TEMPLATES = [{"BACKEND": "django.template.backends.django.DjangoTemplates", "APP_DIRS": True,
              "DIRS": [], "OPTIONS": {}}]

_pg = "postgres" in os.environ.get("DB_HOST", "")
DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.postgresql" if _pg else "django.db.backends.mysql",
        "NAME": os.environ.get("DB_DATABASE", "app_dev"),
        "USER": os.environ.get("DB_USERNAME", "app"),
        "PASSWORD": os.environ.get("DB_PASSWORD", "app"),
        "HOST": os.environ.get("DB_HOST", "postgres"),
        "PORT": os.environ.get("DB_PORT", "5432" if _pg else "3306"),
    }
}

# One Redis logical database per instance, plus a key prefix. Sharing the server
# is fine; sharing keyspace produces a cached value from another branch.
CACHES = {
    "default": {
        "BACKEND": "django.core.cache.backends.redis.RedisCache",
        "LOCATION": "redis://%s:%s/%s" % (
            os.environ.get("REDIS_HOST", "redis"),
            os.environ.get("REDIS_PORT", "6379"),
            os.environ.get("REDIS_DB", "0"),
        ),
        "KEY_PREFIX": os.environ.get("CACHE_PREFIX", "ssmd"),
    }
}

EMAIL_BACKEND = "django.core.mail.backends.smtp.EmailBackend"
EMAIL_HOST = os.environ.get("MAIL_HOST", "mailpit")
EMAIL_PORT = int(os.environ.get("MAIL_PORT", "1025"))

# Caddy serves /static in front of this process - the dev server is
# single-threaded enough without also shipping assets.
STATIC_URL = "/static/"
STATIC_ROOT = BASE_DIR / "static"

USE_TZ = True
DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"
