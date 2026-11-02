#!/usr/bin/env bash

set -Eeuo pipefail
shopt -s failglob
IFS=$'\n\t'

log() { printf -- "** %s\n" "$*" >&2; }
error() { printf -- "** ERROR: %s\n" "$*" >&2; }
fatal() { error "$@"; exit 1; }

export LC_ALL=C

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly repository_root
readonly vendor_root="${repository_root}/HighwayReference/CHighway"

# The upstream files whose implementation of each op the generated C ops reproduce.
readonly -a followed_implementations=(
  "${vendor_root}/include/hwy/ops/arm_neon-inl.h"
  "${vendor_root}/include/hwy/ops/arm_sve-inl.h"
  "${vendor_root}/include/hwy/ops/x86_128-inl.h"
  "${vendor_root}/include/hwy/ops/x86_256-inl.h"
  "${vendor_root}/include/hwy/ops/x86_512-inl.h"
  "${vendor_root}/include/hwy/ops/x86_avx3-inl.h"
  "${vendor_root}/include/hwy/ops/emu128-inl.h"
  "${vendor_root}/include/hwy/ops/generic_ops-inl.h"
)

# Highway's quick reference writes the name of every op it documents in bold.
documented_names() {
  local quick_reference="${1:?documented_names requires the path of a highway quick_reference.md}"

  if [[ ! -f "${quick_reference}" ]]; then
    fatal "There is no '${quick_reference}' to read highway's ops from"
  fi

  local bold_names
  if ! bold_names="$(grep -o '\*\*[A-Z][A-Za-z0-9_]*\*\*' "${quick_reference}")"; then
    fatal "Found no op names in '${quick_reference}'"
  fi

  printf -- '%s\n' "${bold_names}" | tr -d '*' | sort -u
  return 0
}

print_names() {
  local title="${1:?print_names requires the title of the list}"
  local names="${2?print_names requires the names to list, which may be empty}"

  printf -- '### %s\n\n' "${title}"
  if [[ -z "${names}" ]]; then
    printf -- '%s\n\n' "None."
    return 0
  fi

  local name
  while IFS= read -r name; do
    printf -- '%s\n' "- \`${name}\`"
  done <<< "${names}"
  printf -- '\n'
  return 0
}

print_implementation_changes() {
  printf -- '### %s\n\n' "Changes to the implementations the C ops reproduce"

  local changes
  if ! changes="$(git -C "${repository_root}" diff --stat -- "${followed_implementations[@]}")"; then
    fatal "Failed to diff the implementations the C ops reproduce"
  fi

  if [[ -z "${changes}" ]]; then
    printf -- '%s\n' "None."
    return 0
  fi

  printf -- '%s\n' '```' "${changes}" '```'
  return 0
}

# Every '<TARGET>.txt' is what scripts/compare-codegen.sh printed for a target, next to its status.
print_codegen_comparisons() {
  local reports_directory="${1:?print_codegen_comparisons requires the directory of the reports}"

  printf -- '\n### %s\n\n' "Codegen of the ops against highway's"

  local -a report_files=()
  local report_file
  while IFS= read -r -d '' report_file; do
    report_files+=( "${report_file}" )
  done < <(find "${reports_directory}" -maxdepth 1 -type f -name '*.txt' -print0 | sort -z)
  if [[ "${#report_files[@]}" -eq 0 ]]; then
    fatal "Found no codegen comparison reports in '${reports_directory}'"
  fi

  local target status_file status
  for report_file in "${report_files[@]}"; do
    target="$(basename -- "${report_file}" .txt)"
    status_file="${report_file%.txt}.status"
    if [[ ! -f "${status_file}" ]]; then
      fatal "There is no '${status_file}' with the exit status of the ${target} comparison"
    fi
    status="$(< "${status_file}")"

    if [[ "${status}" == "0" ]]; then
      printf -- '%s\n' "- ${target}: every op compiles to the same code as highway's ✅"
    elif grep -q '^Summary of ' "${report_file}"; then
      printf -- '%s\n' "- ${target}: some ops no longer compile to the same code as highway's ❌"
    else
      printf -- '%s\n' "- ${target}: the comparison failed with status ${status} 🛑"
      continue
    fi

    printf -- '%s\n' '```'
    grep -E '^[A-Za-z0-9_]+ +port=[0-9]+ +highway=[0-9]+ +(shorter|longer|different)' \
      "${report_file}" || true
    sed -n '/^Summary of /,$p' "${report_file}"
    printf -- '%s\n' '```'
  done
  return 0
}

main() {
  local -r usage="Usage: highway-update-report.sh <previous quick_reference.md> <codegen reports>"
  local previous_quick_reference="${1:?${usage}}"
  local codegen_reports_directory="${2:?${usage}}"

  local previous_names current_names
  previous_names="$(documented_names "${previous_quick_reference}")"
  current_names="$(documented_names "${vendor_root}/quick_reference.md")"

  local added removed
  added="$(comm -13 <(printf -- '%s\n' "${previous_names}") <(printf -- '%s\n' "${current_names}"))"
  removed="$(comm -23 <(printf -- '%s\n' "${previous_names}") <(printf -- '%s\n' "${current_names}"))"

  print_names "Ops highway added" "${added}"
  print_names "Ops highway removed" "${removed}"
  print_implementation_changes
  print_codegen_comparisons "${codegen_reports_directory}"
  return 0
}

main "$@"
