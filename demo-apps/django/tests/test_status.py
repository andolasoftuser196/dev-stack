import os
import re

import pytest


def test_runs_against_a_disposable_database():
    db = os.environ.get("DB_DATABASE")
    if not db:
        pytest.skip("no database configured")
    assert re.search(r"(_test|_sandbox)$", db), \
        "the suite must never point at the development database"


def test_settings_take_connection_details_from_the_environment():
    """A settings file that hardcodes a host connects to the wrong instance."""
    from config import settings
    src = open(settings.__file__).read()
    assert "os.environ" in src
    assert "localhost" not in src
