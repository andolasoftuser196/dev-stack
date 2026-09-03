import sys
from pathlib import Path

from django.http import HttpResponse

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from status import status  # noqa: E402


def index(request):
    # No /healthz here: Caddy answers it in front of this process, and it has to
    # keep answering while the dev server is reloading after a change.
    return HttpResponse(status("django"), content_type="text/plain")
