#!/usr/bin/env sh
set -eu

usage() {
  printf '%s\n' 'Usage: sympp-worker-secret.sh run-mcp-local-file --path <secret-file> --claimed-by <worker-id> [--database <sqlite-path>] [--elixir-dir <dir>]' >&2
  printf '%s\n' '       sympp-worker-secret.sh run-mcp-local-file-once --path <secret-file> --claimed-by <worker-id> --input-file <jsonl> [--output-file <jsonl>] [--error-file <txt>] [--database <sqlite-path>] [--elixir-dir <dir>]' >&2
}

json_escape() {
  printf '%s' "$1" | awk 'BEGIN { ORS = "" } { gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\r/, "\\r"); gsub(/\t/, "\\t"); if (NR > 1) { printf "\\n" } printf "%s", $0 }'
}

CALLER_CWD=${PWD:-}
case "$CALLER_CWD" in
  /*) ;;
  *) CALLER_CWD=$(pwd) ;;
esac

make_absolute_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$CALLER_CWD" "$1" ;;
  esac
}

normalize_path_segments() {
  awk -v path="$1" 'BEGIN {
    count = split(path, parts, "/")
    out = ""

    for (i = 1; i <= count; i++) {
      part = parts[i]

      if (part == "" || part == ".") {
        continue
      }

      if (part == "..") {
        sub("/[^/]+$", "", out)
        continue
      }

      out = out "/" part
    }

    if (out == "") {
      out = "/"
    }

    print out
  }'
}

canonical_path() {
  path=$(make_absolute_path "$1")
  parent=$(dirname "$path")
  base=$(basename "$path")

  if resolved_parent=$(CDPATH= cd "$parent" 2>/dev/null && pwd -P); then
    printf '%s/%s\n' "$resolved_parent" "$base"
  else
    normalize_path_segments "$path"
  fi
}

has_symlink_ancestor() {
  path=$(make_absolute_path "$1")
  parent=$(dirname "$path")
  parts=${parent#/}
  current=
  old_ifs=$IFS
  IFS=/
  set -- $parts
  IFS=$old_ifs

  for part do
    if [ -z "$part" ]; then
      continue
    fi

    current=$current/$part
    if [ -L "$current" ]; then
      return 0
    fi
  done

  return 1
}

prepare_spool_file() {
  parent=$(dirname "$1")
  old_umask=$(umask)
  restore_noclobber=1
  case $- in
    *C*) restore_noclobber=0 ;;
  esac
  umask 077

  mkdir -p "$parent" 2>/dev/null || {
    umask "$old_umask"
    return 1
  }

  set -C
  : > "$1" 2>/dev/null || {
    if [ "$restore_noclobber" -eq 1 ]; then
      set +C
    fi

    umask "$old_umask"
    return 1
  }

  if [ "$restore_noclobber" -eq 1 ]; then
    set +C
  fi

  chmod 600 "$1" 2>/dev/null || {
    umask "$old_umask"
    return 1
  }

  umask "$old_umask"
}

kill_process_tree() {
  signal=$1
  pid=$2

  if command -v pgrep >/dev/null 2>&1; then
    for child_pid in $(pgrep -P "$pid" 2>/dev/null); do
      kill_process_tree "$signal" "$child_pid"
    done
  fi

  kill "$signal" "$pid" 2>/dev/null
}

emit_one_shot_summary() {
  summary_status=$1
  summary_exit_code=$2

  if [ -f "$OUTPUT_FILE" ]; then
    summary_stdout_bytes=$(wc -c < "$OUTPUT_FILE" | tr -d ' ')
  else
    summary_stdout_bytes=0
  fi

  if [ -f "$ERROR_FILE" ]; then
    summary_stderr_bytes=$(wc -c < "$ERROR_FILE" | tr -d ' ')
  else
    summary_stderr_bytes=0
  fi

  output_file_json=$(json_escape "$OUTPUT_FILE")
  error_file_json=$(json_escape "$ERROR_FILE")
  printf '{"status":"%s","exit_code":%s,"output_file":"%s","error_file":"%s","stdout_bytes":%s,"stderr_bytes":%s}\n' \
    "$summary_status" "$summary_exit_code" "$output_file_json" "$error_file_json" "$summary_stdout_bytes" "$summary_stderr_bytes"
  exit "$summary_exit_code"
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
INPUT_FILE=
OUTPUT_FILE=
ERROR_FILE=

case "$ACTION" in
  run-mcp-local-file|run-mcp-local-file-once)
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
        --input-file)
          [ "$#" -ge 2 ] || { usage; exit 2; }
          INPUT_FILE=$2
          shift 2
          ;;
        --output-file)
          [ "$#" -ge 2 ] || { usage; exit 2; }
          OUTPUT_FILE=$2
          shift 2
          ;;
        --error-file)
          [ "$#" -ge 2 ] || { usage; exit 2; }
          ERROR_FILE=$2
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

if [ "$ACTION" = "run-mcp-local-file-once" ] && [ -z "$INPUT_FILE" ]; then
  usage
  exit 2
fi

if [ "$ACTION" = "run-mcp-local-file-once" ]; then
  SPOOL_STATUS=
  PATH_STATUS=
  OUTPUT_FILE_GENERATED=0
  ERROR_FILE_GENERATED=0

  if [ -z "$OUTPUT_FILE" ] || [ -z "$ERROR_FILE" ]; then
    TEMP_ROOT=${TMPDIR:-/tmp}

    if TEMP_ROOT=$(CDPATH= cd "$TEMP_ROOT" 2>/dev/null && pwd -P) && SPOOL_DIR=$(mktemp -d "$TEMP_ROOT/sympp-mcp.XXXXXX" 2>/dev/null); then
      if [ -z "$OUTPUT_FILE" ]; then
        OUTPUT_FILE=$SPOOL_DIR/stdout.jsonl
        OUTPUT_FILE_GENERATED=1
      fi

      if [ -z "$ERROR_FILE" ]; then
        ERROR_FILE=$SPOOL_DIR/stderr.txt
        ERROR_FILE_GENERATED=1
      fi
    else
      SPOOL_STATUS=launch_failed
    fi
  fi

  if has_symlink_ancestor "$SECRET_PATH" || has_symlink_ancestor "$INPUT_FILE"; then
    PATH_STATUS=invalid_paths
  fi

  if [ -n "$OUTPUT_FILE" ]; then
    if [ "$OUTPUT_FILE_GENERATED" -eq 0 ]; then
      if has_symlink_ancestor "$OUTPUT_FILE"; then
        PATH_STATUS=invalid_paths
      fi

      OUTPUT_FILE=$(canonical_path "$OUTPUT_FILE")
    else
      OUTPUT_FILE=$(canonical_path "$OUTPUT_FILE")

      if has_symlink_ancestor "$OUTPUT_FILE"; then
        PATH_STATUS=invalid_paths
      fi
    fi
  fi

  if [ -n "$ERROR_FILE" ]; then
    if [ "$ERROR_FILE_GENERATED" -eq 0 ]; then
      if has_symlink_ancestor "$ERROR_FILE"; then
        PATH_STATUS=invalid_paths
      fi

      ERROR_FILE=$(canonical_path "$ERROR_FILE")
    else
      ERROR_FILE=$(canonical_path "$ERROR_FILE")

      if has_symlink_ancestor "$ERROR_FILE"; then
        PATH_STATUS=invalid_paths
      fi
    fi
  fi

  if [ -n "$OUTPUT_FILE" ] && { [ -e "$OUTPUT_FILE" ] || [ -L "$OUTPUT_FILE" ]; }; then
    PATH_STATUS=invalid_paths
  fi

  if [ -n "$ERROR_FILE" ] && { [ -e "$ERROR_FILE" ] || [ -L "$ERROR_FILE" ]; }; then
    PATH_STATUS=invalid_paths
  fi

  if [ "$SPOOL_STATUS" = "launch_failed" ]; then
    emit_one_shot_summary launch_failed 127
  fi

  if [ "$PATH_STATUS" = "invalid_paths" ]; then
    emit_one_shot_summary invalid_paths 2
  fi
fi

SECRET_PATH=$(canonical_path "$SECRET_PATH")

if [ ! -f "$SECRET_PATH" ]; then
  if [ "$ACTION" = "run-mcp-local-file-once" ]; then
    emit_one_shot_summary launch_failed 1
  fi

  printf '%s\n' 'Worker secret file was not found.' >&2
  exit 1
fi

if [ "$ACTION" = "run-mcp-local-file-once" ] && [ -L "$SECRET_PATH" ]; then
  emit_one_shot_summary invalid_paths 2
fi

SECRET=$(cat "$SECRET_PATH")

if [ -z "$SECRET" ]; then
  if [ "$ACTION" = "run-mcp-local-file-once" ]; then
    emit_one_shot_summary launch_failed 1
  fi

  printf '%s\n' 'Worker secret file was empty.' >&2
  exit 1
fi

if [ "$ACTION" = "run-mcp-local-file-once" ]; then
  INPUT_FILE=$(canonical_path "$INPUT_FILE")

  if [ ! -f "$INPUT_FILE" ]; then
    emit_one_shot_summary launch_failed 1
  fi

  SUMMARY_STATUS=

  if [ -L "$SECRET_PATH" ] || [ -L "$INPUT_FILE" ] || [ -L "$OUTPUT_FILE" ] || [ -L "$ERROR_FILE" ]; then
    STATUS=2
    SUMMARY_STATUS=invalid_paths
  elif [ "$INPUT_FILE" = "$OUTPUT_FILE" ] || [ "$INPUT_FILE" = "$ERROR_FILE" ] || [ "$OUTPUT_FILE" = "$ERROR_FILE" ] || [ "$SECRET_PATH" = "$INPUT_FILE" ] || [ "$SECRET_PATH" = "$OUTPUT_FILE" ] || [ "$SECRET_PATH" = "$ERROR_FILE" ]; then
    STATUS=2
    SUMMARY_STATUS=invalid_paths
  elif ! prepare_spool_file "$OUTPUT_FILE" || ! prepare_spool_file "$ERROR_FILE"; then
    STATUS=127
    SUMMARY_STATUS=launch_failed
  elif ! cd "$ELIXIR_DIR" 2>/dev/null; then
    STATUS=127
    SUMMARY_STATUS=launch_failed
  else
    TIMEOUT_SECONDS=${SYMPP_MCP_ONCE_TIMEOUT_SECONDS:-60}
    case "$TIMEOUT_SECONDS" in
      ''|*[!0-9]*) TIMEOUT_SECONDS=60 ;;
    esac

    TIMEOUT_FILE=$OUTPUT_FILE.timeout.$$
    rm -f "$TIMEOUT_FILE"
    set +e
    if command -v setsid >/dev/null 2>&1; then
      PROCESS_GROUP=1
      if [ -n "$DATABASE" ]; then
        SYMPP_WORK_KEY_SECRET=$SECRET setsid mise exec -- mix sympp.mcp --mode stdio --database "$DATABASE" --work-key-secret-env SYMPP_WORK_KEY_SECRET --claimed-by "$CLAIMED_BY" < "$INPUT_FILE" > "$OUTPUT_FILE" 2> "$ERROR_FILE" &
      else
        SYMPP_WORK_KEY_SECRET=$SECRET setsid mise exec -- mix sympp.mcp --mode stdio --work-key-secret-env SYMPP_WORK_KEY_SECRET --claimed-by "$CLAIMED_BY" < "$INPUT_FILE" > "$OUTPUT_FILE" 2> "$ERROR_FILE" &
      fi
    else
      PROCESS_GROUP=0
      if [ -n "$DATABASE" ]; then
        SYMPP_WORK_KEY_SECRET=$SECRET mise exec -- mix sympp.mcp --mode stdio --database "$DATABASE" --work-key-secret-env SYMPP_WORK_KEY_SECRET --claimed-by "$CLAIMED_BY" < "$INPUT_FILE" > "$OUTPUT_FILE" 2> "$ERROR_FILE" &
      else
        SYMPP_WORK_KEY_SECRET=$SECRET mise exec -- mix sympp.mcp --mode stdio --work-key-secret-env SYMPP_WORK_KEY_SECRET --claimed-by "$CLAIMED_BY" < "$INPUT_FILE" > "$OUTPUT_FILE" 2> "$ERROR_FILE" &
      fi
    fi

    CHILD_PID=$!
    unset SECRET

    (
      sleep "$TIMEOUT_SECONDS"

      if kill -0 "$CHILD_PID" 2>/dev/null; then
        printf '%s\n' timed_out > "$TIMEOUT_FILE"

        if [ "$PROCESS_GROUP" -eq 1 ]; then
          kill -TERM "-$CHILD_PID" 2>/dev/null
        else
          kill_process_tree -TERM "$CHILD_PID"
        fi

        sleep 1

        if [ "$PROCESS_GROUP" -eq 1 ]; then
          kill -KILL "-$CHILD_PID" 2>/dev/null
        else
          kill_process_tree -KILL "$CHILD_PID"
        fi
      fi
    ) &
    TIMER_PID=$!

    wait "$CHILD_PID"
    STATUS=$?

    if [ -f "$TIMEOUT_FILE" ]; then
      STATUS=124
      SUMMARY_STATUS=timed_out
    fi

    kill "$TIMER_PID" 2>/dev/null
    wait "$TIMER_PID" 2>/dev/null
    rm -f "$TIMEOUT_FILE"
    set -e
  fi

  if [ -f "$OUTPUT_FILE" ]; then
    STDOUT_BYTES=$(wc -c < "$OUTPUT_FILE" | tr -d ' ')
    OUTPUT_FILE_READY=1
  else
    STDOUT_BYTES=0
    OUTPUT_FILE_READY=0
  fi

  if [ -f "$ERROR_FILE" ]; then
    STDERR_BYTES=$(wc -c < "$ERROR_FILE" | tr -d ' ')
    ERROR_FILE_READY=1
  else
    STDERR_BYTES=0
    ERROR_FILE_READY=0
  fi

  if [ -z "$SUMMARY_STATUS" ] && { [ "$STATUS" -eq 126 ] || [ "$STATUS" -eq 127 ] || [ "$OUTPUT_FILE_READY" -eq 0 ] || [ "$ERROR_FILE_READY" -eq 0 ]; }; then
    SUMMARY_STATUS=launch_failed
  elif [ -z "$SUMMARY_STATUS" ]; then
    SUMMARY_STATUS=completed
  fi

  OUTPUT_FILE_JSON=$(json_escape "$OUTPUT_FILE")
  ERROR_FILE_JSON=$(json_escape "$ERROR_FILE")
  printf '{"status":"%s","exit_code":%s,"output_file":"%s","error_file":"%s","stdout_bytes":%s,"stderr_bytes":%s}\n' \
    "$SUMMARY_STATUS" "$STATUS" "$OUTPUT_FILE_JSON" "$ERROR_FILE_JSON" "$STDOUT_BYTES" "$STDERR_BYTES"
  exit "$STATUS"
fi

cd "$ELIXIR_DIR"
export SYMPP_WORK_KEY_SECRET="$SECRET"

if [ -n "$DATABASE" ]; then
  exec mise exec -- mix sympp.mcp --mode stdio --database "$DATABASE" --work-key-secret-env SYMPP_WORK_KEY_SECRET --claimed-by "$CLAIMED_BY"
fi

exec mise exec -- mix sympp.mcp --mode stdio --work-key-secret-env SYMPP_WORK_KEY_SECRET --claimed-by "$CLAIMED_BY"
