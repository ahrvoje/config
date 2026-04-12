# Rex

A Clink Lua plugin that turns the cmd.exe command line into an LLM prompt interface. Type input at your normal shell prompt, press **Ctrl+Enter** to send it to the AI. Normal **Enter** works exactly as before — cmd.exe processes the input. Rex has zero persistent terminal chrome of its own.

Supports Anthropic, OpenAI, GitHub Models / Copilot, Groq, and xAI.

## Install

Register the rex directory with Clink:

```
clink installscripts c:\repos\config\clink\rex
```

Set your API key (add to your shell startup or environment variables):

```
set REX_API_KEY=anthropic:sk-ant-...,github:ghp_...,openai:sk-...
```

### Requirements

- [Clink](https://chrisant996.github.io/clink/) (cmd.exe Lua scripting)
- [curl](https://curl.se/) on PATH (ships with Windows 10+)

### Files

| File | Purpose |
|------|---------|
| `rex.lua` | Clink entrypoint, key binding, slash-command dispatch, onboarding |
| `rex_state.lua` | Durable/session state, config, recall transcript, modes/skills loading |
| `rex_turn.lua` | Turn-scoped prompt framing, shell protocol, output shaping |
| `rex_provider.lua` | Credentials, model discovery, HTTP transport, retries |
| `json.lua` | Bundled JSON encoder/decoder |
| `modes.json` | Provider-aware model modes and capability flags |
| `rex_skills.md` | LLM runtime prompt source, including skills and prompt sections |

## Usage

```
C:\project> explain the error above          ← Ctrl+Enter → AI
C:\project> dir                              ← Enter → cmd.exe
C:\project> /model                           ← Ctrl+Enter → model selector
```

On first Ctrl+Enter, Rex runs interactive onboarding: fetches available models, opens a popup selector, and saves your choice to `~/.config/rex/config.toml`.

## Configuration

Config file location: `%USERPROFILE%/.config/rex/config.toml` (or `$XDG_CONFIG_HOME/rex/config.toml`)

| Key | Default | Description |
|-----|---------|-------------|
| `credential` | *(from onboarding)* | Selected `REX_API_KEY` entry label |
| `provider` | *(from onboarding)* | `anthropic`, `openai`, `github`, `groq`, `xai` |
| `model` | *(from onboarding)* | Model ID |
| `mode` | `"default"` | Mode ID |
| `memory` | `"all"` | Conversation-memory window |
| `max_tokens` | `4096` | Max response tokens |
| `timeout` | `120` | HTTP timeout (seconds) |

## Commands

Slash commands are submitted via **Ctrl+Enter**, same as prompts.

| Command | Action |
|---------|--------|
| `/model` | Select model via popup list |
| `/mode` | Select mode (e.g., thinking, reasoning effort) |
| `/memory` | Select the conversation-memory window |
| `/context` | Show text sent to the LLM; `/context <prompt>` includes a specific prompt |
| `/help` | List commands |

## API Key Prefixes

| Prefix | Provider |
|--------|----------|
| `github:` | GitHub Models / Copilot |
| `sk-ant-` | Anthropic |
| `sk-` | OpenAI |
| `gsk_` | Groq |
| `xai-` | xAI |

See [spec.md](spec.md) for the full specification.
