# Example configurations

Every runtime and framework combination the toolkit accepts. All of them are
validated by the test suite:
`tests/unit/test_compose.sh` parses each one and asserts it produces a working
compose file, so an example here cannot rot without a test going red.

To adopt one:

```bash
cp examples/runtimes/<closest>.stack.yml config/stack.yml
# edit: name, domain, repo.root, repo.git_root
dx config import && dx describe
```

## By runtime

| File | Runtime | Framework | Database | Notes |
|---|---|---|---|---|
| `runtimes/frankenphp-laravel.stack.yml` | PHP 8.3 | Laravel | MySQL | APP_KEY stays in the app's own .env; the worker caches the booted framework |
| `runtimes/frankenphp-cakephp.stack.yml` | PHP 8.3 | CakePHP | Postgres | serves from `webroot/`, not `public/` |
| `runtimes/frankenphp-symfony.stack.yml` | PHP 8.3 | Symfony | Postgres | Messenger consumes `async` by default |
| `runtimes/frankenphp-plain.stack.yml` | PHP 8.3 | none | MySQL | generic verbs only; nothing runs at boot |
| `runtimes/node-next.stack.yml` | Node 22 | Next.js | Postgres | Prisma migrations; HMR needs the proxy's unbuffered responses |
| `runtimes/node-nest.stack.yml` | Node 22 | NestJS | Postgres | queue + scheduler on for BullMQ and `@nestjs/schedule` |
| `runtimes/node-vite.stack.yml` | Node 22 | Vite | **none** | an SPA with no backend - no database container at all |
| `runtimes/node-plain.stack.yml` | Node 22 | none | Postgres | must listen on `$PORT` and `0.0.0.0` |
| `runtimes/python-django.stack.yml` | Python 3.12 | Django | Postgres | Celery worker and beat; Caddy serves `/static` |
| `runtimes/python-fastapi.stack.yml` | Python 3.12 | FastAPI | Postgres | uvicorn `--reload`; Alembic |
| `runtimes/python-flask.stack.yml` | Python 3.12 | Flask | MySQL | no default migration hook - Flask projects vary too much |
| `runtimes/python-plain.stack.yml` | Python 3.12 | none | **none** | set `runtime.start_cmd` |
| `runtimes/go-service.stack.yml` | Go 1.23 | none | Postgres | `air` rebuilds; the proxy holds the request while it does |

## What varies, and what does not

Every example sets the same handful of keys. Everything else - 111 toolkit
defaults covering images, ports, timeouts, thresholds, presets and patterns -
comes from `config/defaults.yml` and is not restated here. That is the point:
adopting an example means deciding about a dozen things, not a hundred.

Machine-specific values are not here either. They live in `config/hosts.yml`,
selected by `DX_HOST` in `.env`:

```
local       loopback only - a laptop or workstation
vm          a shared dev VM reached over the LAN or an SSH tunnel
alt-ports   a machine already running something else on 80/443
ci          no published ports, nothing interactive, no browser
```

Add a machine by adding a key to `config/hosts.yml` and setting `DX_HOST` on it.
No code changes, and `tests/unit/test_config.sh` covers that path.
