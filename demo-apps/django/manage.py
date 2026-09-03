#!/usr/bin/env python
"""Run it through the container, always:  ssmd manage <command>

On the host it reads no database configuration at all and reports a connection
error rather than saying what actually went wrong.
"""
import os
import sys

if __name__ == "__main__":
    os.environ.setdefault("DJANGO_SETTINGS_MODULE", "config.settings")
    from django.core.management import execute_from_command_line
    execute_from_command_line(sys.argv)
