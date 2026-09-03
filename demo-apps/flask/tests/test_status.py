import os
import re
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from status import status  # noqa: E402


def test_renders_the_agreed_shape():
    out = status("flask")
    assert out.startswith("ssmd demo app")


def test_runs_against_a_disposable_database():
    db = os.environ.get("DB_DATABASE")
    if not db:
        pytest.skip("no database configured")
    assert re.search(r"(_test|_sandbox)$", db)
