#!/usr/bin/env sh
set -eu

usage() {
  printf '%s\n' 'Usage: sympp-worker-secret.sh run-mcp-local-file --path <secret-file> --claimed-by <worker-id> [--database <sqlite-path>] [--elixir-dir <dir>]' >&2
}

if [ "$#" -lt 1 ]; then
  usage
  exit 2
fi

ACTION=$1
shift

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
ELIXIR_DIR=$(CDPATH= cd "$SCRIPT_DIR/../elixir" && pwd)
SECRET_PATH=
DATABASE=
CLAIMED_BY=

case "$ACTION" in
  run-mcp-local-file)
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --path)
          [ "$#" -ge 2 ] || { usage; exit 2; }
          SECRET_PATH=$2
          shift 2
          ;;
        --database)
          [ "$#" -ge 2 ] || { usage; exit 2; }
          DATABASE=$2
          shift 2
          ;;
        --claimed-by)
          [ "$#" -ge 2 ] || { usage; exit 2; }
          CLAIMED_BY=$2
          shift 2
          ;;
        --elixir-dir)
          [ "$#" -ge 2 ] || { usage; exit 2; }
          ELIXIR_DIR=$2
          shift 2
          ;;
        *)
          usage
          exit 2
          ;;
      esac
    done
    ;;
  *)
    usage
    exit 2
    ;;
esac

if [ -z "$SECRET_PATH" ] || [ -z "$CLAIMED_BY" ]; then
  usage
  exit 2
fi

if [ ! -f "$SECRET_PATH" ]; then
  printf '%s\n' 'Worker secret file was not found.' >&2
  exit 1
fi

SECRET=$(cat "$SECRET_PATH")

if [ -z "$SECRET" ]; then
  printf '%s\n' 'Worker secret file was empty.' >&2
  exit 1
fi

cd "$ELIXIR_DIR"
export SYMPP_WORK_KEY_SECRET="$SECRET"

if [ -n "$DATABASE" ]; then
  exec mise exec -- mix sympp.mcp --mode stdio --database "$DATABASE" --work-key-secret-env SYMPP_WORK_KEY_SECRET --claimed-by "$CLAIMED_BY"
fi

exec mise exec -- mix sympp.mcp --mode stdio --work-key-secret-env SYMPP_WORK_KEY_SECRET --claimed-by "$CLAIMED_BY"
