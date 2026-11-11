## What's new in 1.3

- **Ask about selected text:** select text in any app, right-click → Services → Ask ClaudeSniper.
- **Multi-capture:** press + in the pop-up to add another capture to the same question.
- **Capture text only (⌥⌘1):** copy the text without asking Claude. QR codes and barcodes are read too.
- **From your iPhone camera:** Import from iPhone or iPad… → take a photo or scan a document (Continuity Camera).
- **Screenshots (⌥⌘3):** area or window, with a thumbnail to copy, save, drag, copy its text, ask Claude or pin it on screen.
- **Screenshot bar and macOS shortcuts:** optionally use ⌘⇧3, ⌘⇧4 and ⌘⇧5 for ClaudeSniper's screenshots.
- **Scrolling capture (⌥⌘4):** scroll a page and get one tall screenshot.
- Option to keep or join line breaks in captured text, and to turn off copying captures to the clipboard.
- The model label in the pop-up is centered again.

## Install

1. Download **ClaudeSniper-x.y.z.zip** below and unzip it.
2. Move **ClaudeSniper.app** to your **Applications** folder.
3. Open it. The first time, macOS will say it can't check the app, because it isn't notarized by Apple:
   - Open **System Settings → Privacy & Security**, scroll down and click **Open Anyway** next to ClaudeSniper.
   - Or in Terminal: `xattr -dr com.apple.quarantine /Applications/ClaudeSniper.app`
4. The welcome guide checks that [Claude Code](https://claude.com/claude-code) is installed and signed in. Scrolling capture also asks for **Screen Recording** permission.

Works on Apple Silicon and Intel Macs with macOS 13 or later. ClaudeSniper reads the screen on your Mac and uses your own Claude plan through Claude Code: no API key.

Not affiliated with Anthropic.
