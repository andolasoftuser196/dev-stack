"""FastAPI demo app.

Served by uvicorn on the inner port; Caddy fronts it and answers /healthz. This
app deliberately does not define a health route - Caddy's has to keep answering
while uvicorn is reloading, which is exactly when an app-level one would not.
"""

from fastapi import FastAPI
from fastapi.responses import PlainTextResponse

from .status import status

app = FastAPI(title="ssmd demo", docs_url="/docs")


@app.get("/", response_class=PlainTextResponse)
async def index() -> str:
    return status("fastapi")
