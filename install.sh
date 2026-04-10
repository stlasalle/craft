#!/usr/bin/env bash
set -euo pipefail

# install.sh — Install craft from a GitHub release
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/stlasalle/craft/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/stlasalle/craft/main/install.sh | bash -s -- --version 0.1.0

REPO="stlasalle/craft"
INSTALL_DIR="${CRAFT_HOME:-$HOME/.craft}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"

# Parse args
VERSION=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Resolve latest version if not specified
if [[ -z "$VERSION" ]]; then
    echo "Fetching latest version..."
    VERSION=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" | grep '"tag_name"' | sed 's/.*"v\(.*\)".*/\1/')
fi

TAG="v${VERSION}"
TARBALL_URL="https://github.com/${REPO}/archive/refs/tags/${TAG}.tar.gz"

echo "Installing craft ${TAG} to ${INSTALL_DIR}"
echo ""

# Download and extract
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo "Downloading ${TARBALL_URL}..."
curl -fsSL "$TARBALL_URL" -o "$TMPDIR/craft.tar.gz"

echo "Extracting..."
tar -xzf "$TMPDIR/craft.tar.gz" -C "$TMPDIR"

# The tarball extracts to craft-<version>/
EXTRACTED_DIR="$TMPDIR/craft-${VERSION}"
if [[ ! -d "$EXTRACTED_DIR" ]]; then
    echo "Error: expected directory $EXTRACTED_DIR not found after extraction"
    ls "$TMPDIR"
    exit 1
fi

# Install to INSTALL_DIR
mkdir -p "$INSTALL_DIR"

# If upgrading, preserve projects/
if [[ -d "$INSTALL_DIR/projects" ]]; then
    mv "$INSTALL_DIR/projects" "$TMPDIR/_projects_backup"
fi

# Copy files (excluding projects/ from the tarball)
rm -rf "$INSTALL_DIR/bin" "$INSTALL_DIR/templates" "$INSTALL_DIR/shared" "$INSTALL_DIR/homebrew"
cp -R "$EXTRACTED_DIR/bin" "$INSTALL_DIR/bin"
cp -R "$EXTRACTED_DIR/templates" "$INSTALL_DIR/templates"
cp -R "$EXTRACTED_DIR/shared" "$INSTALL_DIR/shared"
cp "$EXTRACTED_DIR/VERSION" "$INSTALL_DIR/VERSION"
cp "$EXTRACTED_DIR/README.md" "$INSTALL_DIR/README.md"
cp "$EXTRACTED_DIR/CLAUDE.md" "$INSTALL_DIR/CLAUDE.md"

# Restore projects/
if [[ -d "$TMPDIR/_projects_backup" ]]; then
    mv "$TMPDIR/_projects_backup" "$INSTALL_DIR/projects"
fi
mkdir -p "$INSTALL_DIR/projects"

# Symlink to BIN_DIR
mkdir -p "$BIN_DIR"
ln -sf "$INSTALL_DIR/bin/craft" "$BIN_DIR/craft"

echo ""
echo "Installed craft ${TAG}"
echo "  Location:  ${INSTALL_DIR}"
echo "  Binary:    ${BIN_DIR}/craft"
echo "  Projects:  ${INSTALL_DIR}/projects/"
echo ""

# Check PATH
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$BIN_DIR"; then
    echo "Add this to your shell profile (~/.bashrc or ~/.zshrc):"
    echo ""
    echo "  export PATH=\"${BIN_DIR}:\$PATH\""
    echo ""
fi

echo "Run 'craft doctor' to verify your setup."
