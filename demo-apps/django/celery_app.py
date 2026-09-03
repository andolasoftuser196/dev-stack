"""Celery entrypoint for the `queue` and `scheduler` roles.

The demo does no real work - it exists so the worker container has something to
run, stays up, and is restarted by the runtime entrypoint rather than by compose
(a worker that exits on max-runtime is healthy, and letting compose treat that
as a crash makes the backoff grow until the queue stops draining).
"""

import os

from celery import Celery

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "config.settings")

broker = "redis://%s:%s/%s" % (
    os.environ.get("REDIS_HOST", "redis"),
    os.environ.get("REDIS_PORT", "6379"),
    os.environ.get("REDIS_DB", "0"),
)

app = Celery("dx_demo", broker=broker, backend=broker)
app.conf.beat_schedule = {}


@app.task
def noop() -> str:
    return "ok"
