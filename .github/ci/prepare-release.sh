#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# Bump the named crates, update the `=` pins that point at them, refresh the
# example lockfiles, and add rmk's CHANGELOG heading.
#
#     .github/ci/prepare-release.sh <major|minor|patch> [crate...]   # no crate = all

level="${1:?usage: prepare-release.sh <major|minor|patch> [crate...]}"
shift
if [[ $# -eq 0 ]]; then
    crates=("${RELEASE_BUMPABLE[@]}")
    requested=" ${crates[*]} "
else
    # Assign first: a process substitution would swallow release_closure's exit
    # status, leaving an empty crate list and a release that bumps nothing.
    closure="$(release_closure "$@")"
    crates=()
    while IFS= read -r name; do crates+=("$name"); done <<< "$closure"
    requested=" $* "
fi

# Set a crate's own version, then update every `=` pin that names it.
set_version() {
    local crate="$1" version="$2" manifest name
    manifest="$(crate_manifest "$crate")"
    awk -v v="$version" '
        !done && /^version = "/ { print "version = \"" v "\""; done = 1; next }
        { print }
    ' "$manifest" > "$manifest.new"
    mv "$manifest.new" "$manifest"
    for name in "${RELEASE_CRATES[@]}"; do
        manifest="$(crate_manifest "$name")"
        awk -v n="$crate" -v v="$version" '
            $0 ~ "^" n " *= *\\{" {
                gsub(/version = "=[0-9]+\.[0-9]+\.[0-9]+"/, "version = \"=" v "\"")
            }
            { print }
        ' "$manifest" > "$manifest.new"
        mv "$manifest.new" "$manifest"
    done
}

log_section "Bumping versions"
for crate in "${crates[@]}"; do
    current="$(crate_version "$crate")"
    if [[ ! "$current" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$crate: cannot bump the non-numeric version $current" >&2
        exit 1
    fi
    IFS=. read -r major minor patch <<< "$current"
    case "$level" in
        major) next="$((major + 1)).0.0" ;;
        minor) next="$major.$((minor + 1)).0" ;;
        patch) next="$major.$minor.$((patch + 1))" ;;
        *) echo "unknown bump level: $level" >&2; exit 1 ;;
    esac
    set_version "$crate" "$next"
    case "$requested" in
        *" $crate "*) echo "$crate $current -> $next" ;;
        *) echo "$crate $current -> $next  (pins a crate above)" ;;
    esac
done

# set_version only rewrites pins spelled `name = { ... }` on one line. Any other
# spelling keeps its old version, which cargo would not reject until publish.
log_section "Checking pins"
for crate in "${crates[@]}"; do
    version="$(crate_version "$crate")"
    for name in "${RELEASE_CRATES[@]}"; do
        manifest="$(crate_manifest "$name")"
        awk -v file="$manifest" -v c="$crate" -v v="$version" '
            /^\[/ { table = ($0 ~ "dependencies\\." c "\\]$") }
            $0 ~ "^" c " *= *\\{" || table {
                if (match($0, /version *= *"=[^"]*"/)) {
                    pin = substr($0, RSTART, RLENGTH)
                    sub(/.*"=/, "", pin)
                    sub(/"$/, "", pin)
                    if (pin != v) {
                        printf "::error file=%s,line=%d::%s pin is =%s, expected =%s\n", file, NR, c, pin, v
                        bad = 1
                    }
                }
            }
            END { exit bad + 0 }
        ' "$manifest" || exit 1
    done
done
echo "all pins current"

# Example lockfiles record rmk's version, so the `fetch-check` CI job fails if
# they are left stale.
log_section "Refreshing example lockfiles"
bash scripts/fetch_all.sh

# rmk/CHANGELOG.md is rmk's own, and publish.yml turns the new section into its
# GitHub release notes. A release without rmk in it must not stamp a date there.
log_section "Changelog"
version="$(crate_version rmk)"
if [[ " ${crates[*]} " != *" rmk "* ]]; then
    echo "rmk is not in this release, leaving its changelog alone"
elif grep -q "^## \[$version\]" rmk/CHANGELOG.md; then
    echo "already has a $version section"
else
    awk -v v="$version" -v d="$(date -u +%F)" '
        $0 == "## [Unreleased]" { print; print ""; print "## [" v "] - " d; next }
        { print }
    ' rmk/CHANGELOG.md > rmk/CHANGELOG.new
    mv rmk/CHANGELOG.new rmk/CHANGELOG.md
    echo "rolled [Unreleased] into [$version]"
fi
