## Install

1. Download **ClaudeSniper-x.y.z.zip** below and unzip it.
2. Move **ClaudeSniper.app** to your **Applications** folder.
3. Open it. The first time, macOS will say it can't check the app, because it isn't notarized by Apple:
   - Open **System Settings → Privacy & Security**, scroll down and click **Open Anyway** next to ClaudeSniper.
   - Or in Terminal: `xattr -dr com.apple.quarantine /Applications/ClaudeSniper.app`
4. The welcome guide checks that [Claude Code](https://claude.com/claude-code) is installed and signed in, and that you have [TextSniper](https://textsniper.app).

Works on Apple Silicon and Intel Macs with macOS 13 or later. ClaudeSniper uses your own Claude plan through Claude Code: no API key.

Not affiliated with Anthropic or TextSniper.
