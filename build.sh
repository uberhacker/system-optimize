#!/usr/bin/env bash
# build.sh - make the single-file build of system-optimize.
#
#   ./build.sh [OUTPUT]            default OUTPUT: dist/system-optimize
#   ./build.sh -o OUTPUT | --output OUTPUT
#
# The entry point (bin/system-optimize) is copied with the block between
# its @@BUNDLE-MODULES-BEGIN@@ / -END@@ markers replaced by the contents of
# the modules it sources, in the same order. The entry point's
# `SO_BUNDLED=0` line becomes `SO_BUNDLED=1`; the version and the git
# commit are recorded at the top (SO_BUNDLE_VERSION, SO_BUNDLE_COMMIT) and
# the bash completion script is embedded for `--completion bash` and
# docs/steps.md for `describe`. The result
# is plain bash: nothing is compiled, it needs the same bash 4.4 and
# coreutils as the multi-file version, and it is checked with bash -n.
set -euo pipefail

root=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
out="$root/dist/system-optimize"
while [ $# -gt 0 ]; do
  case "$1" in
    -o|--output) [ -n "${2:-}" ] || { echo "build.sh: $1 needs a value" >&2; exit 2; }; out="$2"; shift ;;
    --output=*) out="${1#*=}" ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "build.sh: unknown option: $1" >&2; exit 2 ;;
    *) out="$1" ;;
  esac
  shift
done
entry="$root/bin/system-optimize"

if ! grep -q '^# @@BUNDLE-MODULES-BEGIN@@$' "$entry" || ! grep -q '^# @@BUNDLE-MODULES-END@@$' "$entry" \
   || ! grep -q '^SO_BUNDLED=0' "$entry"; then
  echo "build.sh: bundle markers not found in $entry" >&2
  exit 1
fi
# The modules the entry point sources, in its order.
# shellcheck disable=SC2016  # $SO_ROOT_DIR is matched literally
mapfile -t modules < <(sed -n 's|^source "\$SO_ROOT_DIR/\(lib/[^"]*\.sh\)"$|\1|p' "$entry")
[ ${#modules[@]} -gt 0 ] || { echo "build.sh: no modules found in $entry" >&2; exit 1; }

version=$(tr -d '[:space:]' < "$root/VERSION")
commit=unknown
if git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
  commit=$(git -C "$root" rev-parse --short HEAD)
  # Modified or untracked files under the bundled paths make it a -dirty build.
  [ -z "$(git -C "$root" status --porcelain -- bin lib/core lib/tweaks completions docs/steps.md VERSION 2>/dev/null)" ] || commit="$commit-dirty"
fi

# module FILE: a module's contents under a banner, without its shebang.
module() {
  printf '\n# ==== %s ====\n' "${1#"$root"/}"
  sed '1{/^#!/d}' "$1"
}

mkdir -p "$(dirname "$out")"
tmp=$(mktemp "$(dirname "$out")/.system-optimize.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT
{
  inside=0
  lineno=0
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    if [ "$lineno" = 1 ]; then
      printf '%s\n' "$line"
      cat <<EOF
#
# Single-file build of system-optimize $version (git $commit), made by
# build.sh from https://github.com/uberhacker/system-optimize. Do not
# edit: change the modules in lib/ and rebuild.
SO_BUNDLE_VERSION='$version'
SO_BUNDLE_COMMIT='$commit'
EOF
      continue
    fi
    case "$line" in
      'SO_BUNDLED=0'*)
        printf 'SO_BUNDLED=1\n'
        continue ;;
      '# @@BUNDLE-MODULES-BEGIN@@')
        inside=1
        for m in "${modules[@]}"; do
          module "$root/$m"
        done
        printf '\n# ==== completions/system-optimize.bash (for --completion bash) ====\n'
        printf "so_completion_script() {\n  cat <<'SO_COMPLETION_EOF'\n"
        cat "$root/completions/system-optimize.bash"
        printf 'SO_COMPLETION_EOF\n}\n'
        if [ -f "$root/docs/steps.md" ]; then
          printf '\n# ==== docs/steps.md (for describe and the tray) ====\n'
          printf "so_steps_doc() {\n  cat <<'SO_STEPS_DOC_EOF'\n"
          cat "$root/docs/steps.md"
          printf 'SO_STEPS_DOC_EOF\n}\n'
        fi
        printf '# ==== end of modules ====\n'
        continue ;;
      '# @@BUNDLE-MODULES-END@@')
        inside=0
        continue ;;
    esac
    [ "$inside" = 1 ] || printf '%s\n' "$line"
  done < "$entry"
} > "$tmp"

bash -n "$tmp" || { echo "build.sh: the result does not parse" >&2; exit 1; }
chmod 0755 "$tmp"
mv -f -- "$tmp" "$out"
trap - EXIT
printf 'built %s (%s, git %s, %s modules, %s lines)\n' "$out" "$version" "$commit" "${#modules[@]}" "$(wc -l < "$out")"
