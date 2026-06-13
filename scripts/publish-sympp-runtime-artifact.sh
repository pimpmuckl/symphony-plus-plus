#!/usr/bin/env bash
set -euo pipefail

manifest_path=""
channel="stable"
published_artifact_url=""
published_manifest_url=""
channel_output_path="artifacts/sympp-runtime-channel.json"
dry_run=0

usage() {
  cat <<'USAGE'
Validates a built Symphony++ runtime artifact manifest before advancing a release channel.

Publishing is intentionally separate from building. Non-dry-run channel output
requires already-published artifact and manifest URLs, so marketplace users
cannot be pointed at a local or unvalidated artifact.

Usage:
  scripts/publish-sympp-runtime-artifact.sh --manifest <manifest.json> --published-artifact-url <url> --published-manifest-url <url> [--channel stable]
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest)
      manifest_path="${2:-}"
      shift 2
      ;;
    --channel)
      channel="${2:-}"
      shift 2
      ;;
    --published-artifact-url)
      published_artifact_url="${2:-}"
      shift 2
      ;;
    --published-manifest-url)
      published_manifest_url="${2:-}"
      shift 2
      ;;
    --channel-output)
      channel_output_path="${2:-}"
      shift 2
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n "${manifest_path// }" ]] || { echo "--manifest is required." >&2; exit 2; }
[[ -f "$manifest_path" ]] || { echo "Artifact manifest is missing: $manifest_path" >&2; exit 1; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
python_bin="$(command -v python3 || command -v python || true)"
[[ -n "$python_bin" ]] || { echo "Required command was not found on PATH: python3 or python" >&2; exit 1; }

"$python_bin" - "$manifest_path" "$channel" "$published_artifact_url" "$published_manifest_url" "$channel_output_path" "$repo_root" "$dry_run" <<'PY'
import datetime
import hashlib
import json
import os
import re
import sys
from urllib.parse import urlparse

manifest_path, channel, artifact_url, manifest_url, channel_output_path, repo_root, dry_run = sys.argv[1:8]
dry_run = dry_run == "1"

def fail(message):
    raise SystemExit(message)

def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

def require_url(value, label):
    if not value.strip():
        fail(f"{label} is required for release-channel advancement.")
    parsed = urlparse(value)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        fail(f"{label} must be an http(s) URL.")

with open(manifest_path, "r", encoding="utf-8") as handle:
    manifest = json.load(handle)

if manifest.get("status") != "built":
    fail("Artifact manifest status must be 'built'.")

revision = str(manifest.get("source_revision", ""))
if not re.fullmatch(r"[0-9a-f]{40}", revision):
    fail("Artifact manifest source_revision must be a 40-character SHA.")

artifact = manifest.get("artifact") or {}
artifact_file = str(artifact.get("file", ""))
expected_sha = str(artifact.get("sha256", "")).lower()
if not re.fullmatch(r"[0-9a-f]{64}", expected_sha):
    fail("Artifact manifest artifact.sha256 must be a SHA256 hex digest.")

artifact_path = os.path.join(os.path.dirname(os.path.abspath(manifest_path)), artifact_file)
if not os.path.isfile(artifact_path):
    fail(f"Artifact package referenced by manifest is missing: {artifact_path}")

actual_sha = sha256(artifact_path)
if actual_sha != expected_sha:
    fail(f"Artifact package SHA256 mismatch. Expected {expected_sha}, got {actual_sha}.")

if dry_run:
    print(f"Dry run: validated {manifest_path} and {artifact_path} for channel '{channel}'.")
    raise SystemExit(0)

require_url(artifact_url, "published-artifact-url")
require_url(manifest_url, "published-manifest-url")

channel_doc = {
    "schema_version": 1,
    "channel": channel,
    "advanced_at": datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"),
    "source_revision": revision,
    "platform": str(manifest.get("platform", "")),
    "artifact": {
        "url": artifact_url,
        "sha256": expected_sha,
        "size_bytes": artifact.get("size_bytes"),
    },
    "manifest": {
        "url": manifest_url,
        "sha256": sha256(manifest_path),
    },
    "launcher_contract": manifest.get("launcher_contract"),
}

if not os.path.isabs(channel_output_path):
    channel_output_path = os.path.join(repo_root, channel_output_path)

os.makedirs(os.path.dirname(channel_output_path), exist_ok=True)
with open(channel_output_path, "w", encoding="utf-8", newline="\n") as handle:
    json.dump(channel_doc, handle, indent=2)
    handle.write("\n")

print(f"Wrote release channel manifest {channel_output_path}")
PY
