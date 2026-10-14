#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd -P)
command -v shellcheck >/dev/null || { printf 'lint: ShellCheck is required\n' >&2; exit 1; }
count=0
# Discover by extension or shell shebang, including extensionless helpers/hooks.
# Generated test data lives outside the checkout.
while IFS= read -r -d '' file; do
    first=''
    IFS= read -r first < "$file" || :
    case "$file:$first" in
        *.sh:*|*:'#!/bin/bash'*|*:'#!/usr/bin/env bash'*|*:'#!/bin/sh'*)
            /bin/bash -n "$file"
            shellcheck --shell=bash "$file"
            count=$((count + 1)) ;;
    esac
done < <(find "$repo" -type d \( -name .git -o -name runs \) -prune -o -type f -print0)
[ "$count" -gt 0 ] || { printf 'lint: no shell files found\n' >&2; exit 1; }
printf 'PASS: syntax and ShellCheck (%s shell files)\n' "$count"
