# Info.plist Configuration

## Add URL Scheme Support

Add this to your main app's `Info.plist` (inside the main `<dict>`):

```xml
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleURLName</key>
        <string>com.mattgrilli.dexxer</string>
        <key>CFBundleURLSchemes</key>
        <array>
            <string>dexxer</string>
        </array>
    </dict>
</array>
```

This registers `dexxer://` as a URL scheme that your app can handle.

## Xcode Project Setup

### 1. Add to Info Tab
In Xcode:
1. Select your **Dexxer** target
2. Go to the **Info** tab
3. Under **URL Types**, click **+**
4. Set:
   - **Identifier**: `com.mattgrilli.dexxer`
   - **URL Schemes**: `dexxer`
   - **Role**: Editor

### 2. Test URL Scheme
After building, test in Terminal:
```bash
open "dexxer://search?q=test"
```

---

## Share Extension Setup

### 1. Add New Target
1. **File → New → Target**
2. Choose **macOS → Share Extension**
3. Name: **Dexxer Share Extension**
4. Bundle Identifier: `com.mattgrilli.Dexxer.ShareExtension`

### 2. Add Files
Copy these files to the Share Extension target:
- `ShareExtension.swift` (Principal class)
- `ShareExtension-Info.plist` (Configuration)

### 3. Configure Build Settings
- **Deployment Target**: Same as main app (macOS 13.0+)
- **Code Signing**: Same team/certificate as main app
- **Embed in Main App**: Yes (should be automatic)

### 4. Link Frameworks
If needed, link:
- AppKit.framework
- Foundation.framework

---

## Verification

### Check URL Scheme Registration
```bash
# After building and running once:
defaults read ~/Library/Preferences/com.apple.LaunchServices/com.apple.launchservices.secure.plist | grep dexxer
```

### Check Share Extension
1. **Right-click any file** in Finder
2. Look for **Share → Add to Dexxer**
3. If not visible:
   - System Settings → Privacy & Security → Extensions → Finder
   - Enable "Dexxer Share Extension"

---

## Troubleshooting

### URL Scheme Not Working
```bash
# Reset Launch Services
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -kill -r -domain local -domain system -domain user

# Rebuild app
# Run again
```

### Share Extension Not Appearing
```bash
# Clear plugin cache
pluginkit -m -v

# Re-register extension
pluginkit -a /path/to/Dexxer.app

# Restart Finder
killall Finder
```

---

## Testing Checklist

- [ ] URL scheme appears in Info.plist
- [ ] `open "dexxer://search?q=test"` opens Dexxer
- [ ] `open "dexxer://open"` opens main window
- [ ] Share Extension shows in Finder's Share menu
- [ ] Can share single file to Dexxer
- [ ] Can share multiple files to Dexxer
- [ ] Extension shows confirmation dialog
- [ ] Extension triggers indexing
