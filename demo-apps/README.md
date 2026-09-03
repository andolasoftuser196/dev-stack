# Demo applications

One genuinely runnable application per allowed runtime. They exist so that
`dx up` works the moment you clone this repository - no project of your own
needed - and so the integration tests can boot every runtime for real rather
than asserting about a compose file.

They live here, inside the toolkit, and each example under `examples/runtimes/`
already points `repo.root` at the matching one. That is deliberate: a toolkit
that cannot demonstrate itself is a toolkit nobody can evaluate.

```bash
cp examples/runtimes/go-service.stack.yml config/stack.yml
dx config import && dx up core && dx urls
```

That is the whole setup - no clone, no scaffold, no project.

## The contract every app implements

Each one serves a plain-text status page at `/` in exactly this shape:

```
dx demo app
runtime=frankenphp framework=laravel version=8.3
instance=main
database=app_dev ok
cache=db0 ok
mail=ok
storage=skipped
```

One format, so `tests/integration/test_apps.sh` can boot all thirteen and assert
the same things about each. `ok` means the app actually opened a connection -
not that the container is running, which is what `dx verify` already covers.

The apps deliberately do **not** serve `/healthz`. That is the web server's job
in every dx runtime, and an application-level healthz would defeat the point:
it has to keep answering while the application is broken.

Every app that has a migration tool ships one migration, and
`tests/integration/test_apps.sh` asserts the table it creates actually exists
afterwards — a hook exiting zero proves nothing, and Doctrine's
`--allow-no-migration` exits zero having found none at all.

Each app also provides, where its ecosystem has the concept:

| | so that this works |
|---|---|
| a dependency manifest | `dx deps` |
| one migration | `dx db:migrate` |
| one test | `dx test` |
| a framework CLI | `dx artisan`, `dx cake`, `dx manage`, … |

## What is here

| Directory | Runtime | Framework | Real framework? |
|---|---|---|---|
| `laravel/` | frankenphp | Laravel 11 | yes - `composer install` pulls it |
| `cakephp/` | frankenphp | CakePHP 5 | yes |
| `symfony/` | frankenphp | Symfony 7 | yes |
| `php-plain/` | frankenphp | none | n/a |
| `next/` | node | Next.js 15 | yes - `npm ci` pulls it |
| `nest/` | node | NestJS 10 | yes |
| `express/` | node | Express 4 | yes |
| `vite/` | node | Vite 5 | yes |
| `django/` | python | Django 5 | yes |
| `fastapi/` | python | FastAPI | yes |
| `flask/` | python | Flask 3 | yes |
| `python-plain/` | python | none | n/a |
| `go/` | go | none (net/http) | n/a |

They are minimal on purpose. A full framework skeleton would be a starter
template - a different thing, with a maintenance burden this repository should
not carry. These are the smallest applications that genuinely exercise the
stack: real framework, real routing, real connections.

## No lockfiles

A real project commits one, and `dx deps` does a frozen install from it - that is
the whole point of `npm ci` over `npm install`. These demos deliberately do not:
a generated Next.js lockfile is ten thousand lines, and thirteen of them would be
most of this repository by volume.

`dx deps` detects the absence, says the result is not reproducible, and installs
anyway so the stack still comes up. That path exists for real projects too - a
new project before its first lockfile hits exactly the same case, and `npm ci`'s
own error message for it says nothing useful.

## They are not starter templates

Do not copy one and build on it. Use the framework's own installer
(`composer create-project`, `npx create-next-app`, `django-admin startproject`),
then point `repo.root` at the result. These exist to prove the stack works and
to give the tests something real to boot.
