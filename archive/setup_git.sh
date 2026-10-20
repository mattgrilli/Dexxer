#!/bin/bash
# Git Setup Script for Dexxer

echo "🚀 Setting up Git repository for Dexxer..."

# Check if already a git repo
if [ -d .git ]; then
    echo "⚠️  Git repository already exists!"
    read -p "Do you want to continue? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
else
    # Initialize git
    echo "📦 Initializing Git repository..."
    git init
fi

# Configure git (if not already set)
if [ -z "$(git config user.name)" ]; then
    echo "🔧 Configuring Git..."
    read -p "Enter your name: " git_name
    read -p "Enter your email: " git_email
    git config user.name "$git_name"
    git config user.email "$git_email"
fi

# Add all files
echo "📝 Adding files..."
git add .

# Check what's being committed
echo ""
echo "📋 Files to be committed:"
git status --short

echo ""
read -p "Continue with commit? (y/n) " -n 1 -r
echo

if [[ $REPLY =~ ^[Yy]$ ]]; then
    # Commit
    echo "💾 Creating initial commit..."
    git commit -m "Initial commit - Dexxer v1.1.0

Features:
- FTS5 full-text search (10-100x faster)
- OCR text extraction from images and PDFs
- Advanced search syntax (type:, size:, modified:, path:)
- URL scheme support (dexxer://)
- Share Extension (right-click → Share → Add to Dexxer)
- Finder Sync Extension (badges, context menu, toolbar)
- Native macOS integration"

    echo ""
    echo "✅ Initial commit created!"
    echo ""
    echo "📤 Next steps:"
    echo ""
    echo "1. Create a GitHub repository:"
    echo "   https://github.com/new"
    echo ""
    echo "2. Add remote and push:"
    echo "   git remote add origin https://github.com/YOUR_USERNAME/dexxer.git"
    echo "   git branch -M main"
    echo "   git push -u origin main"
    echo ""
    echo "Or use GitHub CLI:"
    echo "   gh repo create dexxer --public --source=. --push"
    echo ""
else
    echo "❌ Commit cancelled"
    exit 1
fi

echo ""
echo "🎉 Git setup complete!"
