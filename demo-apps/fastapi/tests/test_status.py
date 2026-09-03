import os
import re

import pytest

from app.status import status


def test_renders_the_agreed_shape():
    out = status("fastapi")
    assert out.startswith("dx demo app")
    assert "runtime=" in out
    assert "instance=" in out


def test_runs_against_a_disposable_database():
    """The same guard dx enforces, asserted from inside the project.

    Visible here so anyone reading the app sees it, not only anyone reading the
    toolkit.
    """
    db = os.environ.get("DB_DATABASE")
    if not db:
        pytest.skip("no database configured")
    assert re.search(r"(_test|_sandbox)$", db), \
        "the suite must never point at the development database"
