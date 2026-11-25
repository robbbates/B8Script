# B8Script for Visual Studio Code

Syntax highlighting for B8Script, plus bracket matching and comment toggling.

## What it colors

| What | Example | Scope (what a theme colors) |
|---|---|---|
| Comments: a string dropped at once | `"Draw the board";` | `comment.line` |
| Strings | `"Score: /s"$` | `string.quoted.double` |
| Escapes in strings | `/M/J`, `/{`, `/~` | `constant.character.escape` |
| Variable escapes in strings | `/s` | `variable.other.escape` |
| Words: calls, and definitions after `[` | `[F ...]`, `7F` | `entity.name.function` |
| Variables | `a@`, `x!` | `variable.other` |
| Numbers, negative ones too | `42`, `-1` | `constant.numeric` |
| Flow control | `( ) [ ] \` | `keyword.control` |
| Console | `$ # ' ?` | `keyword.other.io` |
| Stack, memory, arithmetic | `: ; % { }`, `@ ! , . _`, `+ - * / & \| ^ ~ < = >` | `keyword.operator` |
| Machine code | `` `21AB09 ``, `` ` `` | `keyword.other.machine-code`, `constant.numeric.hex` |
| Bytes 80h-FFh outside strings (reserved) | | `invalid.illegal` |

A `-` directly before a digit is part of the number, as the interpreter reads it: `5-3` is 5 and -3, `5- 3` subtracts.

## Install

No packaging needed. Copy (or link) this folder into your VS Code extensions folder and restart VS Code:

```
# Linux, macOS
cp -r editors/vscode-b8script ~/.vscode/extensions/b8script
# Windows (PowerShell)
Copy-Item -Recurse editors\vscode-b8script "$env:USERPROFILE\.vscode\extensions\b8script"
```

Or install the ready-made `b8script-0.1.0.vsix` in this folder (on GitHub, open it and use **Download raw file**):

```
code --install-extension b8script-0.1.0.vsix
```

or with **Extensions: Install from VSIX...** in VS Code. To build the `.vsix` yourself (after changing the grammar, say):

```
cd editors/vscode-b8script
npx @vscode/vsce package
```

Files ending in `.b8s` or `.B8S` open as B8Script. The commented games are `.TXT` files; to have those highlighted too, add this to your settings (or pick **B8Script** with **Change Language Mode** for one file):

```json
"files.associations": { "**/games/*.TXT": "b8script" }
```

## Comments

**Toggle Block Comment** (Shift+Alt+A) wraps the selection in `"` and `";`, which is a B8Script comment. Only comments on one line are recognized as comments: a string that runs over several lines is colored as a string. (Every comment in the games is on one line.)

## Your own colors

Many themes give words and numbers similar colors. To change any of them, add to your settings, for example:

```json
"editor.tokenColorCustomizations": {
  "textMateRules": [
    { "scope": "entity.name.function.call.b8script", "settings": { "foreground": "#FFD700" } },
    { "scope": "entity.name.function.definition.b8script", "settings": { "foreground": "#FFD700", "fontStyle": "bold" } },
    { "scope": "keyword.other.io.b8script", "settings": { "foreground": "#4FC1FF" } }
  ]
}
```
