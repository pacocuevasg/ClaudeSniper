<div align="center">

<img src="docs/clawd.gif" width="140" alt="Clawd caminando">

# ClaudeSniper

**Captura cualquier cosa en tu pantalla con TextSniper y Claude te la explica al instante.**

Una app nativa de la barra de menú de macOS que conecta [TextSniper](https://textsniper.app) con Claude, usando **tu plan de Claude** (sin API key).

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)
![Swift](https://img.shields.io/badge/Swift-un%20solo%20archivo-F05138?logo=swift&logoColor=white)
![Claude Code](https://img.shields.io/badge/Claude%20Code-tu%20plan-D97757)
![License: MIT](https://img.shields.io/badge/licencia-MIT-blue)

<img src="docs/popup.png" width="640" alt="Pop-up de ClaudeSniper con una respuesta">

</div>

---

## ¿Qué hace?

1. Pulsas **⌘⇧2** y seleccionas un trozo de pantalla con TextSniper (una definición, una pregunta de examen, código, un párrafo en otro idioma…).
2. ClaudeSniper detecta la captura y se la manda a Claude.
3. Aparece un **pop-up junto al cursor** con la respuesta. Sin abrir ninguna ventana de chat.

<table>
<tr>
<td width="50%"><img src="docs/menu.png" alt="Menú de ClaudeSniper"></td>
<td>

### Funciones

- **Toggle on/off** en la barra de menú (la chispa se pone naranja cuando está activo).
- **Modelo:** Haiku · Sonnet · Opus · Fable.
- **Esfuerzo:** de *bajo* (respuestas en segundos) a *máximo*.
- **6 modos de acción rápida:** ✨ Auto · 💡 Explicar · 💬 Traducir · ≡ Resumir · ƒ Resolver · ✓ Corregir.
- **Repite la misma captura en otro modo** con los botones del pop-up o las teclas **1–6**.
- **Chats con memoria de 15 min:** las capturas seguidas comparten contexto; si pasan 15 min sin usarlo, empieza uno nuevo. Puedes crear uno nuevo o cambiar entre chats recientes.
- **Imágenes:** si lo copiado es una imagen, Claude la analiza.
- **Clawd en pixel art** caminando mientras Claude piensa.
- Copiar respuesta, abrir al iniciar sesión, `esc` para cerrar.

</td>
</tr>
</table>

<div align="center">
<img src="docs/loading.png" width="560" alt="Pop-up mientras Claude piensa">
</div>

## Requisitos

- macOS 13 Ventura o superior.
- [TextSniper](https://textsniper.app) con su atajo por defecto **⌘⇧2**.
- [Claude Code](https://claude.com/claude-code) instalado e iniciado con tu cuenta de Claude (Pro o Max):
  ```bash
  curl -fsSL https://claude.ai/install.sh | bash
  ```
- Xcode Command Line Tools (para compilar): `xcode-select --install`.

## Instalación

```bash
git clone https://github.com/pacocuevasg/ClaudeSniper.git
cd ClaudeSniper
./build.sh
open /Applications/ClaudeSniper.app
```

Primera vez, desde el menú ✨ de la barra superior:

1. **Iniciar sesión en Claude…**: se abre Terminal con `claude auth login`.
2. **Dar permiso de teclado (⌘⇧2)…**: activa ClaudeSniper en *Ajustes del Sistema → Privacidad y seguridad → Monitorización de entrada*.
3. Activa el switch, elige modelo, esfuerzo y modo, y prueba con ⌘⇧2.

> [!TIP]
> Para ver el pop-up sin gastar uso de tu plan: `open /Applications/ClaudeSniper.app --args --demo`

## Cómo funciona

```
⌘⇧2 ──► event tap (solo escucha) ──► "armado" 30 s
                                         │
TextSniper copia el texto ──► cambia el portapapeles
                                         │
                                         ▼
          claude -p --model … --effort … --session-id / --resume <chat>
                                         │
                                         ▼
                              pop-up con la respuesta
```

- **Sin API key:** usa el CLI de Claude Code en modo no interactivo (`claude -p`), así que consume tu plan normal de Claude.
- **Chats:** la primera captura crea una sesión (`--session-id`) y las siguientes la continúan (`--resume`) hasta que pasan 15 minutos sin usarla.
- **Todo en un archivo:** [`main.swift`](main.swift) (AppKit puro, sin dependencias). El pixel art se dibuja en código a partir de cuadrículas de texto.

## Privacidad

- El atajo se detecta con un *event tap* de **solo escucha**: no bloquea ni modifica ninguna tecla, y solo reacciona a ⌘⇧2.
- Solo se envía a Claude lo que copia TextSniper justo después de ⌘⇧2 (o lo que pidas con "Interpretar portapapeles ahora").
- Las conversaciones se guardan donde Claude Code guarda sus sesiones (`~/.claude/projects/`). Las capturas de imagen temporales se borran a las 24 h.

## Personalizar

Todo está al principio de [`main.swift`](main.swift):

- `systemPrompt`: cómo responde Claude (idioma, longitud, estilo).
- `modes`: añade o cambia modos de acción rápida (nombre, icono SF Symbol e instrucción).
- `ChatStore.ttl`: duración de la memoria de los chats (15 min por defecto).

Después vuelve a ejecutar `./build.sh`.

## Aviso

Proyecto personal sin afiliación con Anthropic ni con TextSniper. Claude y Clawd son marcas de Anthropic; TextSniper es de su respectivo desarrollador.

## Licencia

[MIT](LICENSE) © Paco Cuevas

---

<details>
<summary><b>English</b></summary>

**ClaudeSniper** is a native macOS menu bar app that pairs [TextSniper](https://textsniper.app) with Claude. Press ⌘⇧2, select anything on screen, and a pop-up shows Claude's take on it: explanations, translations, summaries, step-by-step solutions or corrections. It runs through [Claude Code](https://claude.com/claude-code) (`claude -p`), so it uses your regular Claude Pro/Max plan, with no API key. Features: model and effort pickers, 6 quick action modes (keys 1–6 re-run the same capture), 15-minute chat memory with chat switching, image support, and a pixel-art Clawd that walks while Claude thinks. Install with `./build.sh` (macOS 13+, Xcode Command Line Tools). UI text is in Spanish.

</details>
