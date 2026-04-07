# Compose Project Manager

Standalone helper script for managing multiple Docker Compose projects from one directory.

- Repository: `github.com/AhmadShamli/docker-project`
- License: MIT, with the original license notice kept in copies and substantial portions

## What it does

The script helps when one directory contains a `docker-compose.yml` plus multiple env files such as `.env`, `.env.client-a`, and `.env.client-b`.

It can:

- scan available env files
- read each `COMPOSE_PROJECT_NAME`
- show whether each project is deployed, stopped, or not deployed
- run `up`, `down`, `restart`, `ps`, `logs`, `exec`, `config`, and `pull` against a selected project

It always uses the directory where it is run as the compose root.

## Why this exists

To run multiple client or site instances on the same server, the main rule is:

- do not hardcode `container_name`
- do not hardcode non-shared volume names
- do not hardcode the app's internal network name
- use a unique `COMPOSE_PROJECT_NAME` per client/site

## Why the previous setup caused issues

`container_name: ${CONTAINER_PREFIX}_app` and similar values create global Docker object names.
If two sites reuse the same prefix, or if one variable is forgotten, Docker sees a name collision.

Compose already solves this problem for us:

- containers become `<project>_<service>_1`
- volumes become `<project>_<volume>`
- networks become `<project>_<network>`

That means `client-a` and `client-b` can share one server safely.

## Recommended structure

Keep one deployed stack directory, each with its own env files:

```text
/srv/docker-projects/site-a
/srv/docker-projects/site-b
```

Inside each directory, each deployment target gets a different `COMPOSE_PROJECT_NAME`:

```env
COMPOSE_PROJECT_NAME=site_a
APP_NAME="Site A"
APP_URL=https://site-a.example.com
SHARED_PROXY_NETWORK=mynetwork
```

```env
COMPOSE_PROJECT_NAME=site_b
APP_NAME="Site B"
APP_URL=https://site-b.example.com
SHARED_PROXY_NETWORK=mynetwork
```

## Installation

Clone or copy `compose-project.sh` into any machine that has Docker Compose available.

To install the script into the current working directory:

```bash
bash /path/to/compose-project.sh install
chmod +x ./compose-project.sh
```

This creates a local `./compose-project.sh` in the directory where the command is run.

## Direct Docker Compose commands

From a project directory:

```powershell
docker compose --env-file .env up -d --build
```

Or, if both clients share one repo and only env files differ:

```powershell
docker compose --project-name site_a --env-file .env.site-a up -d --build
docker compose --project-name site_b --env-file .env.site-b up -d --build
```

## Script usage

Interactive mode:

```bash
./compose-project.sh
```

When interactive mode starts, it prints the script info once, then shows the detected projects.

Single command mode:

```bash
./compose-project.sh list
./compose-project.sh up 1 --build
./compose-project.sh down 2
./compose-project.sh restart 1
./compose-project.sh logs 1 webserver
./compose-project.sh exec 1 app -- php artisan migrate
./compose-project.sh env up site-a --build
./compose-project.sh env logs site_a webserver
./compose-project.sh env exec site-a app -- php artisan migrate
```

Examples:

```bash
./compose-project.sh list
./compose-project.sh

# after list inside the interactive prompt
up 1 --build
down 2
restart 1
logs 1 webserver
exec 1 app -- php artisan migrate

# direct env-based commands
env up site-a --build
env down site-a
env restart site_a
env logs site-a webserver
env exec site-a app -- php artisan migrate
```

A project can install the helper locally with `bash /path/to/compose-project.sh install`.
After that, the script uses the directory where it is run as the compose root, reads `.env` and `.env.*` there, and targets `./docker-compose.yml` by default.
`list` scans only the current directory, shows numbered projects plus deployed status, and those numbers can be used immediately for `up`, `down`, `restart`, `logs`, `exec`, and similar commands.
If you already know the project, use `env <action> <project>` with either the compose project name, env nickname, or env file name.

## Commands

- `install` - copy the script into the current directory as `./compose-project.sh`
- `list` - scan env files and show project numbers, names, and status
- `up <number> [flags]`
- `down <number> [flags]`
- `restart <number>`
- `ps <number>`
- `logs <number> [service]`
- `exec <number> <service> -- <command...>`
- `config <number>`
- `pull <number>`
- `env <action> <project>` - run by compose project name, env alias, or env file name

## Project selectors

The `env` command accepts:

- `COMPOSE_PROJECT_NAME`, for example `site_a`
- env nickname, for example `site-a` for `.env.site-a`
- env file path, for example `.env.site-a`

## Variable naming guidance

Use app variables for app behavior only:

- `APP_NAME`
- `APP_URL`
- `DB_*`
- `REDIS_*`

Use Compose variables for deployment isolation only:

- `COMPOSE_PROJECT_NAME`
- `SHARED_PROXY_NETWORK`

Avoid inventing one variable like `CONTAINER_PREFIX` to drive everything. It tends to leak deployment concerns into app configuration and is easy to misconfigure.

## Shared reverse proxy

If you use a reverse proxy like Traefik or Nginx Proxy Manager, only that shared network should be external.

- `proxy_network` is external and shared
- `app_network` stays private per project

This lets the proxy reach each site's web container without merging all app containers into one flat network.

## License

This project is intended to use the MIT license.

That allows broad reuse, modification, distribution, sublicensing, and commercial use, while requiring the original copyright and license notice to remain included in copies and substantial portions of the software.

