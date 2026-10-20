# Changelog

All notable changes to Dexxer will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.1.0] - 2025-03-05

### ✨ Added

#### 🔍 Search Enhancements
- **FTS5 Full-Text Search** - 10-100x faster than standard LIKE queries
- **Advanced Search Syntax** with filters:
  - `type:pdf` - Filter by file extension
  - `size:>10MB` - Filter by file size
  - `modified:today` - Filter by modification date
  - `path:Legal` - Filter by folder path
  - `"exact phrase"` - Exact phrase matching
- **Search Query Parser** - Parses natural language queries into structured filters
- Search syntax help guide (click ? button in search bar)

#### 👁️ OCR Integration
- **OCR text extraction** using Apple Vision framework
- Extract text from images (JPG, PNG, HEIC, TIFF, BMP, GIF)
- Extract text from scanned PDFs
- Search inside screenshots and photos
- Toggle OCR on/off in Settings
- Automatic file size limit (20MB) for performance

#### 🔗 System Integration
- **URL Scheme** (`dexxer://`) for automation:
  - `dexxer://search?q=...` - Trigger searches
  - `dexxer://index?path=...` - Index folders
  - `dexxer://open` - Open main window
- **Share Extension** - Right-click → Share → Add to Dexxer
- **Finder Sync Extension**:
  - Badge overlays (✓ checkmark) on indexed files
  - Context menu actions (Search, Info, Index)
  - Toolbar button in Finder windows
  - Visual feedback in Finder

#### 🛠️ UI Improvements
- Settings section for FTS5 management
- Settings section for OCR configuration
- Rebuild FTS5 Index button
- Optimize FTS5 Index button
- Better search result display
- Status bar with result count
- Preview pane toggle button

#### 📚 Documentation
- Complete FTS5 setup guide
- OCR feature guide with examples
- URL scheme integration guide
- Finder Sync setup guide
- System integration summary
- Example workflows and use cases

### 🔧 Changed
- Database schema updated with `ocr_text` column
- FTS5 virtual table includes OCR text
- Improved indexing performance
- Better memory management during indexing
- Enhanced search result sorting

### 🐛 Fixed
- Preview pane layout issues
- Sidebar overlap at default window size
- Navigation split view button behavior
- Search results scrolling
- Preview toggle button crash prevention

### 🏗️ Technical
- SQLite FTS5 virtual table implementation
- Apple Vision framework integration
- App Groups for extension communication
- Distributed notifications for IPC
- URL event handling
- Finder Sync protocol implementation

---

## [1.0.0] - 2025-01-XX

### ✨ Added
- Initial release
- Basic file indexing
- Simple text search
- Menu bar app
- Settings panel
- Add/remove folders
- Search results view
- File preview
- Quick Look integration

### 🔧 Features
- SQLite database backend
- File metadata indexing (name, path, size, date)
- Basic search with LIKE queries
- Folder monitoring
- Exclude patterns
- Statistics display

---

## [Unreleased]

### 🚀 Planned Features
- Quick Look plugin with OCR text display
- Spotlight importer integration
- Smart folders and saved searches
- Tag support
- Cloud sync (iCloud Drive)
- iOS companion app
- Advanced filters UI
- Search history
- Keyboard shortcuts customization

### 🐛 Known Issues
- Large image files (>20MB) skipped in OCR
- Finder Sync badges may take time to update
- Extension requires manual enable in System Settings

---

## Version History

- **1.1.0** - Major update with OCR, FTS5, and system integration
- **1.0.0** - Initial release with basic indexing and search

---

**Legend:**
- ✨ Added - New features
- 🔧 Changed - Changes to existing functionality
- 🐛 Fixed - Bug fixes
- 🗑️ Removed - Removed features
- 🔒 Security - Security improvements
- 📚 Documentation - Documentation changes
