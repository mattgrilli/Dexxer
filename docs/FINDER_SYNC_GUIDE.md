# 🔍 Finder Sync Extension Setup Guide

## Overview

The **Finder Sync Extension** adds visual integration directly into Finder:
- **Badge overlays** on indexed files (✓ checkmark)
- **Context menu items** - Right-click → "Search in Dexxer"  
- **Toolbar button** - Dexxer icon in Finder toolbar
- **Visual feedback** showing which files are indexed

---

## 🎯 Features

### 1. Badge Overlays
Indexed files show a **✓ checkmark badge** in Finder:
- Quick visual confirmation files are indexed
- Works in List, Icon, and Column views
- Updates automatically when folders are indexed

### 2. Context Menu
Right-click files or folders:
- **Search in Dexxer** - Opens Dexxer and searches for the file
- **Show File Info** - Displays index status
- **Index This Folder** - Add folder to Dexxer index

### 3. Toolbar Button
Dexxer icon appears in Finder toolbar:
- Click to open Dexxer
- Quick access to search and index functions
- Shows in all Finder windows monitoring indexed folders

---

## 🛠️ Xcode Setup

### Step 1: Create Extension Target

1. **File → New → Target**
2. Choose **macOS → Finder Sync Extension**
3. **Product Name**: `Dexxer Finder Sync`
4. **Bundle Identifier**: `com.mattgrilli.Dexxer.FinderSync`
5. Click **Finish**

### Step 2: Add Files to Target

1. Add `FinderSync.swift` to the extension target
2. Replace default `FinderSync` class with provided code
3. Use `FinderSync-Info.plist` for configuration

### Step 3: Configure App Groups

Both the main app and extension need to share data.

**In Main App Target:**
1. Select **Dexxer** target
2. Go to **Signing & Capabilities**
3. Click **+ Capability** → **App Groups**
4. Add: `group.com.mattgrilli.dexxer`

**In Finder Sync Target:**
1. Select **Dexxer Finder Sync** target
2. Go to **Signing & Capabilities**
3. Click **+ Capability** → **App Groups**
4. Add: `group.com.mattgrilli.dexxer` (same as above)

### Step 4: Add Badge Assets

Create badge images for Finder overlays:

1. In Finder Sync target, create **Assets.xcassets**
2. Add new **Image Set** named `indexed`
3. Add checkmark icon images:
   - **1x**: 16x16px PNG with ✓ checkmark
   - **2x**: 32x32px PNG with ✓ checkmark
   - **3x**: 48x48px PNG with ✓ checkmark

**Badge Requirements:**
- **Format**: PNG with transparency
- **Size**: 16x16pt (32x32px @2x)
- **Style**: Simple, clear icon
- **Color**: Blue or green checkmark

### Step 5: Code Signing

Both targets must be signed with the same certificate:

1. Select **Dexxer Finder Sync** target
2. **Signing & Capabilities**
3. **Team**: Select your Apple Developer team
4. **Automatically manage signing**: ✓ Enabled

### Step 6: Embed Extension

1. Select **Dexxer** (main app) target
2. Go to **General** tab
3. Under **Frameworks, Libraries, and Embedded Content**
4. Ensure `Dexxer Finder Sync.appex` is listed and set to **Embed**

---

## 🚀 Build & Run

### Build the App

```bash
# In Xcode
Product → Build (⌘B)
```

### Run and Install

1. **Product → Run** (⌘R)
2. Dexxer launches
3. Extension is automatically installed

### Enable Extension

**macOS will prompt:**
"Dexxer wants to add a Finder extension"
- Click **Open System Settings**
- Or go manually: **System Settings → Privacy & Security → Extensions → Finder**

**Enable the extension:**
- Find "Dexxer" in the list
- Toggle it **ON**

---

## ✅ Verification

### Test Badge Overlays

1. Index a folder in Dexxer
2. Open that folder in Finder
3. Files should show **✓ badge**

If badges don't appear:
- Wait 10 seconds (can be slow to update)
- Switch view mode (List → Icon → Column)
- Restart Finder: `killall Finder`

### Test Context Menu

1. **Right-click** any indexed file
2. Look for **"Search in Dexxer"**
3. Click it → Dexxer opens and searches

### Test Toolbar Button

1. Open Finder window in an indexed folder
2. Look for **Dexxer icon** in toolbar (magnifying glass)
3. Click it for quick actions menu

---

## 🐛 Troubleshooting

### Extension Not Appearing

**1. Check if extension is installed:**
```bash
# List all FinderSync extensions
pluginkit -m -v | grep Dexxer
```

**2. Force reload extensions:**
```bash
# Kill Finder Sync daemon
killall FinderSyncExtension

# Restart Finder
killall Finder

# Re-register extension
pluginkit -a /Applications/Dexxer.app
```

**3. Check System Settings:**
- System Settings → Privacy & Security → Extensions → Finder
- Make sure "Dexxer" is **enabled**

### Badges Not Showing

**1. Check monitored folders:**
- Extension only monitors indexed folders
- Add folders in Dexxer → Settings → Add Folder

**2. Refresh Finder:**
```bash
killall Finder
```

**3. Check badge asset:**
- Ensure `indexed` image set exists in Assets
- Verify image dimensions (16x16pt)

**4. Check app group:**
- Both targets must use same app group ID
- Verify in Signing & Capabilities

### Context Menu Not Working

**1. Check extension is running:**
```bash
# See if process is running
ps aux | grep FinderSync
```

**2. Check permissions:**
- System Settings → Privacy & Security → Full Disk Access
- Add Dexxer if prompted

**3. Reinstall extension:**
- Delete `/Applications/Dexxer.app`
- Clean build folder: Product → Clean Build Folder
- Rebuild and run

### Communication Issues

**App group not working:**

```swift
// Test in both main app and extension:
if let shared = UserDefaults(suiteName: "group.com.mattgrilli.dexxer") {
    shared.set(["test"], forKey: "test")
    print("Shared: \(shared.array(forKey: "test") ?? [])")
} else {
    print("❌ App group not configured")
}
```

---

## 📊 Performance

| Operation | Time | Notes |
|-----------|------|-------|
| Badge update | 1-10s | Depends on Finder refresh rate |
| Context menu | <100ms | Instant |
| Toolbar button | <100ms | Instant |
| Monitoring setup | <1s | On folder change |

**Memory usage:**
- Extension: ~5-10MB RAM
- Badges cached by Finder
- Low CPU usage (mostly idle)

---

## 🎨 Customization

### Custom Badge Icons

Create different badges for different states:

```swift
// In FinderSync.swift
override func requestBadgeIdentifier(for url: URL) {
    if isFileIndexed(url) {
        if hasOCRText(url) {
            FIFinderSyncController.default().setBadgeIdentifier("ocr", for: url)
        } else {
            FIFinderSyncController.default().setBadgeIdentifier("indexed", for: url)
        }
    } else {
        FIFinderSyncController.default().setBadgeIdentifier("", for: url)
    }
}
```

### Additional Context Menu Items

```swift
override func menu(for menuKind: FIMenuKind) -> NSMenu? {
    let menu = NSMenu(title: "")
    
    menu.addItem(withTitle: "Search in Dexxer", action: #selector(searchInDexxer(_:)), keyEquivalent: "")
    menu.addItem(withTitle: "Show OCR Text", action: #selector(showOCR(_:)), keyEquivalent: "")
    menu.addItem(withTitle: "Re-index File", action: #selector(reindexFile(_:)), keyEquivalent: "")
    
    return menu
}
```

### Custom Toolbar Icon

Replace in `FinderSync.swift`:

```swift
override var toolbarItemImage: NSImage {
    // Use custom icon from Assets
    return NSImage(named: "DexxerToolbarIcon")!
    
    // Or SF Symbol:
    return NSImage(systemSymbolName: "doc.text.magnifyingglass", accessibilityDescription: "Dexxer")!
}
```

---

## 🔒 Security & Privacy

### Permissions Required

**Extension needs:**
- **Finder Extensions** - Enable in System Settings
- **Full Disk Access** - If indexing protected folders
- **App Group** - To share data with main app

### Data Sharing

- Indexed folder list shared via **App Groups**
- No file content shared
- Extension runs in sandboxed environment
- Can only access monitored folders

### User Privacy

- No data sent to network
- All processing on-device
- Extension can be disabled anytime
- No tracking or analytics

---

## 📋 Testing Checklist

**Before Deployment:**
- [ ] Extension shows in System Settings → Extensions
- [ ] Can enable/disable extension
- [ ] Badges appear on indexed files
- [ ] Context menu items work
- [ ] Toolbar button appears
- [ ] Can search from context menu
- [ ] Can index folder from context menu
- [ ] App group communication works
- [ ] Extension survives app restart
- [ ] Extension survives system restart

---

## 🚀 Distribution

### Including Extension in Release

**When distributing:**
1. Extension is embedded in main app bundle
2. Automatically installed when app runs
3. User must manually enable in System Settings

**App Store:**
- Include both targets in submission
- Declare extension in app metadata
- Request FinderSync entitlement

**Direct Distribution:**
- Notarize both main app and extension
- Sign with Developer ID
- Include instructions to enable extension

---

## 💡 Tips & Best Practices

### 1. **Monitor Only Indexed Folders**
Don't monitor entire system - only folders user wants:
```swift
FIFinderSyncController.default().directoryURLs = indexedFolderURLs
```

### 2. **Efficient Badge Checks**
Cache indexed file paths to avoid repeated database queries.

### 3. **Update on Changes**
Listen for notifications when folders are added/removed:
```swift
DistributedNotificationCenter.default().addObserver(...)
```

### 4. **Graceful Degradation**
If app group fails, fall back to standard UserDefaults.

### 5. **Clear Communication**
Tell users they need to enable the extension manually.

---

## 📚 Additional Resources

**Apple Documentation:**
- [Finder Sync Extensions](https://developer.apple.com/documentation/findersync)
- [App Groups](https://developer.apple.com/documentation/bundleresources/entitlements/com_apple_security_application-groups)
- [System Extensions](https://developer.apple.com/system-extensions/)

**Sample Projects:**
- Search for "Finder Sync" in Apple's sample code

---

## ✅ Summary

**What You Built:**
- ✓ Badge overlays on indexed files
- ✓ Right-click context menu integration  
- ✓ Finder toolbar button
- ✓ Deep Finder integration

**What Users Get:**
- Visual feedback on indexed files
- Quick search from Finder
- Native macOS experience
- No need to open Dexxer for quick actions

**Next Steps:**
1. Add to Xcode project
2. Configure app groups
3. Build and test
4. Enable in System Settings
5. Ship it! 🚀

---

**Your files are now fully integrated with Finder! 🎉**
