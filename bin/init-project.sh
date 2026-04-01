#!/usr/bin/env bash
set -euo pipefail

# init-project.sh — Scaffold a new autopilot project instance
#
# Usage: init-project.sh <project-name>
#
# Creates a new project folder in projects/<project-name> by copying
# the templates/ structure and replacing placeholders.

AUTOPILOT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATES_DIR="$AUTOPILOT_ROOT/templates"
PROJECTS_DIR="$AUTOPILOT_ROOT/projects"

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <project-name>"
    echo "Example: $0 trust-content-mod"
    exit 1
fi

PROJECT_NAME="$1"
PROJECT_DIR="$PROJECTS_DIR/$PROJECT_NAME"

if [[ -d "$PROJECT_DIR" ]]; then
    echo "Error: Project '$PROJECT_NAME' already exists at $PROJECT_DIR"
    exit 1
fi

echo "Creating project: $PROJECT_NAME"

# Ensure projects directory exists
mkdir -p "$PROJECTS_DIR"

# Copy template structure
cp -R "$TEMPLATES_DIR" "$PROJECT_DIR"

# Create additional directories not in templates
mkdir -p "$PROJECT_DIR/docs/milestones"
mkdir -p "$PROJECT_DIR/docs/adrs"
mkdir -p "$PROJECT_DIR/docs/context"
mkdir -p "$PROJECT_DIR/repos"

# Rename .template files to their actual names and replace placeholders
DATE=$(date +%Y-%m-%d)

# Ensure autopilot.conf exists (not a .template, just a default)
if [[ ! -f "$PROJECT_DIR/autopilot.conf" ]]; then
    cp "$TEMPLATES_DIR/autopilot.conf" "$PROJECT_DIR/autopilot.conf"
fi

for template in "$PROJECT_DIR"/docs/*.template "$PROJECT_DIR"/.claude/*.template "$PROJECT_DIR"/*.template; do
    [[ -f "$template" ]] || continue
    target="${template%.template}"
    sed "s/{{PROJECT_NAME}}/$PROJECT_NAME/g; s/{{DATE}}/$DATE/g; s/{{TIMESTAMP}}/$DATE/g" "$template" > "$target"
    rm "$template"
done

echo ""
echo "Project created at: $PROJECT_DIR"
echo ""
echo "Next steps:"
echo "  1. Edit $PROJECT_DIR/docs/plan.md with your project plan"
echo "  2. Add repos:  cd $PROJECT_DIR/repos && git worktree add <path> <branch>"
echo "  3. Update $PROJECT_DIR/.claude/CLAUDE.md with repo table"
echo "  4. Run /generate-milestone to create your first milestone"
echo ""
