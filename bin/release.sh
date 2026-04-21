#!/usr/bin/env bash
set -euo pipefail

# release.sh — Tag a release and update the Homebrew formula
#
# Usage: ./bin/release.sh [version]
#   If version is omitted, reads from VERSION file.
#
# Prerequisites:
#   - gh CLI authenticated
#   - Clean working tree
#   - On main branch

CRAFT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-$(cat "$CRAFT_ROOT/VERSION")}"
VERSION="${VERSION#v}"  # strip leading v if present
TAG="v${VERSION}"

echo "Releasing craft ${TAG}"
echo ""

# Sanity checks
if [[ -n "$(git -C "$CRAFT_ROOT" status --porcelain)" ]]; then
    echo "Error: working tree is not clean. Commit or stash changes first."
    exit 1
fi

BRANCH="$(git -C "$CRAFT_ROOT" branch --show-current)"
if [[ "$BRANCH" != "main" ]]; then
    echo "Error: not on main branch (on $BRANCH). Switch to main first."
    exit 1
fi

# Update VERSION file if needed
echo "$VERSION" > "$CRAFT_ROOT/VERSION"

# Tag and push
echo "Tagging ${TAG}..."
git -C "$CRAFT_ROOT" tag -a "$TAG" -m "Release ${TAG}"
git -C "$CRAFT_ROOT" push origin main --tags

# Create GitHub release
echo "Creating GitHub release..."
gh release create "$TAG" \
    --repo stlasalle/craft \
    --title "craft ${TAG}" \
    --generate-notes

# Get the tarball SHA256
echo ""
echo "Fetching tarball SHA256..."
TARBALL_URL="https://github.com/stlasalle/craft/archive/refs/tags/${TAG}.tar.gz"
SHA256=$(curl -sL "$TARBALL_URL" | shasum -a 256 | cut -d' ' -f1)

echo ""
echo "Done! Update your Homebrew formula with:"
echo ""
echo "  url  \"${TARBALL_URL}\""
echo "  sha256 \"${SHA256}\""
echo ""

# Auto-update the formula in this repo
FORMULA="$CRAFT_ROOT/homebrew/craft.rb"
if [[ -f "$FORMULA" ]]; then
    # Portable sed -i
    if sed --version 2>/dev/null | grep -q GNU; then
        sed -i "s|url \".*\"|url \"${TARBALL_URL}\"|" "$FORMULA"
        sed -i "s|sha256 \".*\"|sha256 \"${SHA256}\"|" "$FORMULA"
    else
        sed -i "" "s|url \".*\"|url \"${TARBALL_URL}\"|" "$FORMULA"
        sed -i "" "s|sha256 \".*\"|sha256 \"${SHA256}\"|" "$FORMULA"
    fi
    echo "Updated homebrew/craft.rb with new URL and SHA256."

    # Push the formula to the homebrew-craft tap repo
    TAP_DIR="$(brew --repo stlasalle/craft 2>/dev/null)" || true
    if [[ -d "$TAP_DIR/Formula" ]]; then
        cp "$FORMULA" "$TAP_DIR/Formula/craft.rb"
        git -C "$TAP_DIR" add Formula/craft.rb
        git -C "$TAP_DIR" commit -m "Update formula to ${TAG}"
        git -C "$TAP_DIR" push origin main
        echo "Pushed formula update to homebrew-craft tap."
    else
        echo "Warning: homebrew-craft tap not found. Manually copy the formula to your tap repo."
    fi
fi
