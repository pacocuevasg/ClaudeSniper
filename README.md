<div align="center">

<img src="docs/clawd.gif" width="140" alt="Clawd walking">

# ClaudeSniper

**Capture anything on your screen with TextSniper and get Claude's take on it instantly.**

A native macOS menu bar app that connects [TextSniper](https://textsniper.app) to Claude, using **your Claude plan** (no API key).

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)
![Swift](https://img.shields.io/badge/Swift-single%20file-F05138?logo=swift&logoColor=white)
![Claude Code](https://img.shields.io/badge/Claude%20Code-your%20plan-D97757)
![License: MIT](https://img.shields.io/badge/license-MIT-blue)

<a href="docs/claudesniper-demo.mp4"><img src="docs/claudesniper-demo.gif" width="720" alt="ClaudeSniper demo: press ⌘⇧2, select text, and Claude answers in a pop-up"></a>

<sub>▶ <a href="docs/claudesniper-demo.mp4">Watch the 31-second demo with sound (MP4)</a></sub>

</div>

---

## What it does

1. Press **⌘⇧2** and select part of your screen with TextSniper: a definition, an exam question, some code, a paragraph in another language…
2. ClaudeSniper picks up the capture and sends it to Claude.
3. A **pop-up appears next to your cursor** with the answer. No chat window to open.

<div align="center">
<img src="docs/popup.png" width="640" alt="ClaudeSniper pop-up showing an answer">
</div>

<table>
<tr>
<td width="50%"><img src="docs/menu.png" alt="ClaudeSniper menu"></td>
<td>

### Features

- **On/off toggle** in the menu bar (the spark turns orange when it's on).
- **Model:** Haiku · Sonnet · Opus · Fable.
- **Effort:** from *low* (answers in seconds) to *max*.
- **6 quick action modes:** ✨ Auto · 💡 Explain · 💬 Translate · ≡ Summarize · ƒ Solve · ✓ Fix.
- **Re-run the same capture in another mode** with the pop-up buttons or keys **1–6**.
- **Chat memory:** captures in a row share context; after 15 minutes without use (configurable), a new chat starts. You can also start a new chat or switch between recent ones.
- **Answer language:** match your Mac, or pick English, Español, Português, Français or Deutsch.
- **Images:** if the clipboard holds an image, Claude analyzes it.
- **Pixel-art Clawd** walks while Claude thinks.
- **Settings:** chat memory (off, 5 min to 1 hour), answer length, pop-up position, auto-close, auto-copy, a sound when the answer arrives, a custom capture shortcut, clear all chats, open at login.
- Copy the answer and `esc` to close.

</td>
</tr>
</table>

<div align="center">
<img src="docs/loading.png" width="560" alt="Pop-up while Claude is thinking">
</div>

## Requirements

- macOS 13 Ventura or later.
- [TextSniper](https://textsniper.app) with its default **⌘⇧2** shortcut.
- [Claude Code](https://claude.com/claude-code) installed and signed in with your Claude account (Pro or Max):
  ```bash
  curl -fsSL https://claude.ai/install.sh | bash
  ```
- Xcode Command Line Tools (to build): `xcode-select --install`.

## Installation

```bash
git clone https://github.com/pacocuevasg/ClaudeSniper.git
cd ClaudeSniper
./build.sh
open /Applications/ClaudeSniper.app
```

The first time, from the ✨ menu in the menu bar:

1. **Sign in to Claude…** opens Terminal with `claude auth login`.
2. Flip the switch on, pick a model, effort and mode, and try ⌘⇧2 in TextSniper.

No keyboard permission is needed: ClaudeSniper notices TextSniper's capture overlay when the text is copied.

> [!TIP]
> To preview the pop-up without using your plan: `open /Applications/ClaudeSniper.app --args --demo`

## How it works

```
⌘⇧2 in TextSniper ──► capture overlay on screen
                                         │
TextSniper copies the text ──► clipboard changes while the overlay is up
                                         │
                                         ▼
          claude -p --model … --effort … --session-id / --resume <chat>
                                         │
                                         ▼
                              pop-up with the answer
```

- **No API key:** it runs the Claude Code CLI in non-interactive mode (`claude -p`), so it uses your regular Claude plan.
- **Chats:** the first capture creates a session (`--session-id`) and later ones continue it (`--resume`) until the chat memory time passes without use.
- **One file:** [`main.swift`](main.swift), plain AppKit, no dependencies. The pixel art is drawn in code from text grids.

## Privacy

- No keyboard monitoring is needed: ClaudeSniper only checks whether TextSniper's capture window is on screen when the clipboard changes. (If you do allow *Input Monitoring*, it also listens for your capture shortcut with a listen-only event tap that never blocks or changes keys.)
- Only what TextSniper copies is sent to Claude (or what you send with "Interpret clipboard now").
- Conversations are stored where Claude Code keeps its sessions (`~/.claude/projects/`). Temporary image captures are deleted after 24 hours.

## Customize

Most things are in the menu under **Settings**. For deeper changes, everything is at the top of [`main.swift`](main.swift):

- `systemPrompt`: how Claude answers (style, rules).
- `modes`: add or change quick action modes (name, SF Symbol icon and instruction).
- `languages`: the answer languages offered in the menu.
- `Settings` and the `…Options` lists: the choices shown in the Settings menu.

Then run `./build.sh` again.

## Disclaimer

A personal project, not affiliated with Anthropic or TextSniper. Claude and Clawd are trademarks of Anthropic; TextSniper belongs to its developer.

## License

[MIT](LICENSE) © Paco Cuevas
