# 🔍 Dexxer

**Fast local file search for macOS with OCR, full-text search, and deep system integration.**

> Made this because I can't find shit in macOS. Finder's search is slow and useless. This actually works.

[![macOS](https://img.shields.io/badge/macOS-13.0+-blue.svg)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9+-orange.svg)](https://swift.org)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

---

## ✨ Features

### 🚀 **Lightning-Fast Search**
- **FTS5 Full-Text Search** - 10-100x faster than standard LIKE queries
- Search 100,000+ files in milliseconds
- Advanced search syntax: `type:pdf size:>10MB modified:today path:Legal`

### 👁️ **OCR Text Extraction**
- Extract text from images (JPG, PNG, HEIC, etc.)
- Search inside scanned PDFs
- Apple Vision framework (on-device, private)
- Find screenshots by their content

### 🎨 **Native macOS Integration**
- **URL Scheme**: `dexxer://search?q=invoice`
- **Share Extension**: Right-click → Share → Add to Dexxer
- **Finder Sync**: Badges on indexed files, context menu actions
- **Toolbar Integration**: Dexxer icon in Finder windows

### 🔎 **Advanced Search Filters**
```
type:pdf size:>5MB modified:today path:Legal contract
```

**Supported filters:**
- `type:` or `ext:` - File extension (pdf, jpg, docx, etc.)
- `size:` - File size (>10MB, <1GB, 5MB-50MB)
- `modified:` - Date (today, yesterday, 7d, thismonth, >2024-01-01)
- `path:` or `folder:` - Folder path
- `"exact phrase"` - Exact phrase matching

---

## 📥 Installation

### Requirements
- macOS 13.0 or later
- Xcode 15.0+ (for building)

### Build from Source

```bash
# Clone the repo
git clone https://github.com/YOUR_USERNAME/dexxer.git
cd dexxer

# Open in Xcode
open Dexxer.xcodeproj

# Build and run (⌘R)
```

### Setup Extensions

After building:

1. **Enable Finder Extension**:
   - System Settings → Privacy & Security → Extensions → Finder
   - Enable "Dexxer"

2. **Grant Permissions** (if needed):
   - Full Disk Access (for indexing protected folders)

---

## 🎯 Quick Start

### 1. **Add Folders to Index**
```
Settings → Indexed Folders → Add Folder
```

### 2. **Search Your Files**
```
Search bar: invoice type:pdf modified:thismonth
```

### 3. **Enable OCR** (Optional)
```
Settings → OCR → Enable "Extract text from images and PDFs"
```

---

## 🔗 URL Scheme

Trigger Dexxer from anywhere:

```bash
# Search
open "dexxer://search?q=contract"

# Index a folder
open "dexxer://index?path=/Users/you/Documents"

# Just open Dexxer
open "dexxer://open"
```

**Use cases:**
- Alfred/Raycast workflows
- Terminal scripts
- Keyboard Maestro
- Shortcuts app

---

## 🎨 Finder Integration

### Right-Click Context Menu
- **Search in Dexxer** - Search for selected file
- **Show File Info** - Display index status
- **Index This Folder** - Add folder to index

### Badge Overlays
- ✓ checkmark on indexed files
- Visual feedback in Finder

### Toolbar Button
- Quick access to Dexxer
- Appears in monitored folders

---

## 📖 Documentation

- [FTS5 Setup Guide](FTS5_SETUP_GUIDE.md) - Full-text search configuration
- [OCR Feature Guide](OCR_FEATURE_GUIDE.md) - Text extraction from images
- [URL Scheme Guide](URL_SCHEME_GUIDE.md) - Automation and integration
- [Finder Sync Guide](FINDER_SYNC_GUIDE.md) - Badges and context menus
- [System Integration](SYSTEM_INTEGRATION_SUMMARY.md) - Complete overview

---

## 🏗️ Architecture

### Core Components

- **FileIndexer** - SQLite database with FTS5 virtual table
- **SearchQueryParser** - Advanced search syntax parser
- **OCR Engine** - Apple Vision framework integration
- **Extensions** - Share and Finder Sync for system integration

### Database Schema

```sql
CREATE TABLE files (
    id INTEGER PRIMARY KEY,
    path TEXT UNIQUE,
    name TEXT,
    extension TEXT,
    size INTEGER,
    modified_time TEXT,
    indexed_time TEXT,
    folder_root TEXT,
    ocr_text TEXT
);

CREATE VIRTUAL TABLE files_fts USING fts5(
    name,
    path,
    ocr_text,
    content='files',
    content_rowid='id'
);
```

---

## 🚀 Performance

| Database Size | Search Time | Indexing Speed |
|--------------|-------------|----------------|
| 1,000 files  | < 10ms      | ~1 min         |
| 10,000 files | < 20ms      | ~10 min        |
| 100,000 files| < 50ms      | ~2 hours       |

**With OCR enabled:**
- Indexing: ~5x slower (still worth it!)
- Searching: No impact (text pre-extracted)

---

## 🛠️ Development

### Project Structure

```
Dexxer/
├── DexxerApp.swift           # Main app entry point
├── MainView.swift            # Main UI
├── FileIndexer.swift         # Core indexing & search
├── ShareExtension.swift      # Share extension
├── FinderSync.swift          # Finder Sync extension
├── SearchQueryParser         # Advanced syntax parser
└── Assets.xcassets          # Icons and badges
```

### Building Extensions

The project includes 3 targets:
1. **Dexxer** (main app)
2. **Dexxer Share Extension**
3. **Dexxer Finder Sync**

All must be built together and properly code-signed.

---

## 🤝 Contributing

Contributions welcome! Please:
1. Fork the repo
2. Create a feature branch
3. Make your changes
4. Submit a pull request

---

## 📝 License

MIT License - See [LICENSE](LICENSE) file

---

## 🙏 Acknowledgments

- **SQLite** - For FTS5 full-text search
- **Apple Vision** - For OCR capabilities
- **Matt Grilli** - Creator

---

## 🐛 Issues & Support

Found a bug? Have a feature request?
- [Open an issue](https://github.com/YOUR_USERNAME/dexxer/issues)
- Check [existing issues](https://github.com/YOUR_USERNAME/dexxer/issues) first

---

## 🎯 Roadmap

- [ ] Quick Look plugin
- [ ] Spotlight importer
- [ ] Cloud sync support
- [ ] iOS companion app
- [ ] Tag support
- [ ] Smart folders
- [ ] Saved searches

---

## ⚡ Why Dexxer?

**Finder's search sucks. Here's why Dexxer is better:**

| Feature | Finder | Dexxer |
|---------|--------|--------|
| **Speed** | Slow (spotlight rebuild) | Instant (FTS5) |
| **OCR** | No | Yes |
| **Syntax** | Basic | Advanced |
| **Automation** | Limited | URL schemes |
| **Extensions** | No | Share + Finder Sync |
| **Privacy** | Spotlight index | Local database |
| **File size filters** | No | Yes |
| **Date ranges** | Basic | Powerful |

---

**Built with Swift, SQLite, and determination.** 🚀

**No BS, just results.** 💪
