#!/usr/bin/env bash
echo "JDK 17 已不足以运行现行 Jenkins LTS，请改用 set-default-jdk21.sh" >&2
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${SCRIPT_DIR}/set-default-jdk21.sh" "$@"