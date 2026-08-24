#!/bin/bash

set -euo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

# shellcheck disable=SC1091
source "$PROJECT_DIR/uninstall-asus-linux.sh"

[[ "$SCRIPT_VERSION" == "22.3.3" ]] || {
    echo "FAIL: unexpected uninstaller release version" >&2
    exit 1
}

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

assert_true() {
    local message="$1"
    shift
    "$@" || fail "$message"
}

assert_false() {
    local message="$1"
    shift
    if "$@"; then
        fail "$message"
    fi
}

original_base_dir="$BASE_DIR"
BASE_DIR="/"
assert_false "filesystem root must be rejected" validate_build_directory
BASE_DIR="relative/path"
assert_false "relative build directories must be rejected" validate_build_directory
BASE_DIR="$original_base_dir"
assert_true "default build directory must be accepted" validate_build_directory

test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT
mkdir -p "$test_root/real"
ln -s "$test_root/real" "$test_root/link"
BASE_DIR="$test_root/link"
assert_false "symlinked build directories must be rejected" validate_build_directory

legacy_content_hash=$(printf 'blacklist nouveau\noptions nouveau modeset=0\n' | sha256sum | awk '{print $1}')
grep -Fq "local legacy_hash=\"$legacy_content_hash\"" "$PROJECT_DIR/uninstall-asus-linux.sh" \
    || fail "legacy Nouveau cleanup hash does not match content from older releases"

echo "Uninstaller unit tests passed."
