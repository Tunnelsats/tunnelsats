#!/usr/bin/env bash
# --- Git Hooks Installation Script ---
# Sets up the .githooks directory for local development integrity checks.

# Set hooks path to the version-controlled directory
git config core.hooksPath .githooks

# Ensure scripts are executable
chmod +x .githooks/pre-commit
chmod +x .githooks/post-rewrite

echo "✅ Git hooks configured to use .githooks/"
echo "🛡️  Script integrity checks are now active for local development."
