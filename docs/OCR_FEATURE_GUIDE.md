# 🔍 OCR (Optical Character Recognition) Feature Guide

## What is OCR?

OCR extracts text from images and scanned PDFs, making that text **searchable**. Now you can search for text **inside** screenshots, photos, and scanned documents!

---

## 🚀 How to Enable OCR

1. Open **Dexxer**
2. Go to **Settings** (gear icon in sidebar)
3. Scroll to **"OCR (Optical Character Recognition)"** section
4. Toggle **"Extract text from images and PDFs"** to **ON**
5. **Re-index your folders** to extract OCR text from existing files

---

## 📁 Supported File Types

OCR works on:
- **Images**: `.jpg`, `.jpeg`, `.png`, `.heic`, `.heif`, `.tiff`, `.tif`, `.bmp`, `.gif`
- **PDFs**: Scanned PDF documents (not native text PDFs)

---

## 🔎 How to Search OCR Content

Just search normally! OCR text is automatically included in your searches.

### Examples:

**Search for text in screenshots:**
```
type:png invoice 2024
```
Finds PNG images containing "invoice 2024" in the image.

**Search for text in photos:**
```
type:jpg receipt starbucks
```
Finds JPEG photos with "receipt" and "starbucks" visible in the image.

**Search scanned documents:**
```
type:pdf "contract agreement" modified:thismonth
```
Finds PDF files with "contract agreement" text (OCR'ed or native).

---

## ⚠️ Performance Considerations

### Indexing Speed
- **Without OCR**: ~1000 files/minute
- **With OCR**: ~100-300 files/minute (depending on image size)

OCR is **much slower** because it analyzes each image. For 1000 images, expect:
- Without OCR: 1 minute
- With OCR: 3-10 minutes

### File Size Limits
- Files larger than **20MB** are skipped (too slow to process)
- Best for screenshots, photos, and normal-sized documents

### Search Speed
- **No impact** on search speed! OCR text is pre-extracted during indexing.
- Searches stay blazing fast with FTS5.

---

## 🎯 Best Use Cases

### ✅ Perfect For:
1. **Screenshots** - Search text in your screenshots library
2. **Photos of documents** - Find receipts, business cards, notes
3. **Scanned PDFs** - Make old scanned documents searchable
4. **Memes with text** - Find that meme you saved months ago
5. **Diagrams/Charts** - Search for labels and annotations

### ❌ Not Ideal For:
1. **Native PDFs** - Already have searchable text (no OCR needed)
2. **Word docs** - Already searchable
3. **Very large images** (>20MB) - Skipped automatically
4. **Low quality images** - OCR accuracy decreases

---

## 🧪 How Apple Vision OCR Works

### Technology
- Uses **Apple Vision framework** (built into macOS)
- **On-device processing** - completely private, no cloud
- Supports **20+ languages** automatically
- **Highly accurate** - uses ML models trained by Apple

### What It Extracts
- All visible text in images
- Handwriting (with varying accuracy)
- Text at any angle or orientation
- Multi-column layouts

### Accuracy
- **Printed text**: 95-99% accurate
- **Clear handwriting**: 80-90% accurate
- **Messy handwriting**: 50-70% accurate
- **Small text**: May be missed

---

## 💡 Tips & Tricks

### 1. **Enable OCR Before Indexing**
Turn on OCR **before** you index folders for the first time. Otherwise, you'll need to re-index.

### 2. **Re-Index to Extract OCR**
Already indexed? Re-index your folders to extract OCR text:
- Settings → Indexed Folders → Click re-index button

### 3. **Check Database Size**
OCR text increases database size:
- **Without OCR**: ~50KB per 1000 files
- **With OCR**: ~500KB-2MB per 1000 files

### 4. **Selective Indexing**
If indexing is too slow, consider:
- Disabling OCR for folders with mostly native PDFs
- Only enabling OCR when indexing image-heavy folders

### 5. **Use Specific File Type Filters**
When searching OCR content, narrow by file type:
```
type:jpg "receipt total"
```
Faster than searching all file types.

---

## 📊 Example Workflows

### Workflow 1: Find Receipt Screenshots
```
type:png receipt modified:thismonth
```
Finds receipt screenshots from this month.

### Workflow 2: Search All Business Cards
```
type:jpg email modified:thisyear
```
Finds photos of business cards with email addresses.

### Workflow 3: Find Presentation Screenshots
```
type:png "slide presentation" size:>1MB
```
Finds large PNG screenshots from presentations.

### Workflow 4: Search Scanned Documents
```
type:pdf "john smith" modified:>2024-01-01
```
Finds scanned PDFs mentioning "john smith" from 2024.

---

## 🐛 Troubleshooting

### OCR Not Working?

**1. Check if OCR is enabled:**
- Settings → OCR → Toggle should be ON

**2. Re-index your folders:**
- Existing files need to be re-indexed to extract OCR text
- Settings → Indexed Folders → Re-index button

**3. Check file size:**
- Files > 20MB are skipped
- Check file size: Settings → Database

**4. Verify file type:**
- Only images and PDFs are supported
- Check file extension

### No Results When Searching?

**1. Verify text is visible in image:**
- Open the image manually
- Make sure text is clear and readable

**2. Try broader search terms:**
- OCR might have slight errors
- Try searching parts of words

**3. Check FTS5 index:**
- Settings → Full-Text Search → Rebuild FTS5 Index

---

## 🔐 Privacy

- **100% on-device** - no data leaves your Mac
- Uses Apple Vision framework (built into macOS)
- No internet connection required
- OCR text stored locally in SQLite database
- Same privacy as rest of Dexxer (all local)

---

## ⚙️ Technical Details

### Database Schema
```sql
CREATE TABLE files (
    id INTEGER PRIMARY KEY,
    path TEXT,
    name TEXT,
    extension TEXT,
    size INTEGER,
    modified_time TEXT,
    indexed_time TEXT,
    folder_root TEXT,
    ocr_text TEXT  -- New column for OCR
);
```

### FTS5 Index
```sql
CREATE VIRTUAL TABLE files_fts USING fts5(
    name,
    path,
    ocr_text,  -- Searchable OCR text
    content='files',
    content_rowid='id'
);
```

### Vision Framework
```swift
import Vision

let request = VNRecognizeTextRequest { request, error in
    // Extract recognized text
}
request.recognitionLevel = .accurate
request.usesLanguageCorrection = true
```

---

## 📈 Performance Stats

| Files | Without OCR | With OCR | Difference |
|-------|-------------|----------|------------|
| 100   | 6 seconds   | 30 sec   | 5x slower  |
| 1,000 | 1 minute    | 5 min    | 5x slower  |
| 10,000| 10 minutes  | 50 min   | 5x slower  |

*Note: Times vary based on image sizes and system performance*

---

## 🎓 Summary

**Enable OCR if you:**
- Have lots of screenshots
- Scan documents regularly
- Take photos of receipts/documents
- Want to search text in images

**Skip OCR if you:**
- Only index native text files (PDFs, Word docs)
- Need fast indexing
- Have limited disk space
- Don't search image content

---

**Happy OCR searching! 🔍📷**
