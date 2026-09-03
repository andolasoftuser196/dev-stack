#!/usr/bin/env python3
"""scaffold/scaffold.py - project detection.

Detection getting it wrong produces a stack that starts and then fails in a way
that looks like the application's fault, so the interesting cases here are the
ambiguous ones: a Laravel repo also has a package.json, a Next.js repo may have
a pyproject.toml for tooling. The manifest that defines how the app is *served*
must win.
"""

import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scaffold"))

try:
    import scaffold
except ImportError as e:                                    # pragma: no cover
    print("skipping: %s (pip install -r scaffold/requirements.txt)" % e)
    raise SystemExit(0)


class Repo:
    """A throwaway project tree."""

    def __init__(self, **files):
        self.d = tempfile.TemporaryDirectory()
        self.p = Path(self.d.name)
        for name, content in files.items():
            f = self.p / name.replace("__", "/")
            f.parent.mkdir(parents=True, exist_ok=True)
            f.write_text(content if isinstance(content, str) else json.dumps(content))

    def __enter__(self): return self.p
    def __exit__(self, *a): self.d.cleanup()


class TestPhp(unittest.TestCase):
    def test_laravel(self):
        with Repo(**{"composer.json": {"require": {"php": "^8.2", "laravel/framework": "^11"}}}) as p:
            d = scaffold.detect(p)
        self.assertEqual((d.runtime, d.framework, d.docroot), ("frankenphp", "laravel", "public"))
        self.assertTrue(d.queue and d.scheduler)
        self.assertIn("composer install --no-interaction --prefer-dist", d.post_create)

    def test_php_version_takes_the_floor_of_the_constraint(self):
        # Building the ceiling would silently move the project to a PHP it has
        # never been tested on.
        with Repo(**{"composer.json": {"require": {"php": "^8.1"}}}) as p:
            self.assertEqual(scaffold.detect(p).version, "8.1")

    def test_cakephp_serves_from_webroot(self):
        with Repo(**{"composer.json": {"require": {"cakephp/cakephp": "^4.6"}}}) as p:
            d = scaffold.detect(p)
        self.assertEqual((d.framework, d.docroot), ("cakephp", "webroot"))

    def test_symfony(self):
        with Repo(**{"composer.json": {"require": {"symfony/framework-bundle": "^7"}}}) as p:
            self.assertEqual(scaffold.detect(p).framework, "symfony")

    def test_unrecognised_php_says_so_rather_than_guessing(self):
        with Repo(**{"composer.json": {"require": {"monolog/monolog": "^3"}}}) as p:
            d = scaffold.detect(p)
        self.assertEqual(d.framework, "none")
        self.assertTrue(any("no framework recognised" in n for n in d.notes))

    def test_postgres_is_read_from_the_app_env_not_assumed(self):
        with Repo(**{"composer.json": {"require": {"laravel/framework": "^11"}},
                     ".env.example": "DB_CONNECTION=pgsql\n"}) as p:
            self.assertEqual(scaffold.detect(p).database, "postgres")


class TestNode(unittest.TestCase):
    def test_next(self):
        with Repo(**{"package.json": {"dependencies": {"next": "15"}}}) as p:
            d = scaffold.detect(p)
        self.assertEqual((d.runtime, d.framework, d.app_port), ("node", "next", 3000))

    def test_nest(self):
        with Repo(**{"package.json": {"dependencies": {"@nestjs/core": "10"}}}) as p:
            self.assertEqual(scaffold.detect(p).framework, "nest")

    def test_vite_uses_its_own_port(self):
        with Repo(**{"package.json": {"devDependencies": {"vite": "5"}}}) as p:
            d = scaffold.detect(p)
        self.assertEqual((d.framework, d.app_port), ("vite", 5173))

    def test_node_version_from_engines(self):
        with Repo(**{"package.json": {"engines": {"node": ">=20"}}}) as p:
            self.assertEqual(scaffold.detect(p).version, "20")

    def test_prisma_adds_a_migration_hook(self):
        with Repo(**{"package.json": {"dependencies": {"next": "15", "prisma": "5"}}}) as p:
            self.assertIn("npx prisma migrate deploy", scaffold.detect(p).post_start)


class TestPython(unittest.TestCase):
    def test_django(self):
        with Repo(**{"pyproject.toml": '[project]\ndependencies = ["django>=5"]'}) as p:
            d = scaffold.detect(p)
        self.assertEqual((d.runtime, d.framework, d.database), ("python", "django", "postgres"))
        self.assertIn("python manage.py migrate --noinput", d.post_start)

    def test_fastapi(self):
        with Repo(**{"requirements.txt": "fastapi\nuvicorn\n"}) as p:
            self.assertEqual(scaffold.detect(p).framework, "fastapi")

    def test_flask(self):
        with Repo(**{"requirements.txt": "flask\n"}) as p:
            self.assertEqual(scaffold.detect(p).framework, "flask")

    def test_celery_turns_on_the_worker(self):
        with Repo(**{"requirements.txt": "django\ncelery\n"}) as p:
            d = scaffold.detect(p)
        self.assertTrue(d.queue and d.scheduler)

    def test_requirements_only_uses_pip_install(self):
        with Repo(**{"requirements.txt": "flask\n"}) as p:
            self.assertIn("uv pip install -r requirements.txt", scaffold.detect(p).post_create)


class TestGo(unittest.TestCase):
    def test_go(self):
        with Repo(**{"go.mod": "module example.com/x\n\ngo 1.23\n"}) as p:
            d = scaffold.detect(p)
        self.assertEqual((d.runtime, d.version, d.app_port), ("go", "1.23", 8080))
        self.assertEqual(d.post_create, ["go mod download"])


class TestPrecedence(unittest.TestCase):
    def test_composer_wins_over_a_build_toolchain_package_json(self):
        # Every Laravel app has a package.json for its assets. It is not a Node app.
        with Repo(**{"composer.json": {"require": {"laravel/framework": "^11"}},
                     "package.json": {"devDependencies": {"vite": "5"}}}) as p:
            self.assertEqual(scaffold.detect(p).runtime, "frankenphp")

    def test_package_json_wins_over_a_tooling_pyproject(self):
        with Repo(**{"package.json": {"dependencies": {"next": "15"}},
                     "pyproject.toml": "[tool.black]\n"}) as p:
            self.assertEqual(scaffold.detect(p).runtime, "node")

    def test_no_manifest_says_so(self):
        with Repo(**{"README.md": "hi"}) as p:
            d = scaffold.detect(p)
        self.assertTrue(any("no recognisable manifest" in n for n in d.notes))

    def test_an_existing_compose_file_is_flagged(self):
        # Running both stacks fights over ports and container names.
        with Repo(**{"composer.json": {"require": {}}, "docker-compose.yml": "services: {}"}) as p:
            d = scaffold.detect(p)
        self.assertTrue(any("already has a docker-compose" in n for n in d.notes))


class TestRendering(unittest.TestCase):
    def test_slug(self):
        for raw, want in [("My App", "my-app"), ("some-web", "some-web"),
                          ("a__b", "a-b"), ("", "app"), ("--x--", "x")]:
            self.assertEqual(scaffold.slug(raw), want, raw)

    def test_rendered_stack_yml_parses_with_the_toolkit_reader(self):
        """Round trip: what the scaffolder writes, lib/yaml.awk must read."""
        import subprocess
        with Repo(**{"composer.json": {"require": {"php": "^8.3", "laravel/framework": "^11"}}}) as p:
            r = subprocess.run(
                [sys.executable, str(ROOT / "scaffold" / "scaffold.py"),
                 "--ssmd-root", str(ROOT), "--repo", str(p), "--dry-run"],
                capture_output=True, text=True, check=True)
        body = r.stdout.split("--- stack.yml ---", 1)[1]
        with tempfile.NamedTemporaryFile("w", suffix=".yml", delete=False) as f:
            f.write(body); path = f.name
        out = subprocess.run(["awk", "-f", str(ROOT / "lib" / "yaml.awk"), path],
                             capture_output=True, text=True)
        Path(path).unlink()
        self.assertEqual(out.stderr.strip(), "", "the reader warned about generated output")
        for key in ("STACK_NAME=", "STACK_RUNTIME_KIND=", "STACK_DATABASE_NAME=",
                    "STACK_HOOKS_POSTCREATE=", "STACK_AGENTS_EGRESS="):
            self.assertIn(key, out.stdout, key)


class TestInitWritesWhereConfigReads(unittest.TestCase):
    """`ssmd init --into` must land the seed where lib/config.sh looks for it.

    Getting this wrong does not fail. CONFIG_SEEDS reads config/stack.yml, the
    copy of the toolkit brings its own along, and the scaffolded project comes
    up as whatever the toolkit was last used for - a Next.js repo served by
    FrankenPHP, reported by `ssmd describe` as if it were correct. Nothing
    downstream can tell it apart from a real answer, which is what makes it
    worth a test that runs the whole thing rather than one that checks a path
    string.
    """

    def _init_into(self, project: Path) -> Path:
        import subprocess
        r = subprocess.run(
            [sys.executable, str(ROOT / "scaffold" / "scaffold.py"),
             "--ssmd-root", str(ROOT), "--into", str(project)],
            capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, f"init failed:\n{r.stdout}\n{r.stderr}")
        return project / "dev-stack"

    def test_the_seed_lands_in_config(self):
        with Repo(**{"package.json": {"dependencies": {"next": "^15.0.0"}}}) as p:
            dest = self._init_into(p)
            seed = dest / "config" / "stack.yml"
            self.assertTrue(seed.is_file(), "no config/stack.yml - nothing will read the generated config")
            self.assertFalse((dest / "stack.yml").exists(),
                             "a stack.yml beside config/ is read by nothing and only misleads")

    def test_the_seed_describes_the_project_not_the_toolkit(self):
        # The assertion that would have caught the bug: the copied-in seed says
        # frankenphp/laravel, the detected one says node/next.
        with Repo(**{"package.json": {"dependencies": {"next": "^15.0.0"}}}) as p:
            dest = self._init_into(p)
            body = (dest / "config" / "stack.yml").read_text()
        self.assertIn("kind: node", body)
        self.assertIn("framework: next", body)
        self.assertNotIn("frankenphp", body)

    def test_init_does_not_demand_force_for_the_seed_it_just_copied(self):
        # config/stack.yml always exists after the copytree. Testing existence
        # after the copy rather than before makes --force mandatory on every
        # init of a fresh project.
        with Repo(**{"package.json": {"dependencies": {"next": "^15.0.0"}}}) as p:
            self._init_into(p)


class TestClosingInstructions(unittest.TestCase):
    """The last thing init prints is the thing a person acts on.

    It used to render the destination relative to the current directory
    unconditionally, so scaffolding into a temp dir printed

        cd ../../../../../tmp/.../probe/dev-stack

    Correct, unreadable, and it reads as though the tool lost the directory it
    had just finished writing to.
    """

    def _run_init(self, project: Path) -> str:
        import subprocess
        r = subprocess.run(
            [sys.executable, str(ROOT / "scaffold" / "scaffold.py"),
             "--ssmd-root", str(ROOT), "--into", str(project)],
            capture_output=True, text=True, cwd=str(ROOT))
        self.assertEqual(r.returncode, 0, f"init failed:\n{r.stdout}\n{r.stderr}")
        return r.stdout

    def _cd_line(self, out: str) -> str:
        for line in out.splitlines():
            if line.strip().startswith("cd "):
                return line.strip()[3:].strip()
        self.fail(f"init printed no cd line:\n{out}")

    def test_the_cd_line_is_not_a_ladder_of_parent_directories(self):
        with Repo(**{"package.json": {"dependencies": {"next": "^15.0.0"}}}) as p:
            target = self._cd_line(self._run_init(p))
        self.assertNotIn("../..", target,
                         f"the cd line climbs out of the tree instead of naming it: {target}")

    def test_the_cd_line_points_at_the_scaffolded_directory(self):
        # Whichever form it picks has to actually resolve to what was written.
        with Repo(**{"package.json": {"dependencies": {"next": "^15.0.0"}}}) as p:
            target = self._cd_line(self._run_init(p))
            resolved = (ROOT / target).resolve() if not Path(target).is_absolute() else Path(target)
            self.assertTrue((resolved / "config" / "stack.yml").is_file(),
                            f"cd target has no config/stack.yml: {resolved}")


if __name__ == "__main__":
    unittest.main(verbosity=1)
