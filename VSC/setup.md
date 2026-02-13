# Global Visual Studio Code Configuration - semantic syntax highlight

1. Open Command Palette (`Ctrl+Shift+P`).
2. Run `Preferences: Open User Settings (JSON)`.
3. Paste this into your user `settings.json`:

```json
{
  "editor.semanticHighlighting.enabled": true,
  "editor.occurrencesHighlight": "singleFile",
  "editor.selectionHighlight": false,
  "workbench.colorCustomizations": {
    "editor.wordHighlightBackground": "#00000000",
    "editor.wordHighlightBorder": "#4DA6FF",
    "editor.wordHighlightStrongBackground": "#00000000",
    "editor.wordHighlightStrongBorder": "#FF0000",
    "editor.symbolHighlightBackground": "#00000000",
    "editor.symbolHighlightBorder": "#4DA6FF"
  }
}
```

4. Reload VS Code (`Developer: Reload Window`).

Windows user settings file path:
`%APPDATA%\Code\User\settings.json`

# Add-on Dependencies for Semantic Behavior

- Semantic read/write distinction depends on language intelligence from extensions/language servers, not just color settings.
- If language symbol support is missing, VS Code falls back to plain word highlighting (same-name collisions can happen).
- For Python, install/enable:
  - `Python` extension (`ms-python.python`)
  - `Pylance` (`ms-python.vscode-pylance`)  
  - Pylance explicitly provides semantic highlighting and is the default Python language support dependency.
- `Rust`: Use `rust-lang.rust-analyzer`. It explicitly provides semantic syntax highlighting and rich symbol/reference features, so semantic scoping is strong.
- `Julia`: Use `julialang.language-julia`. It provides syntax highlighting, completion, linter, and code navigation; semantic support exists via its language tooling stack, but semantic-token behavior is less explicitly documented than Rust/C.
- `JavaScript`: No extra add-on required by default. VS Code uses built-in `TypeScript and JavaScript Language Features` (`vscode.typescript-language-features`). Semantic behavior is strong when project IntelliSense is active.
- `C`: Install `ms-vscode.cpptools`. Semantic colorization is available when IntelliSense is enabled (`C_Cpp.enhancedColorization`, enabled by default).

# Notes

- `editor.symbolHighlightStrongBorder` is not a documented VS Code color key.
- Border thickness (for example `3px`) is not configurable via standard VS Code settings.
- VS Code removed semantic highlighting support for workspace TypeScript `4.1` or older; native semantic support starts at `4.2+`.
