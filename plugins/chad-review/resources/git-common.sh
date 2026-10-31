# git-common.sh: git settings and helpers shared by receipt.sh and pr-stage.sh.
# Sourced, never run. Each caller sources it from its own directory, so the
# two scripts cannot drift apart on the diff knobs or on base resolution.
#
# BASH 3.2. Defines variables and functions only; no side effects.

# Every diff knob pinned. User config (diff.noprefix, mnemonicPrefix,
# external drivers, algorithm) must not be able to make two runs disagree
# about the same content. Callers build their own array from the two halves:
#   git "${GIT_DIFF_CONFIG[@]}" [extra -c ...] "${GIT_DIFF_ARGS[@]}"
# receipt.sh fingerprints depend on this exact set, so a change here re-arms
# every outstanding receipt.
GIT_DIFF_CONFIG=(-c core.quotepath=false -c diff.noprefix=false
                 -c diff.mnemonicPrefix=false -c diff.srcPrefix=a/ -c diff.dstPrefix=b/
                 -c diff.relative=false)
GIT_DIFF_ARGS=(diff --no-color --no-ext-diff --no-textconv --no-renames
                    --full-index --diff-algorithm=myers)

# resolve_base_ref [explicit-ref]: prints the base ref, or returns 1 when none
# resolves. An explicit ref is printed as given (the caller verifies it).
# Otherwise: the origin/HEAD symbolic ref, then the first of origin/main,
# origin/master, main, master that names a commit.
resolve_base_ref() {
  local b
  if [[ -n "${1:-}" ]]; then printf '%s\n' "$1"; return 0; fi
  b=$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [[ -n "$b" ]]; then printf '%s\n' "$b"; return 0; fi
  for b in origin/main origin/master main master; do
    if git rev-parse -q --verify "$b^{commit}" >/dev/null 2>&1; then
      printf '%s\n' "$b"; return 0
    fi
  done
  return 1
}
