#!/usr/bin/env bash
# Copyright 2024 RISC Zero, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -eu -o pipefail

# Define the download root URL for your binaries
RZUP_BINARY_UPDATE_ROOT="${RZUP_BINARY_UPDATE_ROOT:-https://github.com/hmrtn/asset-test/releases/download/test1/}"
QUIET=no

# Define the cargo bin directory
CARGO_BIN_DIR="${HOME}/.cargo/bin"

usage() {
    cat <<EOF
rzup-init

The installer for rzup from RISC Zero.

Usage: rzup-init.sh [OPTIONS]

Options:
  -v, --verbose
          Enable verbose output
  -q, --quiet
          Disable progress output
  -y, --yes
          Disable confirmation prompt
  -h, --help
          Print help
EOF
}

cleanup() {
    if [ -n "${_dir:-}" ] && [ -d "$_dir" ]; then
        rm -rf "$_dir"
    fi
}

trap cleanup EXIT

main() {
    downloader --check
    need_cmd uname
    need_cmd mktemp
    need_cmd chmod
    need_cmd mkdir
    need_cmd rm
    need_cmd rmdir
    need_cmd mv

    check_rust_installed || return 1

    get_architecture || return 1
    _arch="$RETVAL"
    assert_nz "$_arch" "arch"

    _url="${RZUP_BINARY_UPDATE_ROOT}/rzup"
    if ! _dir="$(ensure mktemp -d)"; then
        exit 1
    fi
    _file="${_dir}/rzup"

    # Remove the old version if it exists
    if [ -f "$CARGO_BIN_DIR/rzup" ]; then
        rm "$CARGO_BIN_DIR/rzup"
        info "Removed old version of rzup"
    fi

    # Check if ANSI escape sequences are supported
    _ansi_escapes_are_valid=false
    if [ -t 2 ]; then
        if [ "${TERM+set}" = 'set' ]; then
            case "$TERM" in
                xterm*|rxvt*|urxvt*|linux*|vt*)
                    _ansi_escapes_are_valid=true
                ;;
            esac
        fi
    fi

    need_tty=yes
    for arg in "$@"; do
        case "$arg" in
            --help)
                usage
                exit 0
                ;;
            --quiet)
                QUIET=yes
                ;;
            -q|--quiet)
                QUIET=yes
                ;;
            -y|--yes)
                need_tty=no
                ;;
            *)
                ;;
        esac
    done

    info 'Downloading installer'

    ensure mkdir -p "$_dir"
    ensure downloader "$_url" "$_file"
    ensure chmod u+x "$_file"
    if [ ! -x "$_file" ]; then
        err "Cannot execute $_file"
        err "Please copy the file to a location where the binary can be executed."
        exit 1
    fi

    # Ensure the cargo bin directory exists
    ensure mkdir -p "$CARGO_BIN_DIR"

    # Move the binary to the cargo bin directory
    ensure mv "$_file" "$CARGO_BIN_DIR"

    info "rzup has been installed to $CARGO_BIN_DIR"

    update_path

    info "🎉 rzup installed!"
    echo "Run the following commands to install the zkVM:"
    echo "  source ${PROFILE}"
    echo "  rzup install"
    return 0
}

check_rust_installed() {
    if ! check_cmd rustc; then
        err "Rust is not installed. Please install Rust from https://rustup.rs/ and run this script again."
        return 1
    fi
    return 0
}

get_architecture() {
    _ostype="$(uname -s)"
    _cputype="$(uname -m)"
    _bitness="$(getconf LONG_BIT)"

    case "$_ostype" in
        Linux)
            _ostype=linux
            ;;
        Darwin)
            _ostype=darwin
            ;;
        *)
            err "unsupported OS type: $_ostype"
            exit 1
            ;;
    esac

    case "$_cputype" in
        x86_64|amd64)
            _cputype=x86_64
            ;;
        aarch64|arm64)
            _cputype=arm64
            ;;
        armv7l)
            _cputype=armv7
            ;;
        i386|i686)
            _cputype=x86
            ;;
        *)
            err "unknown CPU type: $_cputype"
            exit 1
            ;;
    esac

    _arch="${_cputype}-${_ostype}"

    RETVAL="$_arch"
}

update_path() {
    detect_shell
    if [[ ":$PATH:" != *":${CARGO_BIN_DIR}:"* ]]; then
        info "Adding rzup to PATH in ${PROFILE}"
        case "$PREF_SHELL" in
            fish)
                echo "set -x PATH \$PATH $CARGO_BIN_DIR" >> "$PROFILE"
                ;;
            *)
                echo "export PATH=\"\$PATH:$CARGO_BIN_DIR\"" >> "$PROFILE"
                ;;
        esac
        info "Run the following commands to update your shell:"
        info "source ${PROFILE}"
        info "rzup"
    else
        info "rzup is already in your PATH"
    fi
}

detect_shell() {
    case $SHELL in
    */zsh) PROFILE="${ZDOTDIR:-"$HOME"}/.zshenv"; PREF_SHELL='zsh' ;;
    */bash) PROFILE="$HOME/.bashrc"; PREF_SHELL='bash' ;;
    */fish) PROFILE="$HOME/.config/fish/config.fish"; PREF_SHELL='fish' ;;
    */ash) PROFILE="$HOME/.profile"; PREF_SHELL='ash' ;;
    *) err "Could not detect shell, manually add ${CARGO_BIN_DIR} to your PATH." ;;
    esac
    info "Detected your preferred shell as ${PREF_SHELL}"
}

info() {
    if [ "$QUIET" = "no" ]; then
        printf 'info: %s\n' "$1" >&2
    fi
}

err() {
    printf 'error: %s\n' "$1" >&2
    exit 1
}

warn() {
    printf 'warn: %s\n' "$1" >&2
}

need_cmd() {
    if ! check_cmd "$1"; then
        err "need '$1' (command not found)"
    fi
}

check_cmd() {
    command -v "$1" > /dev/null 2>&1
}

assert_nz() {
    if [ -z "$1" ]; then
        err "assert_nz $2"
    fi
}

ensure() {
    if ! "$@"; then
        err "command failed: $*"
    fi
}

ignore() {
    "$@"
}

downloader() {
    if [ "$1" = --check ]; then
        if check_cmd curl; then
            return 0
        elif check_cmd wget; then
            return 0
        else
            err "need 'curl' or 'wget' (neither found)"
        fi
    else
        _url="$1"
        _file="$2"
        if check_cmd curl; then
            _err=$(curl --silent --show-error --fail --location "$_url" --output "$_file" 2>&1) || true
            if [ -n "$_err" ]; then
                err "$_err"
            fi
        elif check_cmd wget; then
            _err=$(wget --quiet --output-document="$2" "$1" 2>&1) || true
            if [ -n "$_err" ]; then
                err "$_err"
            fi
        else
            err "need 'curl' or 'wget' (neither command found)"
        fi
    fi
}

main "$@" || exit 1
