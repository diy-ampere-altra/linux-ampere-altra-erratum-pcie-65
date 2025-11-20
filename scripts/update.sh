#!/usr/bin/env bash
set -euo pipefail

log() {
  echo "[$(date -Iseconds)] $*" >&2
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Not inside a git repository"

#######################################
# 1) Find current highest version dir
#######################################
mapfile -t VERSION_DIRS < <(
  find . -maxdepth 1 -type d -name 'v[0-9]*.[0-9]*' -printf '%P\n' | sort -V
)

if ((${#VERSION_DIRS[@]} == 0)); then
  die "No version directories found (vX.Y)"
fi

CURRENT_DIR="${VERSION_DIRS[-1]}"          # e.g. v6.13
CURRENT_SERIES="${CURRENT_DIR#v}"          # e.g. 6.13
CURRENT_TAG="v${CURRENT_SERIES}"

log "Current highest version directory: ${CURRENT_DIR} (tag ${CURRENT_TAG})"

#######################################
# 2) Determine next stable tag from torvalds/linux
#######################################
log "Discovering next stable tag after ${CURRENT_TAG} from torvalds/linux..."

TAGS_RAW="$(git ls-remote --tags https://github.com/torvalds/linux 'v[0-9]*.[0-9]*')" \
  || die "Failed to list remote tags from torvalds/linux"

# Normalize tags: refs/tags/v6.13, refs/tags/v6.13^{} -> v6.13
TAGS_SORTED="$(
  echo "${TAGS_RAW}" \
  | awk '{print $2}' \
  | sed 's@refs/tags/@@' \
  | sed 's@\^{}@@' \
  | grep -E '^v[0-9]+\.[0-9]+$' \
  | sort -V \
  | uniq
)"

mapfile -t TAGS_ARR <<<"${TAGS_SORTED}"

NEXT_TAG=""
for ((i = 0; i < ${#TAGS_ARR[@]}; i++)); do
  if [[ "${TAGS_ARR[i]}" == "${CURRENT_TAG}" ]]; then
    if (( i + 1 < ${#TAGS_ARR[@]} )); then
      NEXT_TAG="${TAGS_ARR[i+1]}"
    fi
    break
  fi
done

if [[ -z "${NEXT_TAG}" ]]; then
  log "No newer stable tag found after ${CURRENT_TAG}."
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      echo "update_mode=none"
      echo "current_dir=${CURRENT_DIR}"
      echo "current_tag=${CURRENT_TAG}"
    } >> "${GITHUB_OUTPUT}"
  fi
  exit 0
fi

NEXT_DIR="${NEXT_TAG}"                     # e.g. v6.14
BRANCH_NAME="update/${NEXT_DIR}"

log "Next stable tag: ${NEXT_TAG}, new directory: ${NEXT_DIR}, branch: ${BRANCH_NAME}"

#######################################
# 3) Abort if branch for newer version already exists
#######################################
if git show-ref --verify --quiet "refs/heads/${BRANCH_NAME}"; then
  log "Local branch ${BRANCH_NAME} already exists. Aborting."
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      echo "update_mode=branch_exists"
      echo "branch_name=${BRANCH_NAME}"
      echo "next_dir=${NEXT_DIR}"
      echo "next_tag=${NEXT_TAG}"
      echo "current_dir=${CURRENT_DIR}"
      echo "current_tag=${CURRENT_TAG}"
    } >> "${GITHUB_OUTPUT}"
  fi
  exit 0
fi

if git ls-remote --exit-code --heads origin "${BRANCH_NAME}" >/dev/null 2>&1; then
  log "Remote branch ${BRANCH_NAME} already exists on origin. Aborting."
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      echo "update_mode=branch_exists"
      echo "branch_name=${BRANCH_NAME}"
      echo "next_dir=${NEXT_DIR}"
      echo "next_tag=${NEXT_TAG}"
      echo "current_dir=${CURRENT_DIR}"
      echo "current_tag=${CURRENT_TAG}"
    } >> "${GITHUB_OUTPUT}"
  fi
  exit 0
fi

#######################################
# 4) Create new branch
#######################################
log "Creating ${BRANCH_NAME}"
git checkout -b "${BRANCH_NAME}"

#######################################
# 5) Create new folder & symlink patches; commit
#######################################
if [[ -e "${NEXT_DIR}" ]]; then
  die "Target directory ${NEXT_DIR} already exists"
fi

mkdir "${NEXT_DIR}"

shopt -s nullglob
PATCH_FILES=("${CURRENT_DIR}"/*.patch)
shopt -u nullglob

if ((${#PATCH_FILES[@]} == 0)); then
  die "No .patch files found in ${CURRENT_DIR}"
fi

for path in "${PATCH_FILES[@]}"; do
  name="$(basename "${path}")"
  ln -s "../${CURRENT_DIR}/${name}" "${NEXT_DIR}/${name}"
done

git add "${NEXT_DIR}"
git commit -m "Add symlink patch set for ${NEXT_DIR} based on ${CURRENT_DIR}"

#######################################
# 6) Clone torvalds/linux & attempt to apply patches
#######################################
TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

LINUX_CLONE="${TMPDIR}/linux-${NEXT_TAG}"
log "Cloning torvalds/linux at tag ${NEXT_TAG} into ${LINUX_CLONE}"

git clone --depth 1 --branch "${NEXT_TAG}" https://github.com/torvalds/linux "${LINUX_CLONE}" >/dev/null

REPO_ROOT="$(pwd)"
pushd "${LINUX_CLONE}" > /dev/null
git checkout -b "pcie65-${NEXT_DIR}" >/dev/null

declare -a P_NAMES=()
declare -a P_STATUS=()
declare -a P_BASE=()
declare -a P_COMMIT=()
declare -a FAILED_PATCHES=()

NEW_PATCH_DIR="${TMPDIR}/new_patches"
mkdir -p "${NEW_PATCH_DIR}"

for path in "${PATCH_FILES[@]}"; do
  name="$(basename "${path}")"
  patch_path="${REPO_ROOT}/${CURRENT_DIR}/${name}"
  log "Applying patch ${name}..."

  base_commit="$(git rev-parse HEAD)"
  status=""

  # 1) Try clean apply
  if git apply --check "${patch_path}" >/dev/null 2>&1; then
    if git apply "${patch_path}" >/dev/null 2>&1; then
      status="clean"
    else
      status="failed"
      git reset --hard "${base_commit}" >/dev/null
    fi
  else
    # 2) Fuzzy apply: git apply --reject --whitespace=fix
    if git apply --reject --whitespace=fix "${patch_path}" >/dev/null 2>&1; then
      if find . -name '*.rej' -print -quit | grep -q .; then
        status="failed"
        git reset --hard "${base_commit}" >/dev/null
        # Clean up any leftover .rej files just in case
        find . -name '*.rej' -delete || true
      else
        status="fuzzy"
      fi
    else
      status="failed"
      git reset --hard "${base_commit}" >/dev/null
    fi
  fi

  if [[ "${status}" == "failed" ]]; then
    log "Patch ${name} FAILED (even with fuzzy)."
    FAILED_PATCHES+=("${name}")
    # Do not commit; keep tree at base_commit and continue with next patch
    continue
  fi

  # Commit applied changes (clean or fuzzy)
  git add -u
  git add . >/dev/null 2>&1 || true
  git commit -m "Apply ${name} for ${NEXT_TAG} (mode: ${status})" >/dev/null

  P_NAMES+=("${name}")
  P_STATUS+=("${status}")
  P_BASE+=("${base_commit}")
  P_COMMIT+=("$(git rev-parse HEAD)")
done

popd > /dev/null

#######################################
# 7) Generate new patch files for fuzzy patches
#######################################
for idx in "${!P_NAMES[@]}"; do
  if [[ "${P_STATUS[$idx]}" == "fuzzy" ]]; then
    name="${P_NAMES[$idx]}"
    base="${P_BASE[$idx]}"
    commit="${P_COMMIT[$idx]}"
    log "Generating updated patch for ${name} (fuzzy) from ${base}..${commit}"
    git format-patch --stdout "${base}..${commit}" > "${NEW_PATCH_DIR}/${name}"
  fi
done

#######################################
# 8) Replace symlinks with real files for fuzzy patches; commit
#######################################
cd "${REPO_ROOT}"
git checkout "${BRANCH_NAME}"

F_FUZZY_COUNT=0

for idx in "${!P_NAMES[@]}"; do
  if [[ "${P_STATUS[$idx]}" == "fuzzy" ]]; then
    name="${P_NAMES[$idx]}"
    if [[ -f "${NEW_PATCH_DIR}/${name}" ]]; then
      log "Replacing symlink ${NEXT_DIR}/${name} with regenerated patch file"
      rm -f "${NEXT_DIR}/${name}"
      cp "${NEW_PATCH_DIR}/${name}" "${NEXT_DIR}/${name}"
      F_FUZZY_COUNT=$((F_FUZZY_COUNT + 1))
    fi
  fi
done

if ((F_FUZZY_COUNT > 0)); then
  git add "${NEXT_DIR}"
  git commit -m "Regenerate fuzzy patches for ${NEXT_DIR}" >/dev/null
fi

#######################################
# 9) Prepare outputs for GitHub Actions
#######################################
has_errors="false"
failed_list=""

if ((${#FAILED_PATCHES[@]} > 0)); then
  has_errors="true"
  failed_list="$(IFS=,; echo "${FAILED_PATCHES[*]}")"
  log "Some patches failed: ${failed_list}"
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "update_mode=updated"
    echo "branch_name=${BRANCH_NAME}"
    echo "next_dir=${NEXT_DIR}"
    echo "next_tag=${NEXT_TAG}"
    echo "current_dir=${CURRENT_DIR}"
    echo "current_tag=${CURRENT_TAG}"
    echo "has_errors=${has_errors}"
    echo "failed_patches=${failed_list}"
  } >> "${GITHUB_OUTPUT}"
fi

log "Finished update. Branch ${BRANCH_NAME}, directory ${NEXT_DIR}, has_errors=${has_errors}"

exit 0
