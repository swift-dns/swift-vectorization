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
readonly reorder_allowlist_path="${repository_root}/scripts/codegen-reorder-allowlist.txt"
readonly longer_allowlist_path="${repository_root}/scripts/codegen-longer-allowlist.txt"
readonly normalize_script="${repository_root}/scripts/normalize-disassembly.sh"
readonly allowlist_entry_pattern='^([A-Z][A-Z0-9_]*)[[:space:]]+([A-Za-z0-9_]+)[[:space:]]+[^[:space:]]'
readonly allowlist_entry_format='<TARGET> <Function> <reason>'
readonly allowlist_entry_example='NEON FirstLanesU8 the reason it differs'
readonly reorder_allowlist_entry_pattern='^([A-Z][A-Z0-9_]*)[[:space:]]+([A-Za-z0-9_]+)$'
readonly reorder_allowlist_entry_format='<TARGET> <Function>'
readonly reorder_allowlist_entry_example='NEON FirstLanesU8'
readonly longer_allowlist_entry_pattern='^([A-Z][A-Z0-9_]*)[[:space:]]+([A-Za-z0-9_]+)$'
readonly longer_allowlist_entry_format='<TARGET> <Function>'
readonly longer_allowlist_entry_example='EMU128_X86_64 RemainderI64'
readonly target_name="HighwayReferenceCodegen"
readonly host_dependent_target="EMU128"
readonly listing_limit_on_failure=50

architecture=""
verbose="false"
fingerprints_path=""
declare -a extra_build_arguments=()
declare -A location_of_entry=()
workspace=""

cleanup() {
  if [[ -n "${workspace}" && -d "${workspace}" ]]; then
    rm -rf -- "${workspace}"
  fi
  return 0
}

usage() {
  printf -- 'Usage: %s [--arch <arch>] [--verbose | --fingerprints <file>]\n' \
    "$(basename -- "${BASH_SOURCE[0]}")"
  printf -- '       [-- <extra swift build arguments>]\n'
  printf -- '  --fingerprints <file> write the fingerprint of every port and highway function to the\n'
  printf -- '                        file instead of comparing them, for list-new-ops.sh to read\n'
  printf -- "A function that is not the same as highway's fails unless %s\n" \
    "${allowlist_path#"${repository_root}/"}"
  printf -- 'gives the reason, or, if only the order of its instructions differs, unless\n'
  printf -- "%s lists it. A function longer than highway's also fails\n" \
    "${reorder_allowlist_path#"${repository_root}/"}"
  printf -- 'unless %s lists it, and a listed function fails if it\n' \
    "${longer_allowlist_path#"${repository_root}/"}"
  printf -- 'no longer differs that way.\n'
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
      --fingerprints)
        fingerprints_path="${1:?--fingerprints requires the file to write the fingerprints to}"
        shift
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

  if [[ "${verbose}" == "true" && -n "${fingerprints_path}" ]]; then
    fatal "--verbose prints the listings of the comparison, which --fingerprints skips" "$(usage)"
  fi
  return 0
}

validate_allowlist() {
  local allowlist_file="${1:?validate_allowlist requires the allowlist file}"
  local entry_pattern="${2:?validate_allowlist requires the pattern an entry must match}"
  local entry_format="${3:?validate_allowlist requires the format of an entry}"
  local entry_example="${4:?validate_allowlist requires an example of an entry}"
  local entry_group="${5:?validate_allowlist requires the group its entries are unique in}"

  if [[ ! -f "${allowlist_file}" ]]; then
    fatal "There is no '${allowlist_file}' to read the allowlisted functions from" \
      "Every line of it is '${entry_format}'" \
      "It is empty when nothing is allowlisted"
  fi

  local line entry_key
  local line_number=0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line_number=$(( line_number + 1 ))

    if [[ ! "${line}" =~ ${entry_pattern} ]]; then
      fatal "Line ${line_number} of '${allowlist_file}' is malformed: '${line}'" \
        "It must be '${entry_format}'" \
        "For example: '${entry_example}'" \
        "Blank lines and comments are not allowed"
    fi

    if [[ "${BASH_REMATCH[1]}" == "${host_dependent_target}" ]]; then
      fatal "Line ${line_number} of '${allowlist_file}' allowlists '${BASH_REMATCH[2]}'" \
        "on ${host_dependent_target}, whose instructions depend on the host architecture" \
        "It must name the host: '${host_dependent_target}_ARM64' or '${host_dependent_target}_X86_64'"
    fi

    entry_key="${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
    if [[ -n "${location_of_entry["${entry_group} ${entry_key}"]:-}" ]]; then
      fatal "Line ${line_number} of '${allowlist_file}' repeats '${entry_key}'," \
        "which ${location_of_entry["${entry_group} ${entry_key}"]} already allowlists"
    fi
    location_of_entry["${entry_group} ${entry_key}"]="line ${line_number} of '${allowlist_file}'"
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
  shift

  if ! "${normalize_script}" "$@" -- "${object_files_ref[@]}"; then
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
  local reorder_allowlist_file="${4:?compare_functions requires the reorder allowlist file}"
  local longer_allowlist_file="${5:?compare_functions requires the longer allowlist file}"
  local show_listings="${6:?compare_functions requires whether to print the listings}"
  local host_architecture_key="${7:?compare_functions requires the key of the host architecture}"

  if ! awk -F '\t' \
    -v names_file="${names_file}" \
    -v allowlist_file="${allowlist_file}" \
    -v allowlist_name="${allowlist_file#"${repository_root}/"}" \
    -v reorder_allowlist_file="${reorder_allowlist_file}" \
    -v reorder_allowlist_name="${reorder_allowlist_file#"${repository_root}/"}" \
    -v longer_allowlist_file="${longer_allowlist_file}" \
    -v longer_allowlist_name="${longer_allowlist_file#"${repository_root}/"}" \
    -v show_listings="${show_listings}" \
    -v host_dependent_target="${host_dependent_target}" \
    -v host_architecture_key="${host_architecture_key}" \
    -v listing_limit="${listing_limit_on_failure}" '
    function keyed_target(target) {
      if (target == host_dependent_target) {
        return target "_" host_architecture_key
      }
      return target
    }

    function allowlist_name_of(entry) {
      if (allowlist_for_reorders[entry]) {
        return reorder_allowlist_name
      }
      if (allowlist_for_longer[entry]) {
        return longer_allowlist_name
      }
      return allowlist_name
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

    function same_instructions_in_any_order(first, second, total,    position, surplus) {
      for (position = 1; position <= total; position++) {
        surplus[instruction[first, position]]++
        surplus[instruction[second, position]]--
      }
      for (position = 1; position <= total; position++) {
        if (surplus[instruction[first, position]] != 0 ||
            surplus[instruction[second, position]] != 0) {
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

    FILENAME == allowlist_file || FILENAME == reorder_allowlist_file ||
    FILENAME == longer_allowlist_file {
      split($0, entry_fields, " ")
      allowlist_total++
      allowlist_target[allowlist_total] = entry_fields[1]
      allowlist_function[allowlist_total] = entry_fields[2]
      allowlist_line[allowlist_total] = FNR
      allowlist_for_reorders[allowlist_total] = (FILENAME == reorder_allowlist_file)
      allowlist_for_longer[allowlist_total] = (FILENAME == longer_allowlist_file)
      next
    }

    FILENAME == names_file {
      base_name = $2
      sub(/\(.*$/, "", base_name)
      if (base_name ~ /^(port|highway)[A-Z]/) {
        function_of_symbol[$1] = base_name
      }
      if (highway_target == "" && base_name == "targetOfHighway" &&
          match($1, /N_[A-Z0-9_]+O[0-9]/)) {
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
        if (allowlist_target[entry] != highway_target) {
          continue
        }
        if (allowlist_for_reorders[entry]) {
          reorder_allowlisted[allowlist_function[entry]] = 1
        } else if (allowlist_for_longer[entry]) {
          longer_allowlisted[allowlist_function[entry]] = 1
        } else {
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
        } else if (same_instructions_in_any_order(port_name, highway_name, port_length)) {
          verdict = "reordered"
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
          if (key in reorder_allowlisted) {
            allowlist_mark = " [reorder-allowlisted]"
          } else if (key in allowlisted) {
            allowlist_mark = " [allowlisted]"
            allowlisted_count++
          } else {
            unlisted_count++
            failing_function[++failing_total] = key
            if (verdict == "reordered") {
              unlisted_reordered_count++
            }
          }
          if (key in longer_allowlisted) {
            allowlist_mark = allowlist_mark " [longer-allowlisted]"
          } else if (verdict == "longer") {
            unlisted_longer_count++
            if (key in allowlisted || key in reorder_allowlisted) {
              failing_function[++failing_total] = key
            }
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
      if (highway_target == "") {
        printf "** ERROR: found no targetOfHighway to read the target from\n" > "/dev/stderr"
        failed = 1
      }

      for (entry = 1; entry <= allowlist_total; entry++) {
        if (allowlist_target[entry] != highway_target) {
          continue
        }
        listed_function = allowlist_function[entry]
        listed_as = "allowlisted"
        if (allowlist_for_reorders[entry]) {
          listed_as = "reorder-allowlisted"
        } else if (allowlist_for_longer[entry]) {
          listed_as = "longer-allowlisted"
        }
        if (!(listed_function in verdict_of)) {
          printf "** ERROR: %s:%d: %s %s is %s but has no port and highway pair\n",
            allowlist_name_of(entry), allowlist_line[entry], highway_target, listed_function,
            listed_as > "/dev/stderr"
          failed = 1
        } else if (verdict_of[listed_function] == "same") {
          printf "** ERROR: %s:%d: %s %s is %s but its pair is the same\n",
            allowlist_name_of(entry), allowlist_line[entry], highway_target, listed_function,
            listed_as > "/dev/stderr"
          failed = 1
        } else if (allowlist_for_reorders[entry] && verdict_of[listed_function] != "reordered") {
          printf "** ERROR: %s:%d: %s %s is %s but its pair is %s, not reordered\n",
            allowlist_name_of(entry), allowlist_line[entry], highway_target, listed_function,
            listed_as, verdict_of[listed_function] > "/dev/stderr"
          failed = 1
          failing_function[++failing_total] = listed_function
        } else if (allowlist_for_longer[entry] && verdict_of[listed_function] != "longer") {
          printf "** ERROR: %s:%d: %s %s is %s but its pair is %s, not longer\n",
            allowlist_name_of(entry), allowlist_line[entry], highway_target, listed_function,
            listed_as, verdict_of[listed_function] > "/dev/stderr"
          failed = 1
          failing_function[++failing_total] = listed_function
        }
      }
      if (unlisted_count > 0) {
        printf "** ERROR: %d functions differ and are not in %s\n",
          unlisted_count, allowlist_name > "/dev/stderr"
        if (unlisted_reordered_count > 0) {
          printf "Of those, %d only reordered the instructions and can go in %s\n",
            unlisted_reordered_count, reorder_allowlist_name > "/dev/stderr"
        }
        failed = 1
      }
      if (unlisted_longer_count > 0) {
        printf "** ERROR: %d functions are longer than highway\047s and are not in %s\n",
          unlisted_longer_count, longer_allowlist_name > "/dev/stderr"
        failed = 1
      }

      if (show_listings != "true" && failing_total > 0) {
        printf "\nListings of the %d functions that differ from what the allowlists say\n",
          failing_total
        for (rank = 1; rank <= failing_total && rank <= listing_limit; rank++) {
          key = failing_function[rank]
          printf "%s (%s)\n", key, verdict_of[key]
          print_listing("port", "port" key, trimmed_length("port" key))
          print_listing("highway", "highway" key, trimmed_length("highway" key))
        }
        if (failing_total > listing_limit) {
          printf "The other %d listings are left out; --verbose prints them all\n",
            failing_total - listing_limit
        }
      }

      printf "\nSummary of %d functions on %s\n", port_total, highway_target
      print_count("same", verdict_count["same"])
      print_count("shorter", verdict_count["shorter"])
      print_count("longer", verdict_count["longer"])
      print_count("reordered", verdict_count["reordered"])
      print_count("different", verdict_count["different"])
      print_count("flagged", flagged)
      print_count("allowlisted", allowlisted_count)
      exit failed
    }
  ' "${allowlist_file}" "${reorder_allowlist_file}" "${longer_allowlist_file}" "${names_file}" \
    "${listing_file}"; then
    fatal "The comparison of the functions of '${target_name}' failed"
  fi
  return 0
}

validate_fingerprints_path() {
  local fingerprints_file="${1:?validate_fingerprints_path requires the file of the fingerprints}"

  local fingerprints_directory
  fingerprints_directory="$(dirname -- "${fingerprints_file}")"
  if [[ ! -d "${fingerprints_directory}" ]]; then
    fatal "There is no directory '${fingerprints_directory}' to write the fingerprints to"
  fi
  if [[ -d "${fingerprints_file}" ]]; then
    fatal "'${fingerprints_file}' is a directory, not a file to write the fingerprints to"
  fi
  return 0
}

find_hash_command() {
  local -n found_command_ref="${1:?find_hash_command requires the name of the hash command array}"

  if command -v sha256sum > /dev/null 2>&1; then
    found_command_ref+=( sha256sum )
  elif command -v shasum > /dev/null 2>&1; then
    found_command_ref+=( shasum -a 256 )
  else
    fatal "Writing fingerprints requires 'sha256sum' or 'shasum', and neither is installed"
  fi
  return 0
}

serialize_closures() {
  local names_file="${1:?serialize_closures requires the file of symbols and demangled names}"
  local listing_file="${2:?serialize_closures requires the disassembly listing}"
  local closure_directory="${3:?serialize_closures requires the directory to write the closures to}"
  local host_architecture_key="${4:?serialize_closures requires the key of the host architecture}"

  if ! awk -F '\t' \
    -v names_file="${names_file}" \
    -v closure_directory="${closure_directory}" \
    -v host_dependent_target="${host_dependent_target}" \
    -v host_architecture_key="${host_architecture_key}" '
    BEGIN {
      detail_limit = 100
    }

    function quoted(value) {
      return "\047" value "\047"
    }

    function fatal(message) {
      printf "** ERROR: %s\n", message > "/dev/stderr"
      failed = 1
      exit 1
    }

    function keyed_target(target) {
      if (target == host_dependent_target) {
        return target "_" host_architecture_key
      }
      return target
    }

    function mnemonic_of(text,    mnemonic) {
      mnemonic = text
      sub(/[[:space:]].*$/, "", mnemonic)
      return mnemonic
    }

    function is_terminator(mnemonic) {
      return mnemonic ~ /^(ret|retq|retl|retaa|retab|b|br|braa|braaz|brab|brabz|brk|udf)$/ ||
             mnemonic ~ /^(jmp|jmpq|jmpl|ud2|int3)$/
    }

    function register_label(object, label, block,    name) {
      if (((object, label) in raw_block) && raw_block[object, label] != block) {
        raw_ambiguous[object, label] = 1
      }
      raw_block[object, label] = block
      name = label
      if (object_is_macho[object]) {
        sub(/^_/, "", name)
      }
      if ((name in named_block) && named_block[name] != block) {
        named_ambiguous[name] = 1
      }
      named_block[name] = block
    }

    function fail_block(block, reason, detail) {
      if (length(detail) > detail_limit) {
        detail = substr(detail, 1, detail_limit) "..."
      }
      block_problem[block] = reason
      block_problem_detail[block] = detail
      return ""
    }

    function edge_marker(block, target) {
      edge_total[block]++
      edge_target[block, edge_total[block]] = target
      return "\001" edge_total[block] "\001"
    }

    function branch_template(block, target_text,    object, name, offset) {
      if (target_text ~ /^\+0x[0-9a-fA-F]+$/) {
        return "<" target_text ">"
      }
      object = block_object[block]
      name = target_text
      offset = ""
      if (match(target_text, /\+0x[0-9a-fA-F]+$/)) {
        name = substr(target_text, 1, RSTART - 1)
        offset = substr(target_text, RSTART)
      }
      if (!((object, name) in raw_block) || ((object, name) in raw_ambiguous)) {
        return fail_block(block, "refer to code their object does not name once", target_text)
      }
      return "<" edge_marker(block, raw_block[object, name]) offset ">"
    }

    function annotation_template(block, annotation,    kind, content, name) {
      kind = substr(annotation, 2, index(annotation, ":") - 2)
      content = substr(annotation, index(annotation, ":") + 1)
      sub(/}$/, "", content)
      if (kind == "const") {
        return annotation
      }
      if (kind == "data") {
        return fail_block(block, "refer to data the listing does not resolve", annotation)
      }
      if (kind != "sym" && kind != "got") {
        return fail_block(block, "carry an annotation of an unknown kind", annotation)
      }
      name = content
      sub(/[+-]0x[0-9a-fA-F]+$/, "", name)
      if (name in named_ambiguous) {
        return fail_block(block, "refer to a symbol that several functions define", annotation)
      }
      if (name in named_block) {
        return "{" kind ":" content edge_marker(block, named_block[name]) "}"
      }
      if (kind == "got") {
        return fail_block(block, "load an address the listing does not resolve", annotation)
      }
      return annotation
    }

    function instruction_template(block, text,    template, literal_text, remaining, token) {
      if (text == "<unknown>") {
        return fail_block(block, "hold bytes objdump cannot decode", text)
      }
      if (text ~ /\(%rip\)/ && text !~ /\{[a-z]+:/) {
        return fail_block(block, "address memory relative to the instruction without a relocation",
                          text)
      }
      template = ""
      literal_text = ""
      remaining = text
      while (match(remaining, /<[^>]*>|\{[a-z]+:[^}]*\}/)) {
        literal_text = literal_text " " substr(remaining, 1, RSTART - 1)
        template = template substr(remaining, 1, RSTART - 1)
        token = substr(remaining, RSTART, RLENGTH)
        remaining = substr(remaining, RSTART + RLENGTH)
        if (token ~ /^</) {
          template = template branch_template(block, substr(token, 2, length(token) - 2))
        } else {
          template = template annotation_template(block, token)
        }
        if (block_problem[block] != "") {
          return ""
        }
      }
      literal_text = literal_text " " remaining
      if (literal_text ~ /[ ,]-?0x[0-9a-fA-F]+([ ,]|$)/) {
        return fail_block(block, "name an address without a symbol", text)
      }
      return template remaining
    }

    function analyze(block,    total, position) {
      if (block in analyzed) {
        return
      }
      analyzed[block] = 1
      block_problem[block] = ""
      edge_total[block] = 0
      total = instruction_count[block]
      while (total > 0 && mnemonic_of(instruction[block, total]) ~ /^nop/) {
        total--
      }
      trimmed_total[block] = total
      if (total == 0) {
        fail_block(block, "hold nothing but padding", "")
        return
      }
      if (!is_terminator(mnemonic_of(instruction[block, total]))) {
        fail_block(block, "may run past their last instruction", instruction[block, total])
        return
      }
      for (position = 1; position <= total; position++) {
        template[block, position] = instruction_template(block, instruction[block, position])
        if (block_problem[block] != "") {
          return
        }
      }
    }

    function serialize_closure(root, path,    queue, index_of, tail, head, block, edge, target,
                               position, pieces, piece_total, piece, line) {
      tail = 1
      queue[1] = root
      index_of[root] = 1
      for (head = 1; head <= tail; head++) {
        block = queue[head]
        analyze(block)
        if (block_problem[block] != "") {
          return block
        }
        for (edge = 1; edge <= edge_total[block]; edge++) {
          target = edge_target[block, edge]
          if (!(target in index_of)) {
            tail++
            queue[tail] = target
            index_of[target] = tail
          }
        }
      }
      for (head = 1; head <= tail; head++) {
        block = queue[head]
        print "block " head > path
        for (position = 1; position <= trimmed_total[block]; position++) {
          piece_total = split(template[block, position], pieces, "\001")
          line = ""
          for (piece = 1; piece <= piece_total; piece++) {
            if (piece % 2 == 1) {
              line = line pieces[piece]
            } else {
              line = line "@" index_of[edge_target[block, pieces[piece]]]
            }
          }
          print line > path
        }
      }
      close(path)
      return 0
    }

    function closure_state(function_name,    failing_block, reason) {
      function_total++
      failing_block = serialize_closure(block_of_function[function_name],
                                        closure_directory "/" function_name)
      if (failing_block == 0) {
        return "hashed"
      }
      reason = block_problem[failing_block]
      if (!(reason in reason_total)) {
        reason_kinds++
        reason_order[reason_kinds] = reason
        reason_example[reason] = function_name " (" block_problem_detail[failing_block] ")"
      }
      reason_total[reason]++
      unresolved_total++
      return "unresolved"
    }

    FILENAME == names_file {
      base_name = $2
      sub(/\(.*$/, "", base_name)
      if (base_name ~ /^(port|highway)[A-Z]/) {
        if (base_name !~ /^(port|highway)[A-Z][A-Za-z0-9_]*$/) {
          fatal("Cannot name a file after the function " quoted(base_name))
        }
        function_of_symbol[$1] = base_name
      }
      if (highway_target == "" && base_name == "targetOfHighway" &&
          match($1, /N_[A-Z0-9_]+O[0-9]/)) {
        highway_target = substr($1, RSTART + 2, RLENGTH - 2)
        sub(/O[0-9]+$/, "", highway_target)
      }
      next
    }

    /:\tfile format / {
      object_total++
      object_is_macho[object_total] = ($0 ~ /:\tfile format mach-o /)
      current_block = 0
      next
    }

    /^<.*>:$/ {
      if (object_total == 0) {
        fatal("Found the label " quoted($0) " before the file format of any object")
      }
      if (current_block == 0 || instruction_count[current_block] > 0) {
        block_total++
        current_block = block_total
        block_object[current_block] = object_total
        instruction_count[current_block] = 0
      }
      label = substr($0, 2, length($0) - 3)
      register_label(object_total, label, current_block)
      if (label in function_of_symbol) {
        function_name = function_of_symbol[label]
        if (function_name in block_of_function) {
          fatal(function_name " is defined more than once")
        }
        block_of_function[function_name] = current_block
        if (function_name ~ /^port/) {
          port_total++
          port_order[port_total] = function_name
        }
      }
      next
    }

    /^\t/ {
      if (current_block == 0) {
        fatal("Found the instruction " quoted($0) " before any label of its object")
      }
      instruction_count[current_block]++
      instruction[current_block, instruction_count[current_block]] = substr($0, 2)
      next
    }

    {
      fatal("Cannot read the line " quoted($0) " of the disassembly listing")
    }

    END {
      if (failed) {
        exit 1
      }
      if (port_total == 0) {
        fatal("Found no port functions to fingerprint")
      }
      if (highway_target == "") {
        fatal("Found no targetOfHighway to read the target from")
      }
      for (function_name in block_of_function) {
        if (function_name ~ /^highway/ && !(("port" substr(function_name, 8)) in block_of_function)) {
          fatal(function_name " has no port counterpart")
        }
      }

      printf "target\t%s\n", keyed_target(highway_target)
      for (rank = 1; rank <= port_total; rank++) {
        port_name = port_order[rank]
        key = substr(port_name, 5)
        if (!(("highway" key) in block_of_function)) {
          fatal(port_name " has no highway counterpart")
        }
        port_state = closure_state(port_name)
        highway_state = closure_state("highway" key)
        printf "%s\t%s\t%s\n", key, port_state, highway_state
      }

      if (unresolved_total > 0) {
        printf "** %d of %d functions cannot be fingerprinted, so their keys count as new:\n",
          unresolved_total, function_total > "/dev/stderr"
        for (kind = 1; kind <= reason_kinds; kind++) {
          reason = reason_order[kind]
          printf "**   %d %s, like %s\n", reason_total[reason], reason,
            reason_example[reason] > "/dev/stderr"
        }
      }
    }
  ' "${names_file}" "${listing_file}"; then
    fatal "Failed to serialize what the functions of '${target_name}' run"
  fi
  return 0
}

hash_closures() {
  local closure_directory="${1:?hash_closures requires the directory of the closures}"
  local -n hash_command_ref="${2:?hash_closures requires the name of the hash command array}"

  if ! (cd -- "${closure_directory}" && find . -type f -exec "${hash_command_ref[@]}" {} +); then
    fatal "Failed to hash the closures in '${closure_directory}'"
  fi
  return 0
}

merge_fingerprints() {
  local manifest_file="${1:?merge_fingerprints requires the manifest of the closures}"
  local hashes_file="${2:?merge_fingerprints requires the hashes of the closures}"
  local merged_file="${3:?merge_fingerprints requires the file to merge them into}"

  if ! awk -F '\t' -v hashes_file="${hashes_file}" '
    function quoted(value) {
      return "\047" value "\047"
    }

    function fatal(message) {
      printf "** ERROR: %s\n", message > "/dev/stderr"
      failed = 1
      exit 1
    }

    function fingerprint(function_name, state) {
      if (state == "unresolved") {
        return state
      }
      if (state != "hashed") {
        fatal("The closure of " function_name " is " quoted(state) ", neither hashed nor unresolved")
      }
      if (!(function_name in hash_of)) {
        fatal("Found no hash of the closure of " function_name)
      }
      hashed_total++
      return hash_of[function_name]
    }

    FILENAME == hashes_file {
      if (!match($0, /^[0-9a-f]+ [ *]\.\//)) {
        fatal("Cannot read the hash " quoted($0))
      }
      digest = substr($0, 1, index($0, " ") - 1)
      closure_name = substr($0, RLENGTH + 1)
      if (length(digest) != 64) {
        fatal("The hash " quoted($0) " is not a SHA-256 digest")
      }
      if (closure_name in hash_of) {
        fatal("Found two hashes of the closure of " closure_name)
      }
      hash_of[closure_name] = digest
      hash_total++
      next
    }

    FNR == 1 {
      if (NF != 2 || $1 != "target") {
        fatal("The manifest starts with " quoted($0) " instead of the target")
      }
      target = $2
      print
      next
    }

    {
      if (NF != 3) {
        fatal("Cannot read the line " quoted($0) " of the manifest")
      }
      printf "%s\t%s\t%s\n", $1, fingerprint("port" $1, $2), fingerprint("highway" $1, $3)
      key_total++
    }

    END {
      if (failed) {
        exit 1
      }
      if (hashed_total != hash_total) {
        fatal(hash_total " closures were hashed, but the manifest names " hashed_total)
      }
      printf "** Fingerprinted %d keys on %s\n", key_total, target > "/dev/stderr"
    }
  ' "${hashes_file}" "${manifest_file}" > "${merged_file}"; then
    fatal "Failed to merge the hashes into the fingerprints"
  fi

  if ! head -n 1 -- "${merged_file}"; then
    fatal "Failed to read the target out of '${merged_file}'"
  fi
  if ! tail -n +2 -- "${merged_file}" | LC_ALL=C sort; then
    fatal "Failed to sort the fingerprints of '${merged_file}'"
  fi
  return 0
}

write_fingerprints() {
  local names_file="${1:?write_fingerprints requires the file of symbols and demangled names}"
  local listing_file="${2:?write_fingerprints requires the disassembly listing}"
  local host_architecture_key="${3:?write_fingerprints requires the key of the host architecture}"
  local hash_command_name="${4:?write_fingerprints requires the name of the hash command array}"
  local work_directory="${5:?write_fingerprints requires a directory to work in}"
  local fingerprints_file="${6:?write_fingerprints requires the file to write the fingerprints to}"

  local -r closure_directory="${work_directory}/closures"
  local -r manifest_file="${work_directory}/manifest.tsv"
  local -r hashes_file="${work_directory}/hashes.txt"
  local -r merged_file="${work_directory}/merged.tsv"
  local -r written_file="${work_directory}/fingerprints.tsv"

  if ! mkdir -- "${closure_directory}"; then
    fatal "Failed to create the directory '${closure_directory}'"
  fi
  serialize_closures "${names_file}" "${listing_file}" "${closure_directory}" \
    "${host_architecture_key}" > "${manifest_file}"
  hash_closures "${closure_directory}" "${hash_command_name}" > "${hashes_file}"
  merge_fingerprints "${manifest_file}" "${hashes_file}" "${merged_file}" > "${written_file}"

  if ! mv -f -- "${written_file}" "${fingerprints_file}"; then
    fatal "Failed to move the fingerprints to '${fingerprints_file}'"
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

  local -a normalize_options=()
  local -a hash_command=()
  if [[ -n "${fingerprints_path}" ]]; then
    validate_fingerprints_path "${fingerprints_path}"
    find_hash_command hash_command
    normalize_options=( --file-formats --complete-constants --generic-syntax )
  else
    validate_allowlist "${allowlist_path}" "${allowlist_entry_pattern}" \
      "${allowlist_entry_format}" "${allowlist_entry_example}" differing
    validate_allowlist "${reorder_allowlist_path}" "${reorder_allowlist_entry_pattern}" \
      "${reorder_allowlist_entry_format}" "${reorder_allowlist_entry_example}" differing
    validate_allowlist "${longer_allowlist_path}" "${longer_allowlist_entry_pattern}" \
      "${longer_allowlist_entry_format}" "${longer_allowlist_entry_example}" longer
  fi

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
  normalize_object_files object_files "${normalize_options[@]}" > "${listing_file}"
  demangle_symbols "${listing_file}" "${symbols_file}" "${demangled_file}" > "${names_file}"

  if [[ -n "${fingerprints_path}" ]]; then
    log "Fingerprinting the functions with ${hash_command[0]}..."
    write_fingerprints "${names_file}" "${listing_file}" "${host_architecture_key}" hash_command \
      "${workspace}" "${fingerprints_path}"
    log "Wrote the fingerprints to '${fingerprints_path}'"
    return 0
  fi

  log "Comparing the functions..."
  compare_functions "${names_file}" "${listing_file}" "${allowlist_path}" \
    "${reorder_allowlist_path}" "${longer_allowlist_path}" "${verbose}" "${host_architecture_key}"
  return 0
}

main "$@"
