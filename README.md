<div align="center">

<img src="docs/clawd.gif" width="140" alt="Clawd walking">

# ClaudeSniper

**Capture anything on your screen and get Claude's take on it instantly.**

A native macOS menu bar app with its own screen capture and on-device text recognition, using **your Claude plan** (no API key).

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)
![Swift](https://img.shields.io/badge/Swift-single%20file-F05138?logo=swift&logoColor=white)
![Claude Code](https://img.shields.io/badge/Claude%20Code-your%20plan-D97757)
![License: MIT](https://img.shields.io/badge/license-MIT-blue)

<a href="docs/claudesniper-demo.mp4"><img src="docs/claudesniper-demo.gif" width="720" alt="ClaudeSniper demo: capture some text and Claude answers in a pop-up"></a>

<sub>▶ <a href="docs/claudesniper-demo.mp4">Watch the 31-second demo with sound (MP4)</a></sub>

</div>

---

## What it does

1. Press **⌘⇧1** and drag over part of your screen: a definition, an exam question, some code, a table, a paragraph in another language…
2. ClaudeSniper reads the text on your Mac (Apple's Vision OCR, offline) and sends it to Claude.

Already use [TextSniper](https://textsniper.app)? Its ⌘⇧2 captures are picked up too.
3. A **pop-up appears next to your cursor** with the answer. No chat window to open.

<div align="center">
<img src="docs/popup.png" width="640" alt="ClaudeSniper pop-up showing an answer">
</div>

<table>
<tr>
<td width="50%"><img src="docs/menu.png" alt="ClaudeSniper menu"></td>
<td>

### Features

- **Built-in capture and OCR:** no other app needed. The text is read on your Mac in about half a second and also copied to your clipboard. Tables keep their rows and columns (macOS 26+), and a capture with no text is sent to Claude as an image.
- **Ask about selected text:** select text in any app, right-click → **Services → Ask ClaudeSniper**. No capture needed. (You can give it a keyboard shortcut in *System Settings → Keyboard → Keyboard Shortcuts → Services*.)
- **Multi-capture:** press **+** in the pop-up to add another capture to the same question (two pages, a question and its chart).
- **Capture text only (⌥⌘1):** read the text and copy it without asking Claude, like a plain OCR tool. QR codes and barcodes are read too.
- **Copy table:** a captured table (or a table in Claude's answer) is copied as a real table that pastes into Excel, Numbers, Sheets, Notion or Word. If the on-device reader misses a table, **Extract the table with Claude** in the **⋯** menu gets it from the image.
- **Have Claude look at the image:** when the text isn't enough (a diagram, a formula, tricky code), send the capture itself from the **⋯** menu.
- **Live answers:** the text appears while Claude writes it, and the menu bar spark twinkles while Claude is answering.
- **Rich answers:** headings, lists, tables, quotes and code blocks are rendered, not shown as raw Markdown.
- **Model:** ⚡ Fast · Haiku · Sonnet · Opus · Fable. **Effort:** from *low* (seconds) to *max*.
- **⚡ Fast** (Super fast mode): Haiku with no extended thinking, from a Claude Code process that's already running and waiting. First words in about 1 second instead of 3–4.
- **6 quick modes:** ✨ Auto · 💡 Explain · 💬 Translate · ≡ Summarize · ƒ Solve · ✓ Fix. Keys **1–6** re-run the same capture in another mode.
- **Your own modes:** up to 3, with your own instruction (keys 7–9), from **My modes** in the menu.
- **Follow-up questions:** press **Tab** in the pop-up to ask "and why?" in the same chat.
- **Whole conversation:** click the chat status at the bottom of the pop-up (or ⌘T) to see the chat as a thread: earlier captures dimmed, the latest at the bottom. Clicking Mini Clawd opens it this way.
- **Replace:** in Fix and Translate, paste the result back where you captured it.
- **Read aloud** in the answer's language.
- **Chat memory:** captures in a row share context (15 minutes by default, adjustable). Start a new chat or switch between recent ones.
- **History:** every answer is saved, searchable and grouped by day. Open any answer in the pop-up again to keep asking, or **export a chat** to Markdown or Apple Notes.
- **Show last answer:** ⌥⌘2 brings the pop-up back.
- **Pin the pop-up:** the pin button (⌘P) keeps it open (no auto-close, esc doesn't close it) while you work next to it.
- **Mini Clawd mode:** instead of the pop-up, a tiny Clawd walks while Claude thinks and hops with a **!** when the answer is ready. Click it to open the answer, drag it anywhere, right-click to hide it (Settings → Mini Clawd).
- **Answer language:** match your Mac, or English, Español, Português, Français or Deutsch.
- **Settings:** keep or join line breaks in captured text, answer length, pop-up position, auto-close, auto-copy, a sound when the answer arrives, Mini Clawd mode, a custom capture shortcut, open at login.
- **Images:** if the clipboard holds an image, Claude analyzes it.
- **Pixel-art Clawd** walks while Claude thinks.

</td>
</tr>
</table>

### In the pop-up

| Key | What it does |
|---|---|
| **1–6** (7–9 for your modes) | Re-run the same capture in another mode |
| **Tab** | Ask a follow-up in the same chat |
| **+** | Add another capture to this question |
| **⌘C** | Copy the answer (or just the selected text) |
| **⌘↩** | Replace: paste the result where you captured it (Fix and Translate) |
| **⇧⌘C** | Copy table: the captured table, or the table in the answer |
| **⌘T** | Show the whole conversation |
| **⌘P** | Pin the pop-up open |
| **⌘R** | Read aloud |
| **⌘N** | New chat |
| **Esc** | Close |

The **⋯** button has the same actions, plus Export chat and History.

Anywhere on your Mac (while ClaudeSniper is on): **⌘⇧1** capture and ask · **⌥⌘1** capture text only · **⌥⌘2** show the last answer.

<div align="center">
<img src="docs/markdown.png" width="640" alt="An answer with a numbered list, a code block, a table and a quote">
<br><br>
<img src="docs/history.png" width="760" alt="The History window: answers grouped by day on the left, the selected answer on the right">
</div>

<div align="center">
<img src="docs/loading.png" width="560" alt="Pop-up while Claude is thinking">
</div>

## Requirements

- macOS 13 Ventura or later.
- [Claude Code](https://claude.com/claude-code) installed and signed in with your Claude account (Pro or Max):
  ```bash
  curl -fsSL https://claude.ai/install.sh | bash
  ```
- Xcode Command Line Tools (to build): `xcode-select --install`. Table detection needs Xcode 26 to build and macOS 26 to run; everything else works from macOS 13.

## Installation

### Download (no Xcode needed)

1. Download the latest **ClaudeSniper-x.y.z.zip** from [Releases](https://github.com/pacocuevasg/ClaudeSniper/releases/latest) and unzip it.
2. Move **ClaudeSniper.app** to **Applications** and open it.
3. The first time, macOS says it can't check the app (it isn't notarized by Apple): open **System Settings → Privacy & Security** and click **Open Anyway**.

Works on Apple Silicon and Intel.

### Or build it yourself

```bash
git clone https://github.com/pacocuevasg/ClaudeSniper.git
cd ClaudeSniper
./build.sh
open /Applications/ClaudeSniper.app
```

### First launch

A **welcome guide** checks that Claude Code is installed, helps you sign in and lets you try a capture or a sample answer. You can reopen it from **Settings → Welcome guide**.

1. **Sign in to Claude…** opens Terminal with `claude auth login`.
2. Flip the switch on, pick a model, effort and mode, and press ⌘⇧1 (change it in **Settings → Change capture shortcut**).

The capture uses macOS's own selection (the same as ⌘⇧4), so you pick exactly what ClaudeSniper sees. If macOS asks to let ClaudeSniper record the screen, allow it in *System Settings → Privacy & Security → Screen & System Audio Recording*.

> [!TIP]
> To preview the pop-up without using your plan: `open /Applications/ClaudeSniper.app --args --demo` (or `--demo-mini` for Mini Clawd)
>
> To test without capturing: `open /Applications/ClaudeSniper.app --args --ocr-file some-image.png --mode explain` reads an image file, and `--interpret-clipboard` uses the text on your clipboard.

## How it works

```
⌘⇧1 ──► drag over part of the screen (the system's own selection)
                                         │
              text read on your Mac with Apple's Vision OCR (~0.4 s)
                                         │
                                         ▼
          claude -p --model … --effort … --session-id / --resume <chat>
                                         │
                                         ▼
                              pop-up with the answer
```

- **No API key:** it runs the Claude Code CLI in non-interactive mode (`claude -p --output-format stream-json`), so it uses your regular Claude plan and shows the answer as it's written. Your MCP servers aren't loaded (`--strict-mcp-config`), which keeps it fast.
- **Chats:** the first capture creates a session (`--session-id`) and later ones continue it (`--resume`) until the chat memory time passes without use.
- **One file:** [`main.swift`](main.swift), plain AppKit, no dependencies. The pixel art is drawn in code from text grids.

## Privacy

- **Text recognition happens on your Mac** (Apple's Vision framework). Only the recognized text is sent to Claude; the image itself is sent only for captures with no text, or when you choose "Have Claude look at the image".
- You select what gets captured, with macOS's own selection. Nothing is captured in the background.
- No keyboard monitoring: the shortcuts are regular global hotkeys. For TextSniper users, ClaudeSniper only checks whether TextSniper's capture window is on screen when the clipboard changes.
- Conversations are stored where Claude Code keeps its sessions (`~/.claude/projects/`). The answer history is a local file (`~/Library/Application Support/ClaudeSniper/history.json`, last 500 answers) that you can clear from the History window. Temporary image captures are deleted after 24 hours.
- **Replace** pastes automatically only if you allow *Accessibility* (Settings → Allow auto-paste); otherwise it copies and you press ⌘V. **Export to Notes** asks macOS for permission to control Notes the first time.

## Customize

Most things are in the menu under **Settings**. For deeper changes, everything is at the top of [`main.swift`](main.swift):

- `systemPrompt`: how Claude answers (style, rules).
- `Theme`: the colors and corner radius used by the pop-up, the welcome window and the app icon.
- `builtInModes`: the six built-in quick action modes (name, SF Symbol icon and instruction). For your own modes you don't need code: use **My modes** in the menu.
- `languages`: the answer languages offered in the menu.
- `Settings` and the `…Options` lists: the choices shown in the Settings menu.

Then run `./build.sh` again.

## Disclaimer

A personal project, not affiliated with Anthropic or TextSniper. Claude and Clawd are trademarks of Anthropic; TextSniper belongs to its developer.

## License

[MIT](LICENSE) © Paco Cuevas
