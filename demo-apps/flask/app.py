"""Flask demo app.

The runtime runs `flask --app app run --debug`. For an app factory elsewhere:
    dx config set runtime.wsgi_app 'myapp:create_app'
"""

from flask import Flask, Response

from status import status

app = Flask(__name__)


@app.get("/")
def index() -> Response:
    return Response(status("flask"), mimetype="text/plain")
