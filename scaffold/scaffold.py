#!/usr/bin/env python3
"""ssmd init - detect a project's shape and render a dev-stack for it.

Runs once per project. Everything it produces is plain text a human owns
afterwards: a stack.yml, a .env, and (with --into) a copy of the toolkit.

The detection is deliberately conservative. Guessing wrong about a framework
produces a stack that starts and then fails in a way that looks like the app's
fault, so anything ambiguous is reported as a question rather than assumed.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

try:
    from jinja2 import Environment, FileSystemLoader, StrictUndefined
except ImportError:  # pragma: no cover - init.sh guarantees this
    print("[ssmd init] jinja2 missing; run through 'ssmd init', not directly", file=sys.stderr)
    raise SystemExit(1)


# ── detection ───────────────────────────────────────────────────────────────

@dataclass
class Detected:
    runtime: str = "frankenphp"
    version: str = ""
    framework: str = "none"
    docroot: str = "public"
    app_port: int = 3000
    database: str = "mysql"
    cache: str = "redis"
    queue: bool = False
    scheduler: bool = False
    post_create: list[str] = field(default_factory=list)
    post_start: list[str] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)


def _read_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except Exception:
        return {}


def detect(repo: Path) -> Detected:
    """Work out what this project is from the files it ships.

    Order matters: a Laravel repo also has a package.json, and a Next.js repo may
    have a pyproject.toml for tooling. The manifest that defines how the app is
    *served* wins, and that is the one checked first.
    """
    d = Detected()

    if (repo / "composer.json").exists():
        d.runtime = "frankenphp"
        composer = _read_json(repo / "composer.json")
        require = {**composer.get("require", {}), **composer.get("require-dev", {})}

        # The PHP constraint is a range ("^8.2"); take its floor as the version to
        # build. Building the ceiling would silently move the project to a PHP it
        # has never been tested on.
        m = re.search(r"(\d+\.\d+)", str(require.get("php", "")))
        d.version = m.group(1) if m else "8.3"

        if "laravel/framework" in require:
            d.framework = "laravel"
            d.post_create = ["composer install --no-interaction --prefer-dist"]
            d.post_start = ["php artisan migrate --force"]
            d.queue = d.scheduler = True
        elif "cakephp/cakephp" in require:
            d.framework = "cakephp"
            d.docroot = "webroot"
            d.post_create = ["composer install --no-interaction --prefer-dist"]
            d.post_start = ["bin/cake migrations migrate"]
            d.queue = True
        elif "symfony/framework-bundle" in require:
            d.framework = "symfony"
            d.docroot = "public"
            d.post_create = ["composer install --no-interaction --prefer-dist"]
            d.post_start = ["php bin/console doctrine:migrations:migrate --no-interaction"]
        else:
            d.notes.append(
                "composer.json found but no framework recognised - runtime.framework "
                "is 'none', which means ssmd offers only the generic verbs. Set it by "
                "hand if this is a framework ssmd knows (laravel, cakephp, symfony)."
            )

        # The database driver the app actually configures, not the one we prefer.
        env_example = repo / ".env.example"
        if env_example.exists():
            text = env_example.read_text(errors="ignore")
            if re.search(r"^DB_CONNECTION\s*=\s*(pgsql|postgres)", text, re.M):
                d.database = "postgres"

    elif (repo / "package.json").exists():
        d.runtime = "node"
        pkg = _read_json(repo / "package.json")
        deps = {**pkg.get("dependencies", {}), **pkg.get("devDependencies", {})}
        engines = pkg.get("engines", {}).get("node", "")
        m = re.search(r"(\d+)", str(engines))
        d.version = m.group(1) if m else "22"

        if "next" in deps:
            d.framework, d.app_port = "next", 3000
        elif "@nestjs/core" in deps:
            d.framework, d.app_port = "nest", 3000
        elif "vite" in deps:
            d.framework, d.app_port = "vite", 5173
        d.post_create = ["npm ci"]
        if "prisma" in deps or (repo / "prisma").exists():
            d.post_start = ["npx prisma migrate deploy"]
        d.database = "postgres"

    elif (repo / "pyproject.toml").exists() or (repo / "requirements.txt").exists():
        d.runtime = "python"
        d.version = "3.12"
        d.app_port = 8000
        text = ""
        for f in ("pyproject.toml", "requirements.txt"):
            p = repo / f
            if p.exists():
                text += p.read_text(errors="ignore").lower()
        if "django" in text:
            d.framework = "django"
            d.post_start = ["python manage.py migrate --noinput"]
            d.database = "postgres"
        elif "fastapi" in text:
            d.framework = "fastapi"
            d.database = "postgres"
        elif "flask" in text:
            d.framework = "flask"
        d.post_create = ["uv pip install -r requirements.txt"] if (repo / "requirements.txt").exists() \
            else ["uv sync --frozen"]
        if "celery" in text:
            d.queue = d.scheduler = True

    elif (repo / "go.mod").exists():
        d.runtime = "go"
        d.app_port = 8080
        m = re.search(r"^go (\d+\.\d+)", (repo / "go.mod").read_text(errors="ignore"), re.M)
        d.version = m.group(1) if m else "1.23"
        d.database = "postgres"
        d.post_create = ["go mod download"]

    else:
        d.notes.append(
            "no recognisable manifest (composer.json, package.json, pyproject.toml, "
            "go.mod) - defaulting to PHP. Edit runtime.kind in stack.yml."
        )

    if (repo / "docker-compose.yml").exists() or (repo / "compose.yaml").exists():
        d.notes.append(
            "this project already has a docker-compose.yml. ssmd does not read it and "
            "does not replace it - but running both at once will fight over ports "
            "and container names. Decide which one owns the environment."
        )

    return d


# ── rendering ───────────────────────────────────────────────────────────────

def slug(text: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return s or "app"


def git_root(path: Path) -> Path | None:
    try:
        out = subprocess.run(
            ["git", "-C", str(path), "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, check=True,
        )
        return Path(out.stdout.strip())
    except Exception:
        return None


def relpath(target: Path, start: Path) -> str:
    try:
        return os.path.relpath(target, start)
    except ValueError:
        return str(target)


def main() -> int:
    ap = argparse.ArgumentParser(
        prog="ssmd init",
        description="Scaffold a dev-stack for a project.",
    )
    ap.add_argument("--ssmd-root", required=True, help=argparse.SUPPRESS)
    ap.add_argument("--into", metavar="PATH",
                    help="Copy the toolkit into PATH/dev-stack and configure it there. "
                         "Without this, stack.yml is written where ssmd already lives.")
    ap.add_argument("--repo", metavar="PATH", default=None,
                    help="The application source. Defaults to the parent of the dev-stack.")
    ap.add_argument("--name", help="Stack name. Defaults to the repository directory name.")
    ap.add_argument("--domain", help="Root domain. Defaults to <name>.test")
    ap.add_argument("--runtime", choices=["frankenphp", "node", "python", "go"])
    ap.add_argument("--framework")
    ap.add_argument("--database", choices=["mysql", "postgres", "none"])
    ap.add_argument("--force", action="store_true", help="Overwrite an existing stack.yml")
    ap.add_argument("--dry-run", action="store_true", help="Print what would be written")
    args = ap.parse_args()

    ssmd_root = Path(args.ssmd_root).resolve()

    # Where the generated stack.yml will live.
    if args.into:
        dest = Path(args.into).resolve() / "dev-stack"
        repo = Path(args.repo).resolve() if args.repo else Path(args.into).resolve()
    else:
        dest = ssmd_root
        repo = Path(args.repo).resolve() if args.repo else ssmd_root.parent

    if not repo.exists():
        print(f"[ssmd init] ERROR: no such directory: {repo}", file=sys.stderr)
        return 1

    d = detect(repo)
    if args.runtime:
        d.runtime = args.runtime
    if args.framework:
        d.framework = args.framework
    if args.database:
        d.database = args.database

    name = args.name or slug(repo.name)
    domain = args.domain or f"{name}.test"
    groot = git_root(repo) or repo

    ctx = {
        "name": name,
        "domain": domain,
        "repo_root": relpath(repo, dest),
        "git_root": relpath(groot, dest),
        "worktree_root": relpath(groot.parent / f"{groot.name}-worktrees", dest),
        "runtime": d.runtime,
        "version": d.version,
        "framework": d.framework,
        "docroot": d.docroot,
        "app_port": d.app_port,
        "healthz": "/healthz",
        "database": d.database,
        "db_name": f"{name.replace('-', '_')}_dev",
        "db_user": name.replace("-", "_"),
        "db_version": "8.0" if d.database == "mysql" else "16",
        "cache": d.cache,
        "queue": d.queue,
        "scheduler": d.scheduler,
        "post_create": [],
        "post_start": d.post_start,
        "post_instance": d.post_start,
    }

    env = Environment(
        loader=FileSystemLoader(ssmd_root / "scaffold" / "templates"),
        undefined=StrictUndefined,
        keep_trailing_newline=True,
        trim_blocks=True,
        lstrip_blocks=True,
    )

    print(f"[ssmd init] detected: {d.runtime} {d.version} / {d.framework or 'no framework'}")
    print(f"[ssmd init] stack '{name}' at {domain}")
    print(f"[ssmd init] repo     {repo}")
    print(f"[ssmd init] into     {dest}")
    for n in d.notes:
        print(f"[ssmd init] note: {n}")

    if args.dry_run:
        print("\n--- stack.yml ---")
        print(env.get_template("stack.yml.j2").render(**ctx))
        return 0

    # config/stack.yml, not stack.yml: CONFIG_SEEDS in lib/config.sh reads the
    # seeds out of config/, and a file written beside it is read by nothing.
    # Writing to the wrong path does not fail - the scaffolded project quietly
    # runs on whichever stack.yml the copy below brought with it, so a Next.js
    # project comes up as whatever the toolkit was last used for.
    stack_path = dest / "config" / "stack.yml"

    # Whether the *user* already had one, asked before the copy. After it,
    # config/stack.yml always exists - copytree just put the toolkit's own there
    # - and testing it then would demand --force on every single init.
    had_stack = stack_path.exists()

    # Copy the toolkit before writing config into it, so the config is not
    # overwritten by the copy.
    if args.into:
        if dest.exists() and not args.force:
            print(f"[ssmd init] ERROR: {dest} already exists. Use --force to overwrite.",
                  file=sys.stderr)
            return 1
        print(f"[ssmd init] copying the toolkit to {dest}")
        shutil.copytree(
            ssmd_root, dest, dirs_exist_ok=True,
            # Never copy another project's state, secrets or caches.
            ignore=shutil.ignore_patterns(
                "data", ".env", ".stack.env", ".venv", "__pycache__",
                "*.pyc", ".git", "node_modules",
            ),
        )

    if had_stack and not args.force:
        print(f"[ssmd init] ERROR: {stack_path} exists. Use --force to overwrite.", file=sys.stderr)
        return 1

    stack_path.parent.mkdir(parents=True, exist_ok=True)
    stack_path.write_text(env.get_template("stack.yml.j2").render(**ctx))
    print(f"[ssmd init] wrote {stack_path}")

    env_path = dest / ".env"
    if not env_path.exists():
        shutil.copy(dest / ".env.example", env_path)
        print(f"[ssmd init] wrote {env_path} (from .env.example)")

    gitignore = dest / ".gitignore"
    if not gitignore.exists():
        gitignore.write_text(env.get_template("gitignore.j2").render(**ctx))
        print(f"[ssmd init] wrote {gitignore}")

    (dest / "ssmd").chmod(0o755)

    print(f"""
[ssmd init] done.

  cd {relpath(dest, Path.cwd())}
  ./ssmd preflight        check this machine can run it
  ./ssmd up               start the stack
  ./ssmd urls             where everything is

  Review stack.yml first - the detection is a starting point, not an answer.
  In particular check: runtime.docroot, services.database, and hooks.postStart.
""")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
