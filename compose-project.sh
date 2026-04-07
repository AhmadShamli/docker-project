#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_ROOT="$(pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-$COMPOSE_ROOT/docker-compose.yml}"

PROJECT_FILES=()
PROJECT_NAMES=()
PROJECT_STATUSES=()

usage() {
  cat <<'EOF'
Compose Project Manager

Repository:
  github.com/AhmadShamli/compose-project

This script uses the directory where it is run as the compose project root.

Interactive mode:
  compose-project

Single command mode:
  compose-project list
  compose-project install
  compose-project up 1 --build
  compose-project down 2
  compose-project restart 1
  compose-project logs 1 webserver
  compose-project exec 1 app -- php artisan migrate
  compose-project env up client-a --build
  compose-project env logs melati_client_a webserver
  compose-project env exec client-a app -- php artisan migrate

Commands:
  install
      Install this script into a shared executable path as compose-project.

  list
      Scan env files in the current directory and list all projects with their deployed status.

  up <number> [compose up flags]
  down <number> [compose down flags]
  restart <number>
  ps <number>
  logs <number> [service]
  exec <number> <service> -- <command...>
  config <number>
  pull <number>
      Run the action against a project number from the current list.

  env up <project> [compose up flags]
  env down <project> [compose down flags]
  env restart <project>
  env ps <project>
  env logs <project> [service]
  env exec <project> <service> -- <command...>
  env config <project>
  env pull <project>
      Run the action by project name or env selector directly.

Project selectors accepted by `env`:
  - COMPOSE_PROJECT_NAME value, e.g. melati_client_a
  - env nickname, e.g. client-a for .env.client-a
  - env file path, e.g. .env.client-a

Other:
  help
  exit
  quit
EOF
}

show_info() {
  cat <<'EOF'
=============================
 Compose Project Manager
=============================
Repository : github.com/AhmadShamli/compose-project
License    : MIT

Uses the current working directory as the compose project root.
EOF
}

require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "Error: docker is not installed or not in PATH." >&2
    exit 1
  fi
}

ensure_compose_file() {
  if [[ ! -f "$COMPOSE_FILE" ]]; then
    echo "Error: compose file not found at $COMPOSE_FILE" >&2
    exit 1
  fi
}

install_script() {
  local source_file="$SCRIPT_DIR/compose-project.sh"
  local install_name="compose-project"
  local target_dir=""
  local target_file=""
  local -a candidates=()
  local -a labels=()

  if [[ -n "${COMPOSE_PROJECT_INSTALL_DIR:-}" ]]; then
    candidates+=("$COMPOSE_PROJECT_INSTALL_DIR")
    labels+=("COMPOSE_PROJECT_INSTALL_DIR")
  fi

  if [[ -n "${HOME:-}" ]]; then
    candidates+=("$HOME/.local/bin")
    labels+=("HOME local bin")
  fi

  candidates+=("/usr/local/bin")
  labels+=("system local bin")

  local i
  echo "Select install location for compose-project:"
  for ((i = 0; i < ${#candidates[@]}; i++)); do
    local candidate="${candidates[$i]}"
    local label="${labels[$i]}"
    local state=""

    if [[ -d "$candidate" ]]; then
      if [[ -w "$candidate" ]]; then
        state="exists, writable"
      else
        state="exists, not writable"
      fi
    else
      local parent_dir
      parent_dir="$(dirname "$candidate")"
      if [[ -d "$parent_dir" && -w "$parent_dir" ]]; then
        state="will be created"
      else
        state="cannot create"
      fi
    fi

    printf '  %d) %s - %s [%s]\n' "$((i + 1))" "$candidate" "$label" "$state"
  done

  local default_index=""
  for ((i = 0; i < ${#candidates[@]}; i++)); do
    local candidate="${candidates[$i]}"
    if [[ -d "$candidate" && -w "$candidate" ]]; then
      default_index="$((i + 1))"
      break
    fi

    local parent_dir
    parent_dir="$(dirname "$candidate")"
    if [[ ! -e "$candidate" && -d "$parent_dir" && -w "$parent_dir" ]]; then
      default_index="$((i + 1))"
      break
    fi
  done

  if [[ -z "$default_index" ]]; then
    echo "Error: no writable install directory found." >&2
    echo "Set COMPOSE_PROJECT_INSTALL_DIR to a writable directory in your PATH, or run install with elevated permissions." >&2
    exit 1
  fi

  local selection=""
  while true; do
    read -r -p "Choose location [$default_index]: " selection
    selection="${selection:-$default_index}"

    if [[ "$selection" =~ ^[0-9]+$ ]] && (( selection >= 1 && selection <= ${#candidates[@]} )); then
      target_dir="${candidates[$((selection - 1))]}"
      break
    fi

    echo "Invalid selection. Choose a number from the list." >&2
  done

  if [[ -d "$target_dir" ]]; then
    if [[ ! -w "$target_dir" ]]; then
      echo "Error: install directory is not writable: $target_dir" >&2
      exit 1
    fi
  else
    local parent_dir
    parent_dir="$(dirname "$target_dir")"
    if [[ ! -d "$parent_dir" || ! -w "$parent_dir" ]]; then
      echo "Error: cannot create install directory: $target_dir" >&2
      exit 1
    fi
    mkdir -p "$target_dir"
  fi

  target_file="$target_dir/$install_name"

  if [[ "$source_file" == "$target_file" ]]; then
    chmod +x "$target_file" 2>/dev/null || true
    echo "compose-project is already installed at $target_file"
    return
  fi

  cp "$source_file" "$target_file"
  chmod +x "$target_file" 2>/dev/null || true

  echo "Installed compose-project to $target_file"
  case ":${PATH:-}:" in
    *":$target_dir:"*) ;;
    *)
      echo "Warning: $target_dir is not currently in PATH." >&2
      ;;
  esac
}

discover_env_files() {
  local env_file
  for env_file in "$COMPOSE_ROOT"/.env "$COMPOSE_ROOT"/.env.*; do
    [[ -e "$env_file" ]] || continue
    [[ "$(basename "$env_file")" == ".env.example" ]] && continue
    [[ -f "$env_file" ]] || continue
    printf '%s\n' "$env_file"
  done
}

project_name_from_env() {
  local env_file="$1"
  local project_name

  project_name="$(grep -E '^[[:space:]]*COMPOSE_PROJECT_NAME=' "$env_file" | tail -n 1 | cut -d '=' -f 2- || true)"
  project_name="${project_name%\"}"
  project_name="${project_name#\"}"
  project_name="${project_name%\'}"
  project_name="${project_name#\'}"

  if [[ -z "$project_name" ]]; then
    return 1
  fi

  printf '%s\n' "$project_name"
}

compose_cmd() {
  local project_name="$1"
  local env_file="${2:-}"
  shift 2 || true

  local -a cmd=(docker compose -f "$COMPOSE_FILE" --project-name "$project_name")
  if [[ -n "$env_file" ]]; then
    cmd+=(--env-file "$env_file")
  fi
  cmd+=("$@")
  "${cmd[@]}"
}

project_status() {
  local project_name="$1"
  local running
  local all_services

  running="$(compose_cmd "$project_name" "" ps --status running --services 2>/dev/null || true)"
  if [[ -n "$running" ]]; then
    printf '%s\n' "deployed"
    return
  fi

  all_services="$(compose_cmd "$project_name" "" ps --services 2>/dev/null || true)"
  if [[ -n "$all_services" ]]; then
    printf '%s\n' "stopped"
  else
    printf '%s\n' "not deployed"
  fi
}

refresh_projects() {
  PROJECT_FILES=()
  PROJECT_NAMES=()
  PROJECT_STATUSES=()

  local env_file
  while IFS= read -r env_file; do
    PROJECT_FILES+=("$env_file")

    local project_name="-"
    if project_name="$(project_name_from_env "$env_file" 2>/dev/null)"; then
      PROJECT_NAMES+=("$project_name")
      PROJECT_STATUSES+=("$(project_status "$project_name")")
    else
      PROJECT_NAMES+=("-")
      PROJECT_STATUSES+=("missing COMPOSE_PROJECT_NAME")
    fi
  done < <(discover_env_files)
}

print_projects() {
  refresh_projects

  if [[ "${#PROJECT_FILES[@]}" -eq 0 ]]; then
    echo "No env files found in $COMPOSE_ROOT"
    return
  fi

  printf '%-4s %-24s %-28s %s\n' "NO" "ENV FILE" "PROJECT NAME" "STATUS"

  local i
  for ((i = 0; i < ${#PROJECT_FILES[@]}; i++)); do
    printf '%-4s %-24s %-28s %s\n' \
      "$((i + 1))" \
      "$(basename "${PROJECT_FILES[$i]}")" \
      "${PROJECT_NAMES[$i]}" \
      "${PROJECT_STATUSES[$i]}"
  done
}

resolve_index() {
  local index="${1:-}"

  if [[ -z "$index" || ! "$index" =~ ^[0-9]+$ ]]; then
    echo "Error: project number is required." >&2
    return 1
  fi

  if [[ "${#PROJECT_FILES[@]}" -eq 0 ]]; then
    refresh_projects
  fi

  if (( index < 1 || index > ${#PROJECT_FILES[@]} )); then
    echo "Error: project number $index is out of range." >&2
    return 1
  fi

  printf '%s\n' "$((index - 1))"
}

env_alias_from_file() {
  local env_file
  env_file="$(basename "$1")"

  case "$env_file" in
    .env)
      printf '%s\n' "env"
      ;;
    .env.*)
      printf '%s\n' "${env_file#.env.}"
      ;;
    *)
      printf '%s\n' "$env_file"
      ;;
  esac
}

resolve_project_selector() {
  local selector="${1:-}"
  if [[ -z "$selector" ]]; then
    echo "Error: project selector is required." >&2
    return 1
  fi

  refresh_projects

  local i
  for ((i = 0; i < ${#PROJECT_FILES[@]}; i++)); do
    if [[ "$selector" == "${PROJECT_NAMES[$i]}" ]]; then
      printf '%s\n' "$i"
      return
    fi

    if [[ "$selector" == "$(basename "${PROJECT_FILES[$i]}")" ]]; then
      printf '%s\n' "$i"
      return
    fi

    if [[ "$selector" == "$(env_alias_from_file "${PROJECT_FILES[$i]}")" ]]; then
      printf '%s\n' "$i"
      return
    fi

    if [[ -f "$selector" && "$selector" == "${PROJECT_FILES[$i]}" ]]; then
      printf '%s\n' "$i"
      return
    fi
  done

  echo "Error: project '$selector' not found in env files for this directory." >&2
  return 1
}

run_project_action() {
  local project_name="$1"
  local env_file="$2"
  local action="$3"
  shift 3

  case "$action" in
    up)
      compose_cmd "$project_name" "$env_file" up -d "$@"
      ;;
    down)
      compose_cmd "$project_name" "$env_file" down "$@"
      ;;
    restart)
      compose_cmd "$project_name" "$env_file" restart
      ;;
    ps)
      compose_cmd "$project_name" "$env_file" ps
      ;;
    logs)
      if [[ $# -gt 0 ]]; then
        compose_cmd "$project_name" "$env_file" logs -f "$1"
      else
        compose_cmd "$project_name" "$env_file" logs -f
      fi
      ;;
    exec)
      local service_name="${1:-}"
      if [[ -z "$service_name" ]]; then
        echo "Error: service name is required." >&2
        return 1
      fi
      shift
      if [[ "${1:-}" == "--" ]]; then
        shift
      fi
      if [[ $# -eq 0 ]]; then
        echo "Error: exec requires a command after --" >&2
        return 1
      fi
      compose_cmd "$project_name" "$env_file" exec "$service_name" "$@"
      ;;
    config)
      compose_cmd "$project_name" "$env_file" config
      ;;
    pull)
      compose_cmd "$project_name" "$env_file" pull
      ;;
    *)
      echo "Error: unsupported action '$action'." >&2
      return 1
      ;;
  esac
}

run_index_action() {
  local action="$1"
  local index="$2"
  shift 2

  local resolved_index
  resolved_index="$(resolve_index "$index")" || return 1

  local env_file="${PROJECT_FILES[$resolved_index]}"
  local project_name="${PROJECT_NAMES[$resolved_index]}"

  if [[ "$project_name" == "-" ]]; then
    echo "Error: selected env file is missing COMPOSE_PROJECT_NAME." >&2
    return 1
  fi

  run_project_action "$project_name" "$env_file" "$action" "$@"
}

run_env_action() {
  local action="$1"
  local selector="$2"
  shift 2

  local resolved_index
  resolved_index="$(resolve_project_selector "$selector")" || return 1

  local env_file="${PROJECT_FILES[$resolved_index]}"
  local project_name="${PROJECT_NAMES[$resolved_index]}"

  if [[ "$project_name" == "-" ]]; then
    echo "Error: selected env file is missing COMPOSE_PROJECT_NAME." >&2
    return 1
  fi

  run_project_action "$project_name" "$env_file" "$action" "$@"
}

execute_command() {
  local command="${1:-list}"

  case "$command" in
    help)
      usage
      ;;
    install)
      install_script
      ;;
    list|envs)
      print_projects
      ;;
    up|down|restart|ps|logs|exec|config|pull)
      if [[ $# -lt 2 ]]; then
        echo "Error: '$command' requires a project number." >&2
        return 1
      fi
      run_index_action "$command" "$2" "${@:3}"
      ;;
    env)
      if [[ $# -lt 3 ]]; then
        echo "Error: usage is 'env <action> <project>'." >&2
        return 1
      fi
      run_env_action "$2" "$3" "${@:4}"
      ;;
    exit|quit)
      return 99
      ;;
    *)
      echo "Error: unknown command '$command'." >&2
      return 1
      ;;
  esac
}

interactive_loop() {
  show_info
  echo "Working directory: $COMPOSE_ROOT"
  echo "Compose file: $COMPOSE_FILE"
  echo "Type 'help' for commands."
  echo

  print_projects
  echo

  while true; do
    read -r -p "compose-project> " line || break
    [[ -z "${line// }" ]] && continue

    local -a args=()
    read -r -a args <<<"$line"

    execute_command "${args[@]}"
    local status=$?
    if [[ $status -eq 99 ]]; then
      break
    fi
    if [[ $status -ne 0 ]]; then
      echo
    fi
  done
}

main() {
  require_docker

  if [[ "${1:-}" == "install" ]]; then
    execute_command "$@"
    return
  fi

  ensure_compose_file

  if [[ $# -eq 0 ]]; then
    interactive_loop
  else
    execute_command "$@"
  fi
}

main "$@"
