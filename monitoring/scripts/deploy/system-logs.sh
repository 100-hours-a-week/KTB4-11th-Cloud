#!/usr/bin/env bash
# Source before installing agent configs; do not create host journal directories.
detect_system_journal() {
  local root_dir="${1:-}" candidate journal_file
  for candidate in /var/log/journal /run/log/journal; do
    if [[ -d "$root_dir$candidate" ]]; then
      journal_file=$(find "$root_dir$candidate" -type f -name '*.journal' -print -quit) || return 1
      if [[ -n "$journal_file" ]]; then
        printf '/host%s\n' "$candidate"
        return 0
      fi
    fi
  done
  printf 'No host system journal found; agent configuration was not installed. Check journald storage first.\n' >&2
  return 1
}
