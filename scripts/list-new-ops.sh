#!/usr/bin/env bash

set -Eeuo pipefail
shopt -s failglob
IFS=$'\n\t'

log() { printf -- "** %s\n" "$*" >&2; }
error() { printf -- "** ERROR: %s\n" "$*" >&2; }
fatal() { error "$@"; exit 1; }

declare -a fingerprint_files=()

usage() {
  printf -- 'Usage: %s <target fingerprints> <base fingerprints>...\n' \
    "$(basename -- "${BASH_SOURCE[0]}")"
  printf -- 'Prints the keys of the target that no single base has both the port and the highway\n'
  printf -- 'fingerprint of, one per line and sorted. compare-codegen.sh --fingerprints writes the\n'
  printf -- 'fingerprint files.\n'
  return 0
}

parse_arguments() {
  local option
  while [[ "$#" -gt 0 ]]; do
    option="$1"
    shift
    case "${option}" in
      -h | --help)
        usage
        exit 0
        ;;
      --)
        fingerprint_files+=( "$@" )
        break
        ;;
      -*)
        fatal "Unknown argument '${option}'" "$(usage)"
        ;;
      *)
        fingerprint_files+=( "${option}" )
        ;;
    esac
  done

  if [[ "${#fingerprint_files[@]}" -eq 0 ]]; then
    fatal "Found no fingerprint files to compare" "$(usage)"
  fi
  if [[ "${#fingerprint_files[@]}" -eq 1 ]]; then
    fatal "Found the fingerprints of the target, but none of a base to compare them with" "$(usage)"
  fi
  return 0
}

validate_fingerprint_files() {
  local -n fingerprint_files_ref="${1:?validate_fingerprint_files requires the fingerprint file array}"

  local fingerprint_file
  for fingerprint_file in "${fingerprint_files_ref[@]}"; do
    if [[ ! -f "${fingerprint_file}" ]]; then
      fatal "There is no fingerprint file '${fingerprint_file}'"
    fi
    if [[ ! -s "${fingerprint_file}" ]]; then
      fatal "The fingerprint file '${fingerprint_file}' is empty"
    fi
  done
  return 0
}

list_new_keys() {
  local -n fingerprint_files_ref="${1:?list_new_keys requires the fingerprint file array}"

  if ! awk -F '\t' '
    function quoted(value) {
      return "\047" value "\047"
    }

    function fatal(message) {
      printf "** ERROR: %s\n", message > "/dev/stderr"
      failed = 1
      exit 1
    }

    function is_fingerprint(value) {
      return value == "unresolved" || (length(value) == 64 && value ~ /^[0-9a-f]+$/)
    }

    FNR == 1 {
      file_total++
      file_name[file_total] = FILENAME
      if (NF != 2 || $1 != "target" || $2 !~ /^[A-Z][A-Z0-9_]*$/) {
        description = quoted(FILENAME) " starts with " quoted($0)
        description = description " instead of the target it fingerprints"
        description = description "\nIs it a file compare-codegen.sh --fingerprints wrote?"
        fatal(description)
      }
      file_target[file_total] = $2
      next
    }

    {
      if (NF != 3 || $1 !~ /^[A-Za-z0-9_]+$/ || !is_fingerprint($2) || !is_fingerprint($3)) {
        description = "Line " FNR " of " quoted(FILENAME) " is malformed: " quoted($0)
        description = description "\nIt must be a key, its port fingerprint and its highway"
        description = description " fingerprint, split by tabs, where every fingerprint is a"
        description = description " SHA-256 digest or " quoted("unresolved")
        fatal(description)
      }
      if ((file_total, $1) in port_fingerprint) {
        fatal("Line " FNR " of " quoted(FILENAME) " repeats the key " $1)
      }
      port_fingerprint[file_total, $1] = $2
      highway_fingerprint[file_total, $1] = $3
      key_total[file_total]++
      if (file_total == 1) {
        key_order[key_total[1]] = $1
      }
    }

    END {
      if (failed) {
        exit 1
      }

      target = file_target[1]
      for (file = 1; file <= file_total; file++) {
        if (key_total[file] == 0) {
          fatal(quoted(file_name[file]) " fingerprints no keys")
        }
      }
      for (file = 2; file <= file_total; file++) {
        base = "The base " quoted(file_name[file])
        if (file_target[file] == target) {
          description = base " fingerprints " target ", the target of " quoted(file_name[1])
          fatal(description ", so it would cover every key")
        }
        if (key_total[file] != key_total[1]) {
          description = base " fingerprints " key_total[file] " keys, but the target "
          fatal(description quoted(file_name[1]) " fingerprints " key_total[1])
        }
        for (position = 1; position <= key_total[1]; position++) {
          if (!((file, key_order[position]) in port_fingerprint)) {
            description = base " has no key " key_order[position] ", which the target "
            fatal(description quoted(file_name[1]) " has")
          }
        }
      }

      for (position = 1; position <= key_total[1]; position++) {
        key = key_order[position]
        port = port_fingerprint[1, key]
        highway = highway_fingerprint[1, key]
        covered = 0
        if (port == "unresolved" || highway == "unresolved") {
          unresolved_total++
        } else {
          for (file = 2; file <= file_total; file++) {
            if (port_fingerprint[file, key] == port && highway_fingerprint[file, key] == highway) {
              covered_total[file]++
              covered = 1
            }
          }
        }
        if (!covered) {
          new_total++
          print key
        }
      }

      printf "** %d of %d keys are new on %s, %d of them because they could not be fingerprinted\n",
        new_total, key_total[1], target, unresolved_total > "/dev/stderr"
      for (file = 2; file <= file_total; file++) {
        printf "** %s covers %d keys, as fingerprinted in %s\n",
          file_target[file], covered_total[file], quoted(file_name[file]) > "/dev/stderr"
      }
    }
  ' "${fingerprint_files_ref[@]}" | LC_ALL=C sort; then
    fatal "Failed to list the new keys of '${fingerprint_files_ref[0]}'"
  fi
  return 0
}

main() {
  parse_arguments "$@"
  validate_fingerprint_files fingerprint_files
  list_new_keys fingerprint_files
  return 0
}

main "$@"
