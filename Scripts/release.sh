#!/usr/bin/env bash
#
# Prepare and publish a release:
#
#   1. compute the next version from the conventional commits since the last tag
#   2. write the changelog entry and refresh the README version references
#   3. commit the release files, tag that commit, and push main plus the tag
#   4. create the GitHub release from the changelog entry
#
# Usage:
#   Scripts/release.sh [auto|patch|minor|major|<x.y.z>] [options]
#
#   auto                derive the bump from the commits since the last tag
#   patch|minor|major   force that bump
#   x.y.z               use an explicit version
#
# Options:
#   --yes           skip the confirmation prompt (the workflow passes this)
#   --dry-run       print the plan without changing anything
#   --edit          open the editor on the generated changelog entry
#   --force         release even when only maintenance commits are found
#   --skip-tests    skip the formatter and unit-test gate
#   --no-push       commit and tag locally, but do not push
#   --no-release    skip creating the GitHub release
#   -h, --help      show this help
#
# Commit messages follow the Conventional Commits style used in this
# repository: feat bumps minor, fix/perf/refactor bump patch, and a "!" marker
# or a BREAKING CHANGE footer bumps major (minor while the version is 0.x).
#
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$REPO_ROOT"

die() { printf 'release: error: %s\n' "$*" >&2; exit 1; }
info() { printf 'release: %s\n' "$*"; }
warn() { printf 'release: warning: %s\n' "$*" >&2; }
step() { printf '\n==> %s\n' "$*"; }

usage() {
    sed -n '2,/^$/p' "$0" | sed 's/^#\{0,1\} \{0,1\}//'
    exit 0
}

# True (exit 0) when semver $1 is greater than semver $2.
version_gt() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        n = split(a, x, ".")
        m = split(b, y, ".")
        for (i = 1; i <= 3; i++) {
            ai = (i <= n ? x[i] + 0 : 0)
            bi = (i <= m ? y[i] + 0 : 0)
            if (ai > bi) exit 0
            if (ai < bi) exit 1
        }
        exit 1
    }'
}

# bump_version <version> <major|minor|patch>
bump_version() {
    awk -v v="$1" -v part="$2" 'BEGIN {
        split(v, x, ".")
        if (part == "major") { x[1]++; x[2] = 0; x[3] = 0 }
        else if (part == "minor") { x[2]++; x[3] = 0 }
        else { x[3]++ }
        printf "%d.%d.%d\n", x[1], x[2], x[3]
    }'
}

# Strips the conventional-commit prefix and capitalizes the sentence.
clean_subject() {
    printf '%s\n' "$1" | sed -E 's/^[a-z]+(\([^)]*\))?!?: //' | awk '{
        if ($0 ~ /^[a-z]/) $0 = toupper(substr($0, 1, 1)) substr($0, 2)
        print
    }'
}

bump_arg=auto
assume_yes=0
dry_run=0
edit_notes=0
force=0
run_tests=1
push=1
create_release=1

for arg in "$@"; do
    case "$arg" in
        auto|patch|minor|major) bump_arg="$arg" ;;
        --yes|-y) assume_yes=1 ;;
        --dry-run) dry_run=1 ;;
        --edit) edit_notes=1 ;;
        --force) force=1 ;;
        --skip-tests) run_tests=0 ;;
        --no-push) push=0 ;;
        --no-release) create_release=0 ;;
        -h|--help) usage ;;
        [0-9]*.[0-9]*.[0-9]*) bump_arg="$arg" ;;
        *) die "unknown argument: $arg (try --help)" ;;
    esac
done

[ -f Package.swift ] || die "Package.swift not found; run this from the LazyKit repository"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git repository"

branch=$(git rev-parse --abbrev-ref HEAD)
[ "$branch" = main ] || die "releases are cut from main (currently on $branch)"

if [ -n "$(git status --porcelain)" ]; then
    die "working tree is dirty; commit or stash your changes first"
fi

if [ "$push" = 1 ]; then
    git fetch --quiet --tags origin main || die "could not fetch from origin"
    behind=$(git rev-list --count HEAD..origin/main || echo 0)
    [ "$behind" = 0 ] || die "main is $behind commit(s) behind origin/main; pull first"
fi

last_tag=$(git describe --tags --abbrev=0 2>/dev/null || true)
if [ -n "$last_tag" ]; then
    log_range="$last_tag..HEAD"
    base_version=$(printf '%s\n' "$last_tag" | sed 's/^v//')
    since_label=$last_tag
else
    log_range=HEAD
    base_version=
    since_label="the start of history"
fi

subjects=$(git log --no-merges --format='%s' "$log_range" | grep -vE '^chore: release ' || true)
if [ -z "$subjects" ]; then
    die "no commits to release since $since_label"
fi

if printf '%s\n' "$subjects" | grep -qE '^[a-z]+(\([^)]*\))?!:' \
    || [ -n "$(git log --no-merges --grep='BREAKING CHANGE' --format='%h' "$log_range")" ]; then
    has_breaking=1
else
    has_breaking=0
fi

tag_prefix=
case "$last_tag" in
    v*) tag_prefix=v ;;
esac

if printf '%s\n' "$bump_arg" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    version=$bump_arg
else
    [ -n "$last_tag" ] || die "no tags found; pass an explicit version, for example 0.1.0"

    case "$bump_arg" in
        auto)
            if [ "$has_breaking" = 1 ]; then
                bump=major
            elif printf '%s\n' "$subjects" | grep -qE '^feat(\([^)]*\))?!?:'; then
                bump=minor
            elif printf '%s\n' "$subjects" | grep -qE '^(fix|perf|refactor)(\([^)]*\))?!?:'; then
                bump=patch
            else
                bump=none
            fi
            ;;
        *) bump=$bump_arg ;;
    esac

    if [ "$bump" = none ]; then
        [ "$force" = 1 ] || die "only maintenance commits since $last_tag; pass an explicit version or --force"
        bump=patch
    fi

    major_part=$(printf '%s\n' "$base_version" | cut -d. -f1)
    if [ "$major_part" = 0 ] && [ "$bump" = major ]; then
        info "a breaking change while pre-1.0 bumps the minor version instead of the major"
        bump=minor
    fi

    version=$(bump_version "$base_version" "$bump")
fi

if [ -n "$last_tag" ]; then
    version_gt "$version" "$base_version" || die "$version is not greater than the last release $last_tag"
fi

tag_name=$tag_prefix$version
breaking_subjects=$(printf '%s\n' "$subjects" | grep -E '^[a-z]+(\([^)]*\))?!:' || true)

notes=$(printf '%s\n' "$subjects" | awk '
    function clean(s) {
        sub(/^[a-z]+(\([^)]*\))?!?: /, "", s)
        if (s ~ /^[a-z]/) s = toupper(substr(s, 1, 1)) substr(s, 2)
        return s
    }
    function section(title, i) {
        if (count[title] == 0) return
        printf "### %s\n\n", title
        for (i = 1; i <= count[title]; i++) printf "- %s\n", items[title, i]
        printf "\n"
    }
    {
        line = clean($0)
        if (line == "") next
        if ($0 ~ /^feat(\([^)]*\))?!?:/) title = "Added"
        else if ($0 ~ /^fix(\([^)]*\))?!?:/) title = "Fixed"
        else if ($0 ~ /^(perf|refactor)(\([^)]*\))?!?:/) title = "Changed"
        else if ($0 ~ /^docs(\([^)]*\))?!?:/) title = "Documentation"
        else title = "Maintenance"
        count[title]++
        items[title, count[title]] = line
    }
    END {
        section("Added")
        section("Fixed")
        section("Changed")
        section("Documentation")
        section("Maintenance")
    }
')

notes_file=$(mktemp)
{
    printf '## %s — %s\n\n' "$version" "$(date +%F)"
    if [ -n "$breaking_subjects" ]; then
        printf '### Breaking changes\n\n'
        printf '%s\n' "$breaking_subjects" | while IFS= read -r subject; do
            printf -- '- %s\n' "$(clean_subject "$subject")"
        done
        printf '\n'
    fi
    printf '%s\n\n' "$notes"
} > "$notes_file"

if [ "$dry_run" = 1 ]; then
    step "Dry run"
    cat "$notes_file"
    printf 'version:  %s\n' "$version"
    printf 'tag:      %s (annotated)\n' "$tag_name"
    printf 'commit:   chore: release %s\n' "$version"
    printf 'files:    CHANGELOG.md, README.md version references\n'
    printf 'push:     %s and the tag\n' "$branch"
    rm -f "$notes_file"
    exit 0
fi

if [ "$run_tests" = 1 ]; then
    step "Formatter and unit tests"
    swift format lint --strict --parallel --recursive Sources Tests Demo
    swift test
fi

if [ "$edit_notes" = 1 ]; then
    editor=$(printenv EDITOR || true)
    if [ -z "$editor" ]; then editor=vi; fi
    "$editor" "$notes_file"
fi

if [ "$assume_yes" = 0 ]; then
    step "Release $version"
    cat "$notes_file"
    printf 'Commit, tag, and push %s? [y/N] ' "$tag_name"
    read -r reply
    case "$reply" in
        y|Y|yes) ;;
        *) rm -f "$notes_file"; die "aborted" ;;
    esac
fi

first_section=$(grep -n '^## ' CHANGELOG.md | head -n 1 | cut -d: -f1 || true)
tmp_changelog=$(mktemp)
if [ -n "$first_section" ]; then
    head -n $((first_section - 1)) CHANGELOG.md > "$tmp_changelog"
    cat "$notes_file" >> "$tmp_changelog"
    tail -n +"$first_section" CHANGELOG.md >> "$tmp_changelog"
else
    cat CHANGELOG.md > "$tmp_changelog"
    printf '\n' >> "$tmp_changelog"
    cat "$notes_file" >> "$tmp_changelog"
fi
mv "$tmp_changelog" CHANGELOG.md

if [ -n "$base_version" ] && [ -f README.md ]; then
    tmp_readme=$(mktemp)
    awk -v old="$base_version" -v new="$version" '
        BEGIN { bt = sprintf("%c", 96) }
        {
            gsub("from: \"" old "\"", "from: \"" new "\"")
            gsub("releases/tag/" old, "releases/tag/" new)
            gsub(bt old bt, bt new bt)
            print
        }
    ' README.md > "$tmp_readme"
    if cmp -s README.md "$tmp_readme"; then
        rm -f "$tmp_readme"
    else
        mv "$tmp_readme" README.md
        info "README.md now points at $version"
    fi
fi

git add CHANGELOG.md README.md
git commit -m "chore: release $version"

step "Tag"
git tag -a "$tag_name" -m "LazyKit $version"

if [ "$push" = 1 ]; then
    step "Push"
    git push origin main --follow-tags
else
    info "not pushed (--no-push); publish later with: git push origin main --follow-tags"
fi

if [ "$create_release" = 1 ]; then
    if [ "$push" = 0 ]; then
        info "skipping the GitHub release because the tag was not pushed"
    elif command -v gh >/dev/null 2>&1; then
        step "GitHub release"
        if gh release create "$tag_name" --title "$version" --notes-file "$notes_file"; then
            info "created the GitHub release for $tag_name"
        else
            warn "the tag is pushed, but the GitHub release was not created"
            warn "retry with: gh release create $tag_name --title $version --notes-file <notes>"
        fi
    else
        info "gh CLI not found; create the release from the tag in the GitHub UI"
    fi
fi

rm -f "$notes_file"
printf '\nrelease: %s is out\n' "$version"
