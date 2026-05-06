#!/bin/bash
set -euo pipefail

# Sealed Public Release Script
# Creates a sanitized public mirror by stripping secrets and internal files
# Usage: ./scripts/release_public.sh [--dry-run] [--remote REMOTE_URL]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
PUBLIC_DIR="/tmp/sealed-public-$(date +%s)"
DRY_RUN=false
REMOTE_URL=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --remote)
            REMOTE_URL="$2"
            shift 2
            ;;
        *)
            echo "Usage: $0 [--dry-run] [--remote REMOTE_URL]"
            echo "  --dry-run    Don't push, just create sanitized tree"
            echo "  --remote     Git remote URL for public repo"
            exit 1
            ;;
    esac
done

echo "🔒 Sealed Public Release Script"
echo "================================"
echo "Source: $REPO_ROOT"
echo "Target: $PUBLIC_DIR"
echo "Dry run: $DRY_RUN"
echo ""

# Verify clean working tree
cd "$REPO_ROOT"
if [[ -n "$(git status --porcelain)" ]]; then
    echo "❌ Working tree is not clean. Commit or stash changes first."
    git status --short
    exit 1
fi

echo "✅ Working tree is clean"

# Verify we're on main branch
CURRENT_BRANCH=$(git branch --show-current)
if [[ "$CURRENT_BRANCH" != "main" ]]; then
    echo "⚠️  Warning: Not on main branch (currently on $CURRENT_BRANCH)"
    read -p "Continue anyway? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Create clean export directory
echo "📁 Creating clean export at $PUBLIC_DIR"
mkdir -p "$PUBLIC_DIR"

# Export tracked files (excludes .git history)
echo "📦 Exporting tracked files..."
git archive HEAD | tar -x -C "$PUBLIC_DIR"

cd "$PUBLIC_DIR"

# Sanitization sweep
echo "🧹 Sanitizing sensitive content..."

# Remove internal/sensitive directories wholesale
SECRET_DIRS=(
    "internal"
    "sealed_app/design-handoff"
    "sealed-indexer/apns_keys"   # APNs signing keys (.p8) — NEVER publish
    ".windsurf"
    ".idea"
    ".vscode"
)

for dir in "${SECRET_DIRS[@]}"; do
    if [[ -d "$dir" ]]; then
        echo "  🗑️  Removing dir $dir/"
        rm -rf "$dir"
    fi
done

# Remove secret files
SECRET_FILES=(
    "pi_key"
    "pi_key.pub"
    "setup_onion_dev.sh"
    "sealed_app/android/upload-keystore.jks"
    "sealed_app/android/app/google-services.json"
    "sealed_app/ios/Runner/GoogleService-Info.plist"
    "sealed_app/lib/firebase_options.dart"
    "sealed_app/android/key.properties"
    ".mcp.json"
    "sealed-indexer/admin-account.json"   # FCM service-account JSON
    "sealed-indexer/indexer.db"           # local SQLite cache, may contain real round/token data
    "sealed-indexer/.env"
    "sealed_app/.env"
    # Real docker-compose.yml has hostnames/IPs/IDs. Ship .example only.
    "sealed-indexer/docker/docker-compose.yml"
)

# Strip cosmetic junk that has no business in a public mirror
echo "  🧽 Removing .DS_Store, *.log, and editor cruft..."
find . -name ".DS_Store" -delete 2>/dev/null || true
find . -name "*.log" -delete 2>/dev/null || true
find . -name "*.iml" -delete 2>/dev/null || true

for file in "${SECRET_FILES[@]}"; do
    if [[ -f "$file" ]]; then
        echo "  🗑️  Removing $file"
        rm -f "$file"
    fi
done

# Remove development scripts that shouldn't be public
DEV_SCRIPTS=(
    "sealed_app/test_send_message.sh"
)

for script in "${DEV_SCRIPTS[@]}"; do
    if [[ -f "$script" ]]; then
        echo "  🗑️  Removing dev script $script"
        rm -f "$script"
    fi
done

# Verify example files exist
EXAMPLE_FILES=(
    "sealed_app/android/app/google-services.json.example"
    "sealed_app/ios/Runner/GoogleService-Info.plist.example"
    "sealed-indexer/.env.example"
    "sealed-indexer/docker/docker-compose.yml.example"
)

for example in "${EXAMPLE_FILES[@]}"; do
    if [[ ! -f "$example" ]]; then
        echo "⚠️  Warning: Example file missing: $example"
    else
        echo "  ✅ Example file present: $example"
    fi
done

# Secret scan with gitleaks (if available)
echo "🔍 Running secret scan..."
if command -v gitleaks &> /dev/null; then
    if gitleaks detect --source . --no-git --quiet; then
        echo "  ✅ No secrets detected"
    else
        echo "  ❌ Secrets detected! Review and fix before proceeding."
        echo "  Run 'gitleaks detect --source $PUBLIC_DIR --no-git' for details"
        exit 1
    fi
else
    echo "  ⚠️  gitleaks not installed, skipping secret scan"
    echo "  Install with: brew install gitleaks"
fi

# Verify critical files are present
REQUIRED_FILES=(
    "README.md"
    "LICENSE"
    "SECURITY.md"
    "CONTRIBUTING.md"
    "sealed_app/pubspec.yaml"
    "sealed_app/lib/main.dart"
)

echo "📋 Verifying required files..."
for file in "${REQUIRED_FILES[@]}"; do
    if [[ ! -f "$file" ]]; then
        echo "  ❌ Required file missing: $file"
        exit 1
    else
        echo "  ✅ $file"
    fi
done

# Quick verification that secrets were actually removed
echo "🔍 Double-checking secret removal..."
SECRET_PATTERNS=(
    "pi_key"
    "upload-keystore.jks"
    "google-services.json"
    "GoogleService-Info.plist"
    "admin-account.json"
    ".p8"
    "docker-compose"
    "indexer.db"
)

for pattern in "${SECRET_PATTERNS[@]}"; do
    # Allow *.example variants through (they're safe placeholders).
    if find . -name "*$pattern*" -not -name "*.example" -not -name "*.example.*" | grep -q .; then
        echo "  ❌ Secret pattern still found: $pattern"
        find . -name "*$pattern*" -not -name "*.example" -not -name "*.example.*"
        exit 1
    fi
done

echo "  ✅ All targeted secrets removed"

# Initialize git repo
echo "📝 Initializing public repository..."
git init
git add .

# Create initial commit
COMMIT_MSG="Initial public release

Sanitized release from private development repository.
All secrets, internal documentation, and development
artifacts have been removed.

For development setup, see CONTRIBUTING.md
For security information, see SECURITY.md"

git commit -m "$COMMIT_MSG"

# Show summary
echo ""
echo "📊 Release Summary"
echo "=================="
echo "Public repo: $PUBLIC_DIR"
echo "Files included: $(find . -type f | wc -l | tr -d ' ')"
echo "Git commit: $(git rev-parse --short HEAD)"
echo ""

if [[ "$DRY_RUN" == "true" ]]; then
    echo "🏁 DRY RUN COMPLETE"
    echo "   Review the sanitized tree at: $PUBLIC_DIR"
    echo "   When ready, run without --dry-run to push to remote"
    exit 0
fi

# Push to remote (if specified)
if [[ -n "$REMOTE_URL" ]]; then
    echo "🚀 Pushing to public remote: $REMOTE_URL"
    git remote add origin "$REMOTE_URL"

    # Create main branch and push
    git branch -M main

    echo "   Pushing to remote..."
    git push -u origin main --force

    echo "✅ Successfully published to $REMOTE_URL"
else
    echo "📋 No remote specified. To push manually:"
    echo "   cd $PUBLIC_DIR"
    echo "   git remote add origin YOUR_PUBLIC_REPO_URL"
    echo "   git push -u origin main --force"
fi

echo ""
echo "🎉 Public release complete!"
echo "   Local copy: $PUBLIC_DIR"
if [[ -n "$REMOTE_URL" ]]; then
    echo "   Public repo: $REMOTE_URL"
fi