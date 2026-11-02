#!/usr/bin/env bash

set -Eeuo pipefail
shopt -s failglob
IFS=$'\n\t'

log() { printf -- "** %s\n" "$*" >&2; }
error() { printf -- "** ERROR: %s\n" "$*" >&2; }
fatal() { error "$@"; exit 1; }

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly repository_root
readonly version_file="${repository_root}/highway-version.json"
readonly vendor_root="${repository_root}/HighwayReference/CHighway"
readonly include_root="${vendor_root}/include"
readonly port_vendor_root="${repository_root}/Sources/CVectorizationOps/vendor"
readonly module_map="${include_root}/module.modulemap"
readonly patch_root="${repository_root}/patches"

# A module compiles every header it lists, so the module map lists only the ones the package's own
# headers reach.
readonly -a module_seed_headers=(
  hwy/highway.h
)

# The headers the product itself includes to pick its target the way highway does, by their
# path upstream and their path under the vendor root of the product.
readonly -A port_headers=(
  ["hwy/detect_targets.h"]="detect_targets.h"
  ["hwy/detect_compiler_arch.h"]="hwy/detect_compiler_arch.h"
)

clone_dir=""
history_dir=""

cleanup() {
  if [[ -n "${clone_dir}" && -d "${clone_dir}" ]]; then
    rm -rf -- "${clone_dir}"
  fi
  if [[ -n "${history_dir}" && -d "${history_dir}" ]]; then
    rm -rf -- "${history_dir}"
  fi
  return 0
}

require_command() {
  local command_name="${1:?require_command requires the name of the command}"

  if ! command -v "${command_name}" > /dev/null 2>&1; then
    fatal "'${command_name}' is required by $(basename -- "${BASH_SOURCE[0]}") but is not installed"
  fi
  return 0
}

version_field() {
  local field_name="${1:?version_field requires the name of the field to read}"

  local value
  if ! value="$(jq -er --arg field "${field_name}" '.[$field]' "${version_file}")"; then
    fatal "'${version_file}' has no '${field_name}' field"
  fi

  printf -- '%s\n' "${value}"
  return 0
}

clone_history() {
  local repository="${1:?clone_history requires the upstream repository url}"
  local destination="${2:?clone_history requires the destination directory}"

  log "Cloning the history of ${repository}..."
  local -a clone_arguments=(
    clone --quiet --bare --filter=tree:0
  )
  if ! git "${clone_arguments[@]}" "${repository}" "${destination}"; then
    fatal "Failed to clone the history of '${repository}'"
  fi
  return 0
}

verify_tag_commit() {
  local history_dir="${1:?verify_tag_commit requires the history clone directory}"
  local tag="${2:?verify_tag_commit requires the tag to check}"
  local expected_commit="${3:?verify_tag_commit requires the expected commit sha}"

  local tag_commit_reference="refs/tags/${tag}^{commit}"
  local actual_commit
  if ! actual_commit="$(git -C "${history_dir}" rev-parse --verify "${tag_commit_reference}")"; then
    fatal "Failed to resolve the tag '${tag}' of '${version_file}' to a commit"
  fi

  if [[ "${actual_commit}" != "${expected_commit}" ]]; then
    fatal "The tag '${tag}' in '${version_file}' does not point at the commit it records." \
      "Expected: ${expected_commit}" \
      "Actual:   ${actual_commit}"
  fi

  log "Verified that tag ${tag} points at ${expected_commit}."
  return 0
}

verify_branch_contains_commit() {
  local history_dir="${1:?verify_branch_contains_commit requires the history clone directory}"
  local branch="${2:?verify_branch_contains_commit requires the branch to check}"
  local expected_commit="${3:?verify_branch_contains_commit requires the expected commit sha}"

  local -a ancestor_arguments=(
    merge-base --is-ancestor "${expected_commit}" "refs/heads/${branch}"
  )
  local exit_status=0
  git -C "${history_dir}" "${ancestor_arguments[@]}" || exit_status=$?

  case "${exit_status}" in
    0) ;;
    1)
      fatal "The commit in '${version_file}' is not in the history of the branch '${branch}'." \
        "Commit: ${expected_commit}"
      ;;
    *)
      fatal "Failed to check whether the commit in '${version_file}' is in the history of" \
        "the branch '${branch}' (git merge-base exited with ${exit_status})." \
        "Commit: ${expected_commit}"
      ;;
  esac

  log "Verified that branch ${branch} contains ${expected_commit}."
  return 0
}

verify_ref_contains_commit() {
  local history_dir="${1:?verify_ref_contains_commit requires the history clone directory}"
  local ref="${2:?verify_ref_contains_commit requires the tag or branch to check}"
  local expected_commit="${3:?verify_ref_contains_commit requires the expected commit sha}"

  if git -C "${history_dir}" show-ref --verify --quiet "refs/tags/${ref}"; then
    verify_tag_commit "${history_dir}" "${ref}" "${expected_commit}"
  elif git -C "${history_dir}" show-ref --verify --quiet "refs/heads/${ref}"; then
    verify_branch_contains_commit "${history_dir}" "${ref}" "${expected_commit}"
  else
    fatal "The ref '${ref}' in '${version_file}' is neither a tag nor a branch of the repository"
  fi
  return 0
}

fetch_commit() {
  local repository="${1:?fetch_commit requires the upstream repository url}"
  local commit="${2:?fetch_commit requires the commit to fetch}"
  local destination="${3:?fetch_commit requires the destination directory}"

  log "Fetching ${commit} from ${repository}..."
  if ! git init --quiet "${destination}"; then
    fatal "Failed to initialize a repository at '${destination}'"
  fi

  if ! git -C "${destination}" fetch --quiet --depth 1 "${repository}" "${commit}"; then
    fatal "Failed to fetch the commit '${commit}' of '${repository}'"
  fi

  local -a checkout_arguments=(
    -c advice.detachedHead=false
    checkout --quiet FETCH_HEAD
  )
  if ! git -C "${destination}" "${checkout_arguments[@]}"; then
    fatal "Failed to check out the commit '${commit}' in '${destination}'"
  fi
  return 0
}

verify_commit() {
  local clone_dir="${1:?verify_commit requires the clone directory}"
  local expected_commit="${2:?verify_commit requires the expected commit sha}"

  local actual_commit
  if ! actual_commit="$(git -C "${clone_dir}" rev-parse HEAD)"; then
    fatal "Failed to resolve HEAD of the clone at '${clone_dir}'"
  fi

  if [[ "${actual_commit}" != "${expected_commit}" ]]; then
    fatal "The clone is not at the commit that '${version_file}' records." \
      "Expected: ${expected_commit}" \
      "Actual:   ${actual_commit}"
  fi

  log "Verified upstream commit ${actual_commit}."
  return 0
}

# The .cc files upstream itself compiles into libhwy, so that vendoring follows upstream rather
# than a list here that would silently drift away from it.
library_sources_from_cmake() {
  local clone_dir="${1:?library_sources_from_cmake requires the clone directory}"

  local listed_sources
  listed_sources="$(
    awk '
      /^[[:space:]]*set\([[:space:]]*HWY_SOURCES/ { in_block = 1 }
      /^[[:space:]]*list\([[:space:]]*APPEND[[:space:]]+HWY_SOURCES/ { in_block = 1 }
      in_block && match($0, /hwy\/[A-Za-z0-9_\/.-]+\.cc/) {
        print substr($0, RSTART, RLENGTH)
      }
      in_block && /^[[:space:]]*\)[[:space:]]*$/ { in_block = 0 }
    ' "${clone_dir}/CMakeLists.txt"
  )"

  printf -- '%s\n' "${listed_sources}" | sort -u
  return 0
}

copy_headers() {
  local clone_dir="${1:?copy_headers requires the clone directory}"

  log "Copying headers..."
  if ! rsync --archive --quiet \
    --exclude='tests/' \
    --exclude='contrib/' \
    --exclude='*_test.h' \
    --exclude='*_test_util.h' \
    --include='*/' \
    --include='*.h' \
    --exclude='*' \
    --prune-empty-dirs \
    "${clone_dir}/hwy/" "${include_root}/hwy/"; then
    fatal "Failed to copy the headers of '${clone_dir}/hwy' into '${include_root}/hwy'"
  fi
  return 0
}

copy_sources() {
  local clone_dir="${1:?copy_sources requires the clone directory}"
  local -n source_paths_ref="${2:?copy_sources requires the name of the source path array}"

  log "Copying ${#source_paths_ref[@]} library sources..."
  local source_path
  for source_path in "${source_paths_ref[@]}"; do
    if [[ ! -f "${clone_dir}/${source_path}" ]]; then
      fatal "Upstream lists '${source_path}' as a library source but the clone does not have it"
    fi

    mkdir -p -- "${include_root}/$(dirname -- "${source_path}")"
    if ! cp -- "${clone_dir}/${source_path}" "${include_root}/${source_path}"; then
      fatal "Failed to copy '${source_path}' into '${include_root}'"
    fi
  done
  return 0
}

copy_port_headers() {
  local clone_dir="${1:?copy_port_headers requires the clone directory}"

  log "Copying ${#port_headers[@]} headers for the product..."
  local upstream_path destination
  for upstream_path in "${!port_headers[@]}"; do
    destination="${port_vendor_root}/${port_headers["${upstream_path}"]}"

    if [[ ! -f "${clone_dir}/${upstream_path}" ]]; then
      fatal "The product needs '${upstream_path}' but the clone does not have it"
    fi

    mkdir -p -- "$(dirname -- "${destination}")"
    if ! cp -- "${clone_dir}/${upstream_path}" "${destination}"; then
      fatal "Failed to copy '${upstream_path}' into '${port_vendor_root}'"
    fi
  done
  return 0
}

copy_license() {
  local clone_dir="${1:?copy_license requires the clone directory}"

  local license_name
  for license_name in LICENSE LICENSE-BSD3; do
    if [[ -f "${clone_dir}/${license_name}" ]]; then
      cp -- "${clone_dir}/${license_name}" "${vendor_root}/${license_name}"
    fi
  done
  return 0
}

# The op reference, so that an update can list the ops upstream adds and removes.
copy_quick_reference() {
  local clone_dir="${1:?copy_quick_reference requires the clone directory}"

  local quick_reference="${clone_dir}/g3doc/quick_reference.md"
  if ! cp -- "${quick_reference}" "${vendor_root}/quick_reference.md"; then
    fatal "Failed to copy '${quick_reference}' into '${vendor_root}'"
  fi
  return 0
}

# Patches are written against the upstream tree rather than this one, so that the very same file
# can go upstream unchanged.
apply_patches() {
  local ref="${1:?apply_patches requires the ref the patches are written against}"
  local commit="${2:?apply_patches requires the commit the patches are written against}"

  if [[ ! -d "${patch_root}" ]]; then
    return 0
  fi

  local -a patch_paths=()
  local patch_path
  while IFS= read -r -d '' patch_path; do
    patch_paths+=( "${patch_path}" )
  done < <(find "${patch_root}" -name '*.patch' -type f -print0 | sort -z)

  if [[ "${#patch_paths[@]}" -eq 0 ]]; then
    return 0
  fi

  log "Applying ${#patch_paths[@]} patches..."
  local -a apply_arguments=(
    apply --directory="${include_root#"${repository_root}/"}"
  )
  for patch_path in "${patch_paths[@]}"; do
    if ! git -C "${repository_root}" "${apply_arguments[@]}" -- "${patch_path}"; then
      fatal "Failed to apply '${patch_path#"${repository_root}/"}' to the vendored tree." \
        "Rebase it onto highway ${ref} (${commit:0:7}), or drop it if upstream has taken it."
    fi
  done
  return 0
}

headers_reachable_from_seeds() {
  local -A reached=()
  local -a queue=( "${module_seed_headers[@]}" )
  local index=0
  local header included

  while [[ "${index}" -lt "${#queue[@]}" ]]; do
    header="${queue[${index}]}"
    index=$(( index + 1 ))

    if [[ -n "${reached["${header}"]:-}" || ! -f "${include_root}/${header}" ]]; then
      continue
    fi
    reached["${header}"]=1

    while IFS= read -r included; do
      queue+=( "${included}" )
    done < <(
      sed -n 's|^[[:space:]]*#[[:space:]]*include[[:space:]]*"\([^"]*\)".*|\1|p' \
        "${include_root}/${header}"
    )
  done

  if [[ "${#reached[@]}" -eq 0 ]]; then
    fatal "None of the seed headers of the module map exist under '${include_root}'"
  fi

  printf -- '%s\n' "${!reached[@]}" | sort
  return 0
}

# A header that is included more than once, or only from inside HWY_NAMESPACE, cannot be a module
# of its own, which upstream marks by the '-inl.h' suffix.
is_textual_header() {
  local header_path="${1:?is_textual_header requires the header path}"

  case "${header_path}" in
    *-inl.h | hwy/highway.h | hwy/foreach_target.h) return 0 ;;
    *) return 1 ;;
  esac
}

generate_module_map() {
  log "Generating ${module_map#"${repository_root}/"}..."

  local -A in_module=()
  local reachable
  while IFS= read -r reachable; do
    in_module["${reachable}"]=1
  done < <(headers_reachable_from_seeds)

  local -a header_paths=()
  local header_path
  while IFS= read -r -d '' header_path; do
    header_paths+=( "${header_path#"${include_root}/"}" )
  done < <(find "${include_root}/hwy" -name '*.h' -type f -print0 | sort -z)

  if [[ "${#header_paths[@]}" -eq 0 ]]; then
    fatal "Found no headers under '${include_root}/hwy' to generate a module map from"
  fi

  {
    printf -- '%s\n' "// Generated by scripts/vendor-highway.sh. Do not edit."
    printf -- '%s\n' ""
    printf -- '%s\n' "module CHighway {"

    for header_path in "${header_paths[@]}"; do
      if ! is_textual_header "${header_path}" && [[ -n "${in_module["${header_path}"]:-}" ]]; then
        printf -- '    header "%s"\n' "${header_path}"
      fi
    done

    printf -- '%s\n' ""

    for header_path in "${header_paths[@]}"; do
      if is_textual_header "${header_path}"; then
        printf -- '    textual header "%s"\n' "${header_path}"
      fi
    done

    printf -- '%s\n' ""
    printf -- '%s\n' "    requires cplusplus"
    printf -- '%s\n' "    export *"
    printf -- '%s\n' "}"
  } > "${module_map}"

  return 0
}

main() {
  require_command git
  require_command jq
  require_command rsync

  if [[ ! -f "${version_file}" ]]; then
    fatal "There is no '${version_file}' to read the pinned upstream version from"
  fi

  local repository ref commit
  repository="$(version_field repository)"
  ref="$(version_field ref)"
  commit="$(version_field commit)"

  trap cleanup EXIT
  clone_dir="$(mktemp -d)" || fatal "Failed to create a temporary directory for the clone"
  history_dir="$(mktemp -d)" || fatal "Failed to create a temporary directory for the history"

  clone_history "${repository}" "${history_dir}"
  verify_ref_contains_commit "${history_dir}" "${ref}" "${commit}"
  fetch_commit "${repository}" "${commit}" "${clone_dir}"
  verify_commit "${clone_dir}" "${commit}"

  local -a source_paths=()
  while IFS= read -r source_path; do
    [[ -n "${source_path}" ]] && source_paths+=( "${source_path}" )
  done < <(library_sources_from_cmake "${clone_dir}")

  if [[ "${#source_paths[@]}" -eq 0 ]]; then
    fatal "Parsed no library sources out of '${clone_dir}/CMakeLists.txt'"
  fi

  log "Removing the previously vendored trees..."
  rm -rf -- "${include_root}/hwy" "${port_vendor_root}"
  mkdir -p -- "${include_root}"

  copy_headers "${clone_dir}"
  copy_sources "${clone_dir}" source_paths
  copy_port_headers "${clone_dir}"
  copy_license "${clone_dir}"
  copy_quick_reference "${clone_dir}"
  apply_patches "${ref}" "${commit}"
  generate_module_map

  log "✅ Vendored highway ${ref} (${commit:0:7})."
  return 0
}

main "$@"
