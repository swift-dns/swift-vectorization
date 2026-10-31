#!/usr/bin/env bash

set -Eeuo pipefail
shopt -s failglob
IFS=$'\n\t'

log() { printf -- "** %s\n" "$*" >&2; }
error() { printf -- "** ERROR: %s\n" "$*" >&2; }
fatal() { error "$@"; exit 1; }

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly repository_root
readonly package_root="${repository_root}/HighwayReference"
readonly allowlist_path="${repository_root}/scripts/codegen-allowlist.txt"
readonly normalize_script="${repository_root}/scripts/normalize-disassembly.sh"
readonly allowlist_entry_pattern='^([A-Z][A-Z0-9_]*)[[:space:]]+([A-Za-z0-9_]+)[[:space:]]+[^[:space:]]'
readonly target_name="HighwayReferenceCodegen"
readonly host_dependent_target="EMU128"

architecture=""
verbose="false"
declare -a extra_build_arguments=()
workspace=""

cleanup() {
  if [[ -n "${workspace}" && -d "${workspace}" ]]; then
    rm -rf -- "${workspace}"
  fi
  return 0
}

usage() {
  printf -- 'Usage: %s [--arch <arch>] [--verbose] [-- <extra swift build arguments>]\n' \
    "$(basename -- "${BASH_SOURCE[0]}")"
  return 0
}

require_command() {
  local command_name="${1:?require_command requires the name of the command}"

  if ! command -v "${command_name}" > /dev/null 2>&1; then
    fatal "'${command_name}' is required by $(basename -- "${BASH_SOURCE[0]}") but is not installed"
  fi
  return 0
}

parse_arguments() {
  local option
  while [[ "$#" -gt 0 ]]; do
    option="$1"
    shift
    case "${option}" in
      --arch)
        architecture="${1:?--arch requires the architecture to build for, e.g. 'x86_64'}"
        shift
        ;;
      --verbose)
        verbose="true"
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      --)
        extra_build_arguments=( "$@" )
        break
        ;;
      *)
        fatal "Unknown argument '${option}'" "$(usage)"
        ;;
    esac
  done
  return 0
}

validate_allowlist() {
  local allowlist_file="${1:?validate_allowlist requires the allowlist file}"

  if [[ ! -f "${allowlist_file}" ]]; then
    fatal "There is no '${allowlist_file}' to read the allowlisted functions from" \
      "Every line of it is '<TARGET> <Function> <reason>'" \
      "It is empty when nothing is allowlisted"
  fi

  local -A line_of_entry=()
  local line entry_key
  local line_number=0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line_number=$(( line_number + 1 ))

    if [[ ! "${line}" =~ ${allowlist_entry_pattern} ]]; then
      fatal "Line ${line_number} of '${allowlist_file}' is malformed: '${line}'" \
        "It must be '<TARGET> <Function> <reason>'" \
        "For example: 'NEON FirstLanesU8 the reason it differs'" \
        "Blank lines and comments are not allowed"
    fi

    if [[ "${BASH_REMATCH[1]}" == "${host_dependent_target}" ]]; then
      fatal "Line ${line_number} of '${allowlist_file}' allowlists '${BASH_REMATCH[2]}'" \
        "on ${host_dependent_target}, whose instructions depend on the host architecture" \
        "It must name the host: '${host_dependent_target}_ARM64' or '${host_dependent_target}_X86_64'"
    fi

    entry_key="${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
    if [[ -n "${line_of_entry["${entry_key}"]:-}" ]]; then
      fatal "Line ${line_number} of '${allowlist_file}' repeats '${entry_key}'," \
        "which line ${line_of_entry["${entry_key}"]} already allowlists"
    fi
    line_of_entry["${entry_key}"]="${line_number}"
  done < "${allowlist_file}"
  return 0
}

architecture_key() {
  local requested_architecture="${1:-}"

  local machine="${requested_architecture}"
  if [[ -z "${machine}" ]] && ! machine="$(uname -m)"; then
    fatal "Failed to tell which architecture this host is"
  fi

  case "${machine}" in
    arm64 | aarch64)
      printf -- 'ARM64\n'
      ;;
    x86_64 | amd64)
      printf -- 'X86_64\n'
      ;;
    *)
      fatal "Cannot name the architecture '${machine}' in the ${host_dependent_target} allowlist entries" \
        "Only 'arm64', 'aarch64', 'x86_64' and 'amd64' are known"
      ;;
  esac
  return 0
}

build_target() {
  local -n build_arguments_ref="${1:?build_target requires the name of the build argument array}"

  log "Building ${target_name}..."
  if ! swift build "${build_arguments_ref[@]}" >&2; then
    fatal "Failed to build '${target_name}' of '${package_root#"${repository_root}/"}'"
  fi
  return 0
}

binary_path() {
  local -n build_arguments_ref="${1:?binary_path requires the name of the build argument array}"

  local path
  if ! path="$(swift build "${build_arguments_ref[@]}" --show-bin-path)"; then
    fatal "Failed to resolve where '${target_name}' is built to"
  fi

  printf -- '%s\n' "${path}"
  return 0
}

normalize_object_files() {
  local -n object_files_ref="${1:?normalize_object_files requires the object file array}"

  if ! "${normalize_script}" -- "${object_files_ref[@]}"; then
    fatal "Failed to normalize the disassembly of the object files of '${target_name}'"
  fi
  return 0
}

remove_object_files() {
  local binary_directory="${1:?remove_object_files requires the binary directory}"

  local object_directory="${binary_directory}/${target_name}.build"
  if [[ -d "${object_directory}" ]]; then
    find "${object_directory}" -name '*.o' -type f -delete
  fi
  return 0
}

find_object_files() {
  local binary_directory="${1:?find_object_files requires the binary directory}"

  local object_directory="${binary_directory}/${target_name}.build"
  if [[ ! -d "${object_directory}" ]]; then
    fatal "There is no '${object_directory}' to read the object files of '${target_name}' from"
  fi

  find "${object_directory}" -name '*.o' -type f -print0 | sort -z
  return 0
}

demangle_symbols() {
  local listing_file="${1:?demangle_symbols requires the disassembly listing}"
  local symbols_file="${2:?demangle_symbols requires the file to write the symbols to}"
  local demangled_file="${3:?demangle_symbols requires the file to write the demangled names to}"

  if ! sed -n 's|^<\(.*\)>:$|\1|p' "${listing_file}" > "${symbols_file}"; then
    fatal "Failed to read the symbols out of '${listing_file}'"
  fi
  if ! swift demangle --simplified < "${symbols_file}" > "${demangled_file}"; then
    fatal "Failed to demangle the symbols of '${listing_file}'"
  fi
  paste "${symbols_file}" "${demangled_file}"
  return 0
}

compare_functions() {
  local names_file="${1:?compare_functions requires the file of symbols and demangled names}"
  local listing_file="${2:?compare_functions requires the disassembly listing}"
  local allowlist_file="${3:?compare_functions requires the allowlist file}"
  local show_listings="${4:?compare_functions requires whether to print the listings}"
  local host_architecture_key="${5:?compare_functions requires the key of the host architecture}"

  if ! awk -F '\t' \
    -v names_file="${names_file}" \
    -v allowlist_file="${allowlist_file}" \
    -v allowlist_name="${allowlist_file#"${repository_root}/"}" \
    -v show_listings="${show_listings}" \
    -v host_dependent_target="${host_dependent_target}" \
    -v host_architecture_key="${host_architecture_key}" '
    function keyed_target(target) {
      if (target == host_dependent_target) {
        return target "_" host_architecture_key
      }
      return target
    }

    function trimmed_length(function_name,    length_without_padding) {
      length_without_padding = instruction_count[function_name]
      while (length_without_padding > 0 &&
             mnemonic[function_name, length_without_padding] ~ /^nop/) {
        length_without_padding--
      }
      return length_without_padding
    }

    function count_matching(function_name, total, pattern,    matched, position) {
      matched = 0
      for (position = 1; position <= total; position++) {
        if (mnemonic[function_name, position] ~ pattern) {
          matched++
        }
      }
      return matched
    }

    function same_instructions(first, second, total,    position) {
      for (position = 1; position <= total; position++) {
        if (instruction[first, position] != instruction[second, position]) {
          return 0
        }
      }
      return 1
    }

    function print_listing(label, function_name, total,    position) {
      printf "  %s\n", label
      for (position = 1; position <= total; position++) {
        printf "    %s\n", instruction[function_name, position]
      }
    }

    function print_count(label, count) {
      printf "  %-12s %d\n", label, count
    }

    FILENAME == allowlist_file {
      split($0, entry_fields, " ")
      allowlist_total++
      allowlist_target[allowlist_total] = entry_fields[1]
      allowlist_function[allowlist_total] = entry_fields[2]
      allowlist_line[allowlist_total] = FNR
      next
    }

    FILENAME == names_file {
      base_name = $2
      sub(/\(.*$/, "", base_name)
      if (base_name ~ /^(port|highway)[A-Z]/) {
        function_of_symbol[$1] = base_name
      }
      if (highway_target == "" && base_name ~ /^highway/ && match($1, /N_[A-Z0-9_]+O[0-9]/)) {
        highway_target = substr($1, RSTART + 2, RLENGTH - 2)
        sub(/O[0-9]+$/, "", highway_target)
      }
      next
    }

    /^<.*>:$/ {
      symbol = substr($0, 2, length($0) - 3)
      if (instruction_seen) {
        current_function = ""
        instruction_seen = 0
      }
      if (current_function == "" && (symbol in function_of_symbol)) {
        current_function = function_of_symbol[symbol]
        if (current_function in instruction_count) {
          printf "** ERROR: %s is defined more than once\n", current_function > "/dev/stderr"
          failed = 1
        }
        instruction_count[current_function] = 0
        if (current_function ~ /^port/) {
          port_order[++port_total] = current_function
        }
      }
      next
    }

    /^[[:space:]]+[^[:space:]]/ {
      instruction_seen = 1
      if (current_function != "") {
        text = $0
        sub(/^[[:space:]]+/, "", text)
        name = text
        sub(/[[:space:]].*$/, "", name)
        position = ++instruction_count[current_function]
        instruction[current_function, position] = text
        mnemonic[current_function, position] = name
      }
    }

    END {
      highway_target = keyed_target(highway_target)
      call_pattern = "^(bl|blr|blraa|blraaz|blrab|blrabz|call|callq|calll)$"
      branch_pattern = "^(b|b\\.[a-z]+|bc\\.[a-z]+|br|braa|braaz|brab|brabz|cbz|cbnz|tbz|tbnz|j[a-z]+)$"

      for (entry = 1; entry <= allowlist_total; entry++) {
        if (allowlist_target[entry] == highway_target) {
          allowlisted[allowlist_function[entry]] = 1
        }
      }

      for (rank = 1; rank <= port_total; rank++) {
        port_name = port_order[rank]
        key = substr(port_name, 5)
        highway_name = "highway" key
        if (!(highway_name in instruction_count)) {
          printf "** ERROR: %s has no highway counterpart\n", port_name > "/dev/stderr"
          failed = 1
          continue
        }
        paired[highway_name] = 1

        port_length = trimmed_length(port_name)
        highway_length = trimmed_length(highway_name)
        if (port_length == highway_length &&
            same_instructions(port_name, highway_name, port_length)) {
          verdict = "same"
        } else if (port_length < highway_length) {
          verdict = "shorter"
        } else if (port_length > highway_length) {
          verdict = "longer"
        } else {
          verdict = "different"
        }
        verdict_of[key] = verdict

        port_calls = count_matching(port_name, port_length, call_pattern)
        highway_calls = count_matching(highway_name, highway_length, call_pattern)
        port_branches = count_matching(port_name, port_length, branch_pattern)
        highway_branches = count_matching(highway_name, highway_length, branch_pattern)
        flags = ""
        if (port_calls > highway_calls) {
          flags = flags " [call]"
        }
        if (port_branches > highway_branches) {
          flags = flags " [branch]"
        }
        allowlist_mark = ""
        if (verdict != "same") {
          if (key in allowlisted) {
            allowlist_mark = " [allowlisted]"
            allowlisted_count++
          } else {
            unlisted_count++
          }
        }

        verdict_count[verdict]++
        if (flags != "") {
          flagged++
        }
        printf "%-40s port=%-4d highway=%-4d %s%s%s\n",
          key, port_length, highway_length, verdict, flags, allowlist_mark

        if (show_listings == "true" && verdict != "same") {
          print_listing("port", port_name, port_length)
          print_listing("highway", highway_name, highway_length)
        }
      }

      for (function_name in instruction_count) {
        if (function_name ~ /^highway/ && !(function_name in paired)) {
          printf "** ERROR: %s has no port counterpart\n", function_name > "/dev/stderr"
          failed = 1
        }
      }
      if (port_total == 0) {
        printf "** ERROR: found no port functions to compare\n" > "/dev/stderr"
        failed = 1
      }

      for (entry = 1; entry <= allowlist_total; entry++) {
        if (allowlist_target[entry] != highway_target) {
          continue
        }
        listed_function = allowlist_function[entry]
        if (!(listed_function in verdict_of)) {
          printf "** ERROR: %s:%d: %s %s is allowlisted but has no port and highway pair\n",
            allowlist_name, allowlist_line[entry], highway_target, listed_function > "/dev/stderr"
          failed = 1
        } else if (verdict_of[listed_function] == "same") {
          printf "** ERROR: %s:%d: %s %s is allowlisted but its pair is the same\n",
            allowlist_name, allowlist_line[entry], highway_target, listed_function > "/dev/stderr"
          failed = 1
        }
      }
      if (unlisted_count > 0) {
        printf "** ERROR: %d functions differ and are not in %s\n",
          unlisted_count, allowlist_name > "/dev/stderr"
        failed = 1
      }

      printf "\nSummary of %d functions on %s\n", port_total, highway_target
      print_count("same", verdict_count["same"])
      print_count("shorter", verdict_count["shorter"])
      print_count("longer", verdict_count["longer"])
      print_count("different", verdict_count["different"])
      print_count("flagged", flagged)
      print_count("allowlisted", allowlisted_count)
      exit failed
    }
  ' "${allowlist_file}" "${names_file}" "${listing_file}"; then
    fatal "The comparison of the functions of '${target_name}' failed"
  fi
  return 0
}

main() {
  require_command swift

  parse_arguments "$@"

  if [[ ! -x "${normalize_script}" ]]; then
    fatal "There is no executable '${normalize_script#"${repository_root}/"}'" \
      "to normalize the disassembly of the object files with"
  fi
  if ! "${normalize_script}" --check; then
    fatal "Cannot normalize the disassembly of '${target_name}' without an objdump"
  fi

  validate_allowlist "${allowlist_path}"

  local host_architecture_key
  host_architecture_key="$(architecture_key "${architecture}")"

  local -a build_arguments=(
    -c release
    --build-system native
    --package-path "${package_root}"
    --target "${target_name}"
    -Xswiftc -Xfrontend -Xswiftc -disable-llvm-merge-functions-pass
  )
  if [[ -n "${architecture}" ]]; then
    build_arguments+=( --arch "${architecture}" )
  fi
  build_arguments+=( "${extra_build_arguments[@]}" )

  local binary_directory
  binary_directory="$(binary_path build_arguments)"
  remove_object_files "${binary_directory}"
  build_target build_arguments

  local -a object_files=()
  local object_file
  while IFS= read -r -d '' object_file; do
    object_files+=( "${object_file}" )
  done < <(find_object_files "${binary_directory}")

  if [[ "${#object_files[@]}" -eq 0 ]]; then
    fatal "Found no object files of '${target_name}' under '${binary_directory}'"
  fi

  workspace="$(mktemp -d)" || fatal "Failed to create a temporary directory for the disassembly"
  trap cleanup EXIT
  local -r listing_file="${workspace}/listing.txt"
  local -r symbols_file="${workspace}/symbols.txt"
  local -r demangled_file="${workspace}/demangled.txt"
  local -r names_file="${workspace}/names.tsv"

  log "Disassembling ${#object_files[@]} object files..."
  normalize_object_files object_files > "${listing_file}"
  demangle_symbols "${listing_file}" "${symbols_file}" "${demangled_file}" > "${names_file}"

  log "Comparing the functions..."
  compare_functions "${names_file}" "${listing_file}" "${allowlist_path}" "${verbose}" \
    "${host_architecture_key}"
  return 0
}

main "$@"
