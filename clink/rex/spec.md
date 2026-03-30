# Rex - Clink AI Agent Plugin

## Overview

Rex is a Clink Lua plugin whose entrypoint is `rex.lua` and whose implementation is intentionally split across **four sibling Lua files**: `rex.lua`, `rex_state.lua`, `rex_turn.lua`, and `rex_provider.lua`. The user types input at their normal shell prompt and presses **Ctrl+Enter** to send it to Rex instead of cmd.exe. Normal **Enter** works exactly as before — cmd.exe processes the input. Rex does not add persistent terminal chrome of its own: no screen clearing, no prompt changes, no dedicated Rex indicators, and no branded UI layer. The terminal remains the normal cmd environment. Visible turn output may still use ordinary terminal styling, including ANSI color, when useful. The split is deliberate: each file should stay large enough to preserve semantic cohesion, but small enough to be generated in one single homogeneous shot. In practice, no implementation file should grow past roughly 1000 lines, and the four files should remain reasonably similar in length. `rex_state.lua` and `rex_turn.lua` are intentionally separate so durable/session concerns do not accumulate in the same file as turn-scoped prompt, shell, and response-flow logic. There is no external binary and no external dependency beyond Clink and an API key.

## Goals

- **Pure Clink Lua plugin**: Exactly four implementation files — `rex.lua`, `rex_state.lua`, `rex_turn.lua`, and `rex_provider.lua` — placed in a Clink scripts directory. No compiled binary, no external dependencies.
- **Generation-sized modules**: Keep the four implementation files reasonably similar in length and comfortably below the point where one-shot generation becomes unreliable; treat roughly 1000 lines as a hard upper bound per file.
- **Clear state/turn separation**: `rex_state.lua` owns durable/session state and metadata resolution, while `rex_turn.lua` owns turn-scoped request assembly, shell-command handling, and response shaping. The split must improve readability and maintainability, not just move lines around.
- **Ctrl+Enter activation**: The user types at their normal cmd prompt. Enter → cmd.exe. Ctrl+Enter → Rex. No special prefix, no mode switching, no activation/deactivation.
- **Invisible operation**: Rex does not add persistent UI chrome of its own. No screen clearing, no prompt changes, no Rex-branded indicators, no thinking animations, and no decorative wrapper layer around the shell. Ordinary answer output may still use terminal styling, including ANSI color, when useful.
- **Terminal-native output**: LLM responses are printed via `clink.print()`. The LLM decides how to format responses (guided by `rex_skills.md`), and final answers may use normal terminal text styling, including ANSI rendering, but must not be wrapped in decorative outer boxes or wrappers.
- **Context-aware**: Automatically captures cwd, terminal size, and git state.
- **Capability-aware request building**: Optional API features such as web search are enabled only when the active endpoint and selected model support them.
- **Turn-focused conversation framing**: Prior turns remain available, but each new prompt is explicitly marked as the active request so stale context does not hijack the answer.
- **No shell-denial mode**: There is no user-facing "shell execution is not allowed for this turn" state. The only distinction is whether the newest user request explicitly asks Rex to perform shell activity.
- **Shell-history parity**: Every non-empty line submitted via Ctrl+Enter is appended to Clink shell history exactly once, so it can be recalled with the Up arrow just like a normal Enter-submitted command.
- **Explicit shell execution protocol**: When and only when the current user turn explicitly asks Rex to perform shell activity, the model may return a machine-readable shell-command block that Rex extracts and executes in the live main shell context. Session-visible shell effects such as cwd changes and environment-variable changes must persist into the next prompt. Rex then prints a normal shell transcript and ends the turn without a second model pass.
- **No silent turn consumption**: Every non-empty Ctrl+Enter submission consumed by Rex must end with visible output: an answer, shell transcript, confirmation, cancellation notice, or error. Returning straight to the prompt with no user-visible result is a bug.
- **Skill-enriched**: A bundled `rex_skills.md` teaches the LLM what the terminal can render.
- **Multi-provider**: Supports Anthropic, OpenAI, GitHub Copilot / GitHub Models, Groq, and xAI. `$REX_API_KEY` may contain one or more comma-separated credentials.
- **Dynamic model discovery**: Available models are fetched live from each provider's model-listing API — nothing is hardcoded.
- **Data-driven model metadata**: Model modes (e.g., extended thinking, reasoning effort) and optional per-model capability flags (e.g., web search) are defined in a `modes.json` data file — not hardcoded in plugin code — so they can be updated without changing the plugin.
- **Persistent configuration**: An XDG-compliant, self-documenting config file stores user preferences across sessions. Auto-created during onboarding.
- **Durable recall transcript**: Every Rex instance creates its own append-only session file under the recall configuration folder and flushes user/assistant turn data immediately as it becomes available.
- **Slash commands**: `/model`, `/mode`, `/settings`, `/help`, etc. — submitted via Ctrl+Enter like any other Rex input.

### Workflow

1. User types a natural language prompt at the cmd prompt (e.g., `explain the error above`).
2. User presses **Ctrl+Enter**.
3. Clink's key binding fires `rex_submit()`, which reads the input line, records that exact submitted line into the active Clink shell-history session using the path-appropriate mechanism, appends accepted conversation turns to the current durable recall session file, and manages the readline buffer so visible-output flows preserve the submitted text on screen while popup flows avoid phantom prompt redraws.
4. Plugin reads config. If no valid model is configured, the startup onboarding flow runs (see [Startup Onboarding](#startup-onboarding)).
5. Plugin makes an HTTP request to the LLM API with the prompt + the effective conversation-memory window + prior-history framing + context + skills. If the newest request explicitly asks for shell activity, Rex may execute one machine-readable shell command returned by the model in the live main shell context, capture the result, and finish the turn by printing the shell transcript directly.
6. Final visible conversation output is printed to the terminal via `clink.print()` and appended immediately to the current durable recall session file.
7. Cmd.exe shows its next prompt — the user can type another prompt or a normal command.

```
C:\project> explain the error above          ← user types, presses Ctrl+Enter

The error on line 42 is a null pointer       ← LLM response (plain text)
dereference. The variable `ctx` is not
initialized before...

C:\project> dir                              ← user types, presses Enter (normal cmd)
 Volume in drive C is OS
 ...

C:\project> /model                           ← user types, presses Ctrl+Enter
<popup list for model selection>

C:\project>
```

The cmd prompt (`C:\project>`) is never modified. Enter always goes to cmd.exe. Ctrl+Enter always goes to Rex.

### Slash Commands via Ctrl+Enter

Slash commands are submitted the same way as prompts — by pressing **Ctrl+Enter**. If the user types `/model` and presses Enter, cmd.exe tries to execute it as a normal command (whatever happens, happens). If the user types `/model` and presses **Ctrl+Enter**, Rex intercepts it and runs the model selector.

This means there is no separate "active" or "inactive" state. Rex is always available via Ctrl+Enter. There is no toggle.

### Shell History Integration

Rex input handling must preserve normal shell recall behavior:

- Every non-empty line submitted via Ctrl+Enter is appended to Clink shell history exactly once for the active Clink session.
- This includes both normal prompts and slash commands such as `/model`, `/context`, or `/settings`.
- The literal text the user typed is what gets stored. Rex must not store the framed prompt, synthetic helper messages, shell-command protocol blocks, or assistant responses in shell history.
- Rex must use the history mechanism that matches the execution path:
  - Immediate print path and popup-only path: call `rl.invokecommand("add-history")` while the submitted text is still present in `rl_buffer`. On the print path, `beginoutput()` must happen first so the line remains visible on screen before `add-history` clears it.
  - Deferred popup-then-print path: keep the buffer intact through the popup, save the trimmed line separately, and append that saved line later via `clink history -s` scoped to the active session when the deferred buffer is flushed.
- `clink.history.add()` is not part of Clink's Lua API and must not be relied on.
- On the deferred path, the history write must happen before Rex prints the first visible output for that turn or returns cleanly after cancellation/error handling, so the submitted line is still recallable even when onboarding does not lead to a successful answer.
- Acceptance test: after submitting `2+2` with Ctrl+Enter, the next prompt's Up arrow recalls `2+2` just as if the line had been submitted with normal Enter.
- Acceptance test: after invoking `/model` with Ctrl+Enter and cancelling the popup, the next prompt's Up arrow recalls `/model`.
- Acceptance test: after invoking `/memory` with Ctrl+Enter and cancelling the popup, the next prompt's Up arrow recalls `/memory`.
- Acceptance test: after invoking `/settings` with Ctrl+Enter, the next prompt's Up arrow recalls `/settings`.
- Acceptance test: after first-run onboarding triggered by `2+2`, the next prompt's Up arrow recalls `2+2` whether onboarding completes or is cancelled.

## Configuration

### XDG Base Directory

Rex stores its configuration file at the XDG-compliant path:

```
$XDG_CONFIG_HOME/rex/config.toml
```

If `$XDG_CONFIG_HOME` is not set, the default path on Windows is:

```
%USERPROFILE%/.config/rex/config.toml
```

If the config file does not exist or cannot be parsed, Rex triggers the startup onboarding flow on first Ctrl+Enter (see [Startup Onboarding](#startup-onboarding)). After onboarding completes, Rex writes the config file with the selected settings.

The config file is created via standard `io.open()` in write mode — Clink's Lua environment has full file I/O.

### Recall Configuration Folder

Rex stores durable session transcripts in the recall configuration folder:

```
$XDG_CONFIG_HOME/rex/recall/
```

If `$XDG_CONFIG_HOME` is not set, the default path on Windows is:

```
%USERPROFILE%/.config/rex/recall/
```

The recall configuration folder is created automatically if it does not exist.

### Config File Format

The configuration file uses a simple `key = value` format (one key per line). Lines starting with `#` are comments. The file begins with a descriptive header explaining what Rex is, where it is installed, and what each setting does.

#### Generated config file example

```toml
# Rex - Clink AI Agent Plugin
# https://github.com/<user>/rex
#
# Rex turns your cmd prompt into an LLM interface.
# Type any text and press Ctrl+Enter to send it to the AI.
# Normal Enter still executes commands in cmd.exe as usual.
#
# Installed at: C:\repos\rex
# Skills file:  C:\repos\rex\rex_skills.md
# Modes file:   C:\repos\rex\modes.json
#
# Settings:
#   credential - Selected API-key entry ID (e.g., "github-main")
#   model      - LLM model ID (e.g., "openai/gpt-5.4", "claude-sonnet-4-20250514")
#   mode       - Model mode ID (e.g., "default", "high_reasoning")
#   provider   - Provider of the current model (anthropic/openai/github/groq/xai)
#   memory     - Conversation-memory window for API requests
#   max_tokens - Maximum tokens in LLM response (default: 4096)
#   timeout    - HTTP request timeout in seconds (default: 120)

credential = "github-main"
provider = "github"
model = "openai/gpt-5.4"
mode = "high_reasoning"
memory = "last_2_qa"
max_tokens = 8192
```

#### Top-level keys

| Key             | Type   | Default              | Description                                                                 |
|-----------------|--------|----------------------|-----------------------------------------------------------------------------|
| `credential`    | string | *(selected in onboarding)* | Stable ID of the selected API-key entry.                              |
| `provider`      | string | *(derived from credential)* | Provider of the currently selected model. Derived automatically when a model is selected via `/model` or onboarding. One of: `anthropic`, `openai`, `github`, `groq`, `xai`. **Not a filter** — `/model` always shows all models from all configured credentials. |
| `model`         | string | *(selected in onboarding)* | Model ID to use.                                                       |
| `mode`          | string | `"default"`          | Mode ID to use. Must be valid for the active model per `modes.json`.        |
| `memory`        | string | `"all"`              | Conversation-history window to include in future API requests. One of: `none`, `all`, `last_answer`, `last_qa`, `last_2_qa`, `last_4_qa`. |
| `max_tokens`    | integer| `4096`               | Maximum tokens in LLM response.                                             |
| `timeout`       | integer| `120`                | HTTP request timeout in seconds.                                             |

### Configuration Precedence

Settings are resolved in this order (highest to lowest priority):

1. **Session state** — values set via `/model`, `/mode`, or `/memory` during the current session
2. **Config file** — values from the config file
3. **Built-in defaults** — hardcoded fallback values

`/settings` reports the effective values after this resolution order is applied; it is not a raw dump of the config file.

### Memory Window Values

The `memory` setting controls how much prior conversation Rex includes in the next API request. The current prompt is always included separately as the newest user message; the `memory` setting only affects earlier stored conversation.

Supported values:

- `none` — include no prior conversation messages.
- `all` — include the full stored conversation history for the current Rex session.
- `last_answer` — include only the most recent stored assistant message before the current prompt.
- `last_qa` — include the most recent completed question-and-answer pair before the current prompt.
- `last_2_qa` — include the most recent 2 completed question-and-answer pairs before the current prompt.
- `last_4_qa` — include the most recent 4 completed question-and-answer pairs before the current prompt.

Definitions:

- A "question" is a stored user history entry from an earlier completed turn.
- An "answer" is the stored assistant entry for that turn. A normal assistant reply and a shell transcript both count as answers.
- A "completed question-and-answer pair" means a stored user entry followed by its stored assistant reply/transcript from an earlier turn.
- If fewer completed pairs exist than requested, Rex includes as many trailing completed pairs as are available.

## Slash Commands

When input submitted via Ctrl+Enter starts with `/`, it is handled as a built-in command — not sent to the LLM.

| Command      | Purpose                                                |
|--------------|--------------------------------------------------------|
| `/model`     | Select LLM model via popup list across all configured credentials |
| `/mode`      | Select model mode via popup list                      |
| `/memory`    | Select conversation-memory window for future API requests |
| `/settings`  | Print the effective current Rex settings                 |
| `/context`   | Show what context is being sent to the LLM, including the effective memory window |
| `/help`      | List available commands                                |

### Selector Pattern

`/model`, `/mode`, and `/memory` use Clink's `clink.popuplist()`:

1. Plugin fetches or constructs the available options (models from API, modes from `modes.json`, memory choices from a fixed built-in list).
2. Opens a popup list with type-to-filter.
3. While the popup is open, arrow-key navigation, filtering, and highlight changes must not print anything, must not call `rl_buffer:beginoutput()`, and must not reveal a duplicate or blank cmd prompt line above the popup.
4. User navigates with arrow keys and selects with Enter.
5. Validated selection updates the session state.
6. Pressing Escape cancels the selection (no change) and prints a short visible cancellation line such as `Cancelled.` or `No change.`.

#### Popup return value

`clink.popuplist(title, items)` returns a **single value**: the selected item string, or `nil` if the user pressed Escape. There is no second return value for an index.

```lua
local value = clink.popuplist("Select model", items)
if not value or value == "" then
    clink.print("Cancelled.")
    return
end
```

Because only the string is returned, the plugin must maintain a lookup table mapping display labels back to their metadata (credential, provider, model ID):

```lua
local lookup = {}
for _, m in ipairs(merged) do
    local label = m.id .. "  [" .. m.credential .. "]"
    items[#items + 1] = label
    lookup[label] = m
end
local value = clink.popuplist("Select model", items)
local selected = lookup[value]
```

Incorrect — assuming multiple return values:

```lua
local value, idx = clink.popuplist("Select model", items)   -- idx is always nil
local selected = merged[idx]                                  -- nil, selection silently lost
```

#### Popup interaction invariant

`clink.popuplist()` is an interactive UI surface, not visible output from Rex itself. Opening or navigating a popup must leave the underlying terminal display untouched. In particular, `/model`, `/mode`, `/memory`, and onboarding must not produce a "phantom prompt" line when the user presses arrow keys inside the popup. For onboarding triggered by a normal prompt, this popup cleanliness requirement does not override later prompt preservation: once popup interaction is finished and Rex starts printing, the original submitted prompt must still be visible.

### `/model`

1. If model lists are not cached, fetch them from every configured credential that is in scope.
2. Merge the results into one selector. Each item must retain `credential`, `provider`, and `model` metadata, and the visible label should disambiguate same-name models from different credentials.
3. Open a `clink.popuplist()` with the filtered model list.
4. Treat the selected item as **tentative** until Rex validates it against the target credential/provider pair.
5. On validated selection:
   - Update the active credential and provider.
   - Update the active model.
   - Clear any session mode override for the previous model; the effective mode after model change is `default` unless the user explicitly chooses another valid mode.
   - Print a plain-text confirmation.
6. If the selected model is later rejected as unsupported, unavailable, stale, or incompatible with the active credential/provider pair, Rex must keep the previous working selection (if any), avoid writing the invalid selection to config, and show a short hint telling the user to choose another model.

Selecting a model clears the previous model's explicit mode selection and falls back to the effective `default` mode.

### `/mode`

1. Look up available modes for the current model in `modes.json`.
2. If only the `default` mode exists, print a plain-text message.
3. Otherwise, open a `clink.popuplist()` with the available modes.
4. Treat the selected mode as **tentative** until Rex validates it against the active provider/model pair.
5. On validated selection:
   - Update the active mode.
   - Print a plain-text confirmation.
6. If the selected mode is unsupported for the current model/provider pair, Rex must keep the model, fall back to `default`, avoid saving the invalid mode, and print a short hint telling the user to choose another mode or continue with `default`.

### `/memory`

1. Open a `clink.popuplist()` containing exactly these user-visible options:
   - `none`
   - `all`
   - `last answer`
   - `last question and answer`
   - `last 2 questions and answers`
   - `last 4 questions and answers`
2. Map those visible labels to stable internal config values:
   - `none` → `none`
   - `all` → `all`
   - `last answer` → `last_answer`
   - `last question and answer` → `last_qa`
   - `last 2 questions and answers` → `last_2_qa`
   - `last 4 questions and answers` → `last_4_qa`
3. On validated selection:
   - Update the active memory setting for the current session.
   - Persist the chosen value to config.
   - Print a plain-text confirmation such as `Memory: last 2 questions and answers.`
4. Pressing Escape leaves the current setting unchanged and prints a short visible cancellation line.
5. `/memory` changes only how much prior conversation is included in future API requests. It does not delete, truncate, or rewrite stored conversation history.

### `/settings`

1. Print the effective current Rex settings as plain text and return. There is no popup, no LLM request, no model-catalog fetch, and no config mutation.
2. The printed values must reflect normal runtime resolution: session-state overrides first, then config-file values, then built-in defaults.
3. At minimum, print `credential`, `provider`, `model`, `mode`, `memory`, `max_tokens`, and `timeout`.
4. If a value is currently unset, unavailable, or not yet derived, show that explicitly with a short placeholder such as `not set`.
5. `/settings` must work even before onboarding is complete. It is informational only and must not force onboarding just to print unresolved fields.

Unrecognized `/` commands print a plain-text error.

### Selection Validation And Graceful Recovery

Model and mode picks are tentative until Rex validates them against the current credential, provider endpoint, model metadata, and final request acceptance.

Unsupported or stale selections are recoverable states, not fatal errors. Typical cases include:

- A model disappeared after a provider catalog refresh.
- A GitHub-hosted model rejects a mode parameter that works on the upstream provider.
- A saved mode no longer matches the selected model after a provider upgrade or deprecation.
- A tool or capability is accepted by one provider/model pair but rejected by another.
- A provider temporarily overloads a valid request immediately after onboarding or model selection.

Rules:

1. Rex must not commit a model or mode to session state or config until the selection passes validation.
2. If model validation fails, Rex must keep the previous working model/mode when available, or leave the current session unset if none existed.
3. If mode validation fails, Rex must keep the model and revert the mode to `default`.
4. If a rejection is discovered only at request time, Rex must classify it, invalidate the stale cached assumption, and retry only the minimal safe fallback such as `default` mode or no web-search tool.
5. If a failure is a transient provider-capacity condition such as `Overloaded`, `rate_limit`, HTTP `429`, HTTP `503`, or HTTP `529`, Rex must **not** treat it as an invalid model or mode selection. It must keep the validated selection unchanged.
6. Transient overload failures should trigger a small bounded retry of the exact same request with short backoff before showing an error. Retries should be silent unless they ultimately fail.
7. Error text must be concise, actionable, and calm. It should name the failing model or mode when relevant and tell the user what to do next.
8. Good messages look like: `Model openai/gpt-5.4 is not available for this credential. Choose another model.`, `Mode "Effort: Max" is not supported for claude-opus-4.6 on github. Using default.`, or `Anthropic is temporarily overloaded for claude-opus-4-6. Try again in a moment.`

## Data-Driven Mode Definitions

### modes.json

Model metadata is defined in a `modes.json` file that ships with the plugin. This file is the **single source of truth** for which models support which modes and for explicit per-model capability overrides such as web search. Modes and capability overrides are not hardcoded in the plugin code.

This design means:
- When a provider adds new modes (e.g., OpenAI's `xhigh` reasoning effort), the user updates `modes.json` — no plugin code change needed.
- When a model gains, loses, or rejects optional features such as web search, the user can record that in `modes.json` without touching request-building code.
- Users can add custom modes for new models as they become available.
- The plugin reads `modes.json` at startup and caches it.

#### File format

This spec intentionally does **not** embed a full `modes.json` snapshot. Model catalogs, reasoning controls, and provider-specific parameter names change too quickly, and a pasted JSON example becomes stale faster than the plugin design.

`modes.json` is still the runtime data source, but the file should be maintained from current provider metadata instead of copied from this document.

`modes.json` may be either:

- A legacy top-level array of pattern entries.
- A compact object with `mode_sets` and `models`, where model entries reference a shared mode set by name.

Compact format is preferred when multiple models reuse the same mode list.

Each model pattern entry should contain:

| Field        | Type        | Meaning |
|--------------|-------------|---------|
| `provider`   | string?     | Request transport/provider this pattern applies to, e.g. `anthropic`, `openai`, `github`, `xai`; omitted means wildcard for backward compatibility |
| `match`      | string      | Model ID or family fragment to match |
| `match_type` | string      | Matching strategy: `exact` or `contains` |
| `capabilities` | object?   | Optional explicit capability overrides for matching models |
| `capabilities.web_search` | boolean? | Model-level web-search support hint: `true` = supported by current docs/metadata, `false` = known unsupported or intentionally disabled, omitted = unknown |
| `modes`      | array?      | Ordered list of selectable modes for matching models |
| `mode_set`   | string?     | Name of a shared mode set from the top-level `mode_sets` object |
| `modes[].id` | string      | Stable internal identifier stored in config/state |
| `modes[].label` | string   | Human-readable popup label |
| `modes[].params` | object   | Request-body params merged when the mode is active |

Minimal example:

```json
{
  "mode_sets": {
    "anthropic_opus_4_6_effort": [
      {"id": "effort_medium", "label": "Effort: Medium", "params": {"output_config": {"effort": "medium"}}}
    ]
  },
  "models": [
    {
      "provider": "anthropic",
      "match": "claude-opus-4-6",
      "match_type": "contains",
      "capabilities": {"web_search": true},
      "mode_set": "anthropic_opus_4_6_effort"
    }
  ]
}
```

#### Mode maintenance rules

- Every model must implicitly support a `default` mode with no extra request params.
- `provider` should be present on new entries. Omitted `provider` is treated as a wildcard only for backward compatibility with older files.
- Prefer shared `mode_sets` when multiple provider/model entries use the same mode list.
- `capabilities.web_search = true` means the model family supports web search in current provider docs/metadata. Rex must still validate that the active API surface and tool variant can use it.
- `capabilities.web_search = false` means Rex must omit the web-search tool for matching models even if the provider family usually supports it.
- Omitting `capabilities.web_search` means support is unknown. Rex should treat unknown conservatively unless another trusted probe or endpoint-specific allowlist proves support.
- Detailed current model IDs, effort levels, capability flags, and other concrete settings belong in `modes.json`, not in this specification.
- GitHub-hosted models should usually reuse the same mode families as their upstream publishers, but must still be validated against the GitHub inference endpoint.
- This document is a reference for how to build `modes.json`, not a second source of truth.

#### Maintenance guidance

- Keep the detailed, current model catalog in `modes.json`, not in this spec.
- Build `modes.json` from current provider docs, live model discovery, and runtime validation where needed.
- Treat GitHub-hosted upstream models as provider-specific variants that may need the same mode families but separate validation.
- When provider docs and runtime behavior disagree, prefer the runtime-safe behavior and record the concrete result in `modes.json`.

#### Match types

- `"exact"` — model ID must equal the `match` string exactly (e.g., `"o3"` matches `o3` but not `o3-mini`)
- `"contains"` — model ID must contain the `match` string (e.g., `"claude-sonnet-4"` matches `claude-sonnet-4-20250514`)

#### Mode resolution

Mode resolution is provider-aware:

1. Rex first looks for entries whose `provider` matches the active request provider.
2. Within that provider slice, it iterates through patterns in order and uses the first match.
3. If no provider-specific entry matches, Rex may fall back to provider-less wildcard entries for backward compatibility.
4. If nothing matches, the model gets only the `default` mode (which is always implicitly available even if not specified).

Each mode entry has:
- `id` — internal identifier, stored in config/state
- `label` — human-readable label shown in the popup list
- `params` — table deep-merged into the API request body when this mode is active

## Architecture

### File Structure (Git Repository)

```
rex/
├ rex.lua               # Clink entrypoint: key binding, rl_buffer handling, slash-command dispatch, popup orchestration, onboarding flow
├ rex_state.lua         # Durable/session state, config I/O, recall-session files, modes.json + skills loading, effective-setting resolution
├ rex_turn.lua          # Turn-scoped helpers: context capture, prompt framing, shell-command protocol, response cleanup/output shaping
├ rex_provider.lua      # Credentials, provider registry, model discovery, HTTP transport, request execution, retry/error classification
├ json.lua              # Minimal JSON encoder/decoder (bundled)
├ modes.json            # Mode definitions (data-driven, not hardcoded)
├ rex_skills.md         # LLM system prompt: terminal rendering capabilities
├ spec.md               # This specification
```

The four implementation files must remain reasonably balanced in size. The split is not cosmetic; it exists so each file can be generated or regenerated in one homogeneous shot without crossing the practical reliability cliff that appears once a single file grows beyond roughly 1000 lines. In particular, `rex_state.lua` and `rex_turn.lua` should stay close enough in size that neither becomes the new catch-all file.

Responsibility split:

- `rex.lua` owns Clink-facing behavior only: `rex_submit`, key bindings, readline buffer management, popup-path decisions, slash-command dispatch, and onboarding orchestration.
- `rex_state.lua` owns durable and reusable runtime data concerns: the shared state table, config parsing/writing, recall-session file lifecycle, `modes.json` resolution, skills loading, capability lookup, and effective setting resolution.
- `rex_turn.lua` owns turn-scoped behavior: context capture, shell-authorization checks, shell-command parsing/execution helpers, prompt construction, ANSI rendering, markdown stripping, and response post-processing.
- `rex_provider.lua` owns provider-specific and transport logic: parsing credentials, provider metadata, model-list fetching, request-body assembly, HTTP calls, response extraction, retry policy, and request-time error classification.

Tie-break rule: if a helper primarily answers "what is currently configured or cached?", it belongs in `rex_state.lua`. If it primarily answers "how should this specific prompt/response turn be assembled, executed, or rendered?", it belongs in `rex_turn.lua`.

### Plugin Loading

The plugin is loaded by placing `rex.lua`, `rex_state.lua`, `rex_turn.lua`, `rex_provider.lua`, and `json.lua` into a directory that Clink scans for Lua scripts. Clink loads `rex.lua` as the entrypoint, and `rex.lua` loads the three sibling implementation files. Options:

1. **`clink installscripts <path>`** — registers `c:\repos\rex` as an additional scripts directory, so Clink loads `rex.lua` directly from the repo
2. **Clink profile scripts directory** — copy files to the path shown by `clink info`

No configuration of Clink itself is needed beyond having the script in a scanned directory.

### JSON Module Loading

The bundled `json.lua` must be loaded by **explicit path** using `dofile()`, not via `require("json")`. Clink environments commonly include other scripts (e.g., clink-completions) that ship their own `json.lua` with a different API surface. A bare `require("json")` resolves via `package.path` and may pick up the wrong module.

```lua
local script_dir = debug.getinfo(1, "S").source:match("@?(.+[\\/])")
local json = dofile(script_dir .. "json.lua")
```

Incorrect:

```lua
local json = require("json")   -- may resolve to clink-completions/modules/json.lua
```

This produces errors like:

```
clink-completions\modules\json.lua:783: JSON:decode must be called in method formatList
```

The clink-completions `json.lua` uses method syntax (`json:decode()`) while Rex's bundled module uses function syntax (`json.decode()`). Loading by explicit path avoids the collision entirely.

The same explicit-path rule applies to the internal split modules. `rex.lua` should load `rex_state.lua`, `rex_turn.lua`, and `rex_provider.lua` by sibling path so the four-file structure stays deterministic and self-contained:

```lua
local state_mod = dofile(script_dir .. "rex_state.lua")
local turn_mod = dofile(script_dir .. "rex_turn.lua")
local provider_mod = dofile(script_dir .. "rex_provider.lua")
```

Do not add a fifth miscellaneous implementation file. If one of the four files starts growing too large, rebalance responsibilities across the existing four files instead of creating an unbounded module tree. The preferred first move is to keep durable/session logic in `rex_state.lua` and turn-specific flow logic in `rex_turn.lua` rather than letting either file become a grab bag.

### Ctrl+Enter Key Binding

The plugin registers a Ctrl+Enter key binding via Clink's Lua key binding API:

```lua
function rex_submit(rl_buffer)
  local line = rl_buffer:getbuffer()
  local trimmed = line:match("^%s*(.-)%s*$")
  local is_popup_only = (trimmed == "/model") or (trimmed == "/mode") or (trimmed == "/memory")
  local needs_onboarding = (not resolve_model())

  if not is_popup_only and not needs_onboarding then
    rl_buffer:beginoutput()
    rl.invokecommand("add-history")
  elseif is_popup_only then
    -- Popup-only command: do not call beginoutput() before clink.popuplist().
    rl.invokecommand("add-history")
  else
    -- Onboarding from a normal prompt: keep rl_buffer intact, save the
    -- trimmed line separately, and defer both visible-output flushing and
    -- the session-scoped history append until the popup path finishes.
  end

  -- process line as Rex input...
end

-- Clink xterm modified-key format: modifier 5 = Ctrl, keycode 13 = Enter.
rl.setbinding([["\e[27;5;13~"]], [["luafunc:rex_submit"]])
-- CSI u encoding for terminals that send it natively.
rl.setbinding([["\e[13;5u"]], [["luafunc:rex_submit"]])
```

#### Global function requirement

The `rex_submit` function **must be global** (no `local` keyword). Clink's `luafunc:` binding mechanism resolves the function by name in the global Lua table at invocation time. A `local` function is invisible to this lookup and produces:

```
can't execute 'rex_submit'; not a function
```

Correct:

```lua
function rex_submit(rl_buffer)   -- global: visible to luafunc: binding
```

Incorrect:

```lua
local function rex_submit(rl_buffer)   -- local: Clink cannot find it
```

#### Key binding format

The **primary** binding is `\e[27;5;13~` — Clink's xterm modified-key format (modifier 5 = Ctrl, keycode 13 = Enter). This is what Clink generates internally from Win32 console input events. The CSI u encoding (`\e[13;5u`) is registered as a fallback for terminals that send it natively. Both bindings must be registered.

The binding should also be added to the Clink `default_inputrc` file for visibility alongside other key bindings:

```
"\e[27;5;13~": "luafunc:rex_submit"   # Ctrl-Enter sends input to Rex AI
```

#### Clink rl_buffer API

Clink's `rl_buffer` positions are **1-based** with **exclusive end** (Lua convention). Key methods:

- `rl_buffer:getbuffer()` — returns the current input line as a string
- `rl_buffer:getlength()` — returns the length of the input line
- `rl_buffer:remove(from, to)` — removes characters from position `from` up to but not including `to` (1-based)
- `rl_buffer:beginoutput()` — advances the output cursor past the input line so subsequent output appears below it

To clear the entire buffer: `rl_buffer:remove(1, rl_buffer:getlength() + 1)`.

#### Input preservation

The typed input must remain visible on screen after Ctrl+Enter whenever Rex eventually produces visible terminal output for that submitted line — exactly like a normal command that prints a result. This includes both the direct print path and the first-use onboarding path that ends by printing a configuration confirmation and then answering the original prompt.

Two Clink behaviors matter here:

- `rl.invokecommand("add-history")` appends the current buffer to shell history **and clears the edit line**.
- `rl_buffer:beginoutput()` advances the output cursor past the current input line so that line remains visible on screen.

Therefore:

- On immediate print paths, `beginoutput()` must happen **before** `add-history`.
- On deferred onboarding paths, `beginoutput()` must happen **before** the eventual `remove()`.

If the clear happens first, the input line is already gone when output begins, and the response appears detached from what the user typed.

Popup interaction adds a second constraint: `/model`, `/mode`, `/memory`, and onboarding selectors must not call `beginoutput()` before or during `clink.popuplist()`. Otherwise Clink redraws the cmd prompt and popup navigation reveals a phantom prompt line.

The rules are therefore:

1. **Print path** (LLM response, `/help`, `/settings`, `/context`, errors): call `beginoutput()` first, then `rl.invokecommand("add-history")`. `add-history` records the submitted line and clears the edit buffer in one step.
2. **Popup-only path** (`/model`, `/mode`, `/memory`): call `rl.invokecommand("add-history")` without `beginoutput()`. This records the slash command and clears the edit line without creating a phantom prompt before the popup.
3. **Popup-then-print path** (startup onboarding triggered by a normal prompt): do **not** call `beginoutput()` and do **not** call `add-history` before the popup, because `add-history` would clear the buffer too early. Keep the original line in `rl_buffer`, save the trimmed line separately, and after popup interaction finishes call deferred `beginoutput()` first, then `remove()`, then append the saved line via session-scoped `clink history -s`.

`rex_submit()` must determine the path **before** touching the buffer so it can choose the correct history and clearing strategy.

The function steps:
1. Reads the entire input line from `rl_buffer:getbuffer()`
2. Determines whether the flow is direct-print, popup-only, or popup-then-print
3. **Print path**: calls `rl_buffer:beginoutput()` to preserve the typed text, then calls `rl.invokecommand("add-history")` to append the line to shell history and clear the buffer
4. **Popup-only path**: calls `rl.invokecommand("add-history")` without `beginoutput()` before opening the popup
5. **Popup-then-print path**: leaves the buffer untouched during popup interaction, saves the trimmed line separately, then later calls deferred `beginoutput()` and `remove()` in that order immediately before the first visible print and appends the saved line via `clink history -s --session`
6. Processes the line (slash command dispatch, popup selection, or LLM request)
7. Returns — Clink shows the next cmd prompt

### Clink Lua Environment

Clink extends cmd.exe with a full Lua 5.2 environment. Unlike the WezTerm sandbox, there are **no restrictions**:

| Capability           | API                                      |
|----------------------|------------------------------------------|
| Run external commands| `io.popen()`, `os.execute()`             |
| File I/O (read+write)| `io.open()` — full read and write access|
| JSON parsing         | Bundled `json.lua` module                |
| Config parsing       | Simple key=value parser (no TOML library needed) |
| Environment variables| `os.getenv()`                            |
| Current directory    | `os.getenv("CD")` or `clink.get_cwd()`  |
| Terminal output      | `clink.print()` — supports ANSI escape codes |
| Popup selection      | `clink.popuplist(title, items)`          |
| Readline history     | `rl.invokecommand("add-history")`        |
| Session-scoped history fallback | `clink history -s` with `CLINK_EXE` + `clink.getsession()` |
| Key bindings         | `rl.setbinding()`, `luafunc:` prefix     |

### Data Flow

```
User types "explain this error" and presses Ctrl+Enter (model already configured)
  → Clink fires rex_submit(rl_buffer)
  → rl_buffer:getbuffer() returns "explain this error"
  → This is a print path (not a popup command, model is configured)
  → rl_buffer:beginoutput() preserves "explain this error" on screen
  → rl.invokecommand("add-history") appends the line to Clink history and clears the edit buffer
  → Append the accepted user entry to the current recall session file and flush immediately
  → Plugin captures context: cwd, git branch, terminal size
  → Plugin builds system prompt + API request
  → Plugin spawns: io.popen("curl ...") to provider API
  → Response arrives → clink.print(response) below the preserved input line
  → Append the assistant response to the same recall session file and flush immediately
  → Function returns, Clink shows next cmd prompt

User types "2+2" and presses Ctrl+Enter (first use, no model configured)
  → Clink fires rex_submit(rl_buffer)
  → rl_buffer:getbuffer() returns "2+2"
  → This is a popup-then-print path (no model → onboarding needed)
  → Do not call beginoutput() yet
  → Do not call add-history yet; it would clear the buffer too early
  → Keep the line in rl_buffer through onboarding and save the trimmed line separately for deferred history write
  → Append the accepted user entry to the current recall session file and flush immediately before later onboarding or request steps can fail
  → Onboarding: parse credentials → fetch models → popuplist → user picks model
  → Then: popuplist for mode selection (if modes available)
  → Popup navigation does not redraw the cmd prompt
  → Onboarding complete; Rex is about to print visible text
  → rl_buffer:beginoutput() preserves "2+2" on screen
  → rl_buffer:remove() clears the edit buffer for the next prompt
  → Saved line is appended to Clink history via session-scoped `clink history -s`
  → Print onboarding confirmation including selected model, provider, and resolved mode
  → Fall through to process the original prompt "2+2"
  → Send "2+2" to LLM
  → If the provider is temporarily overloaded, retry the same request with short backoff
  → Print the final response or a concise transient-capacity error below the preserved input line
  → Append the assistant-side outcome to the same recall session file and flush immediately
  → Function returns, Clink shows next cmd prompt

User types "explain this error" and presses Enter
  → cmd.exe tries to execute "explain this error" as a command
  → Rex is not involved at all

User types "/model" and presses Ctrl+Enter
  → rex_submit fires, sees "/" prefix
  → This is a popup path (/model)
  → rl.invokecommand("add-history") records "/model" and clears the edit buffer (no beginoutput)
  → Opens clink.popuplist() with model list
  → Arrow-key navigation does not redraw the cmd prompt
  → On selection: beginoutput() is called immediately before printing the confirmation
  → On Escape: Rex prints `Cancelled.` (or similarly short feedback) and returns cleanly

User types "/model" and presses Enter
  → cmd.exe tries to execute "/model" as a command
  → Rex is not involved at all
```

## State Management

The plugin maintains module-level state with the following fields:

| Field        | Type          | Description                                                           |
|--------------|---------------|-----------------------------------------------------------------------|
| `credential` | string or nil | Currently selected credential ID (nil = resolve from config/default) |
| `provider`   | string or nil | Currently selected provider (nil = derive from selected credential)   |
| `model`      | string or nil | Currently selected model (nil = use config/default)                   |
| `mode`       | string or nil | Currently selected mode (nil = use config/default)                    |
| `memory`     | string or nil | Currently selected conversation-memory policy (nil = use config/default) |
| `history`    | list          | Conversation message history for this session                         |
| `session_path` | string or nil | Path of the current durable recall session file                     |
| `session_date` | string or nil | Session file date stamp in `YYYYMMDD` form                          |
| `session_index` | integer or nil | Daily 1-based recall-session index for this Rex instance         |
| `credentials` | list or nil   | Parsed credential entries from `REX_API_KEY`                          |
| `models`     | table or nil  | Cached model lists keyed by credential ID                             |
| `config`     | table or nil  | Parsed config file contents                                           |
| `modes_data` | table or nil  | Parsed modes.json contents                                            |

State is not per-window (cmd.exe has one session). State is not persisted across cmd.exe restarts — it lives in the Clink Lua process.
These durable/session fields belong in `rex_state.lua`. Turn-local helpers in `rex_turn.lua` may read them, but `rex_turn.lua` must not become a second config/state module.
Important distinction: `credentials` is only a derived cache of the current `REX_API_KEY` environment variable, not an independent source of truth. A `nil`, empty, or stale in-memory `credentials` cache must never be interpreted as proof that no API key exists in the live shell environment.

### Recall Session File

Every Rex instance owns exactly one durable recall session file for its lifetime.

Lifecycle:

1. For each Clink start that results in one live Rex instance, Rex must allocate exactly one durable recall session file for that instance.
2. The file name must be:
   - `session_<DATE>_<INDEX>`
3. `DATE` is the local calendar date associated with that Rex instance's startup in `YYYYMMDD` format.
4. `INDEX` is a three-digit zero-padded integer starting at `001` for the first Rex instance allocated on that date and increasing by one for each later Rex instance allocated on the same date.
5. Each fresh Rex instance must get a new file with the next available `INDEX`. It must not append to a previous Rex instance's file just because the date matches.
6. The session file chosen for that Rex instance remains the durable transcript for that instance even if the clock later crosses midnight.
7. Startup-time duplicate loads, speculative initialization, abandoned startup paths, or other non-owning activity must not consume an extra recall-session index.
8. Rex may allocate the session file lazily at the first durably persisted Rex event, but if it allocates earlier it must still reuse that same file for the lifetime of the instance.
9. It is invalid to create an empty placeholder recall file for one startup and then write the real transcript to a second file with the next index.

Examples:

- `session_20260329_001`
- `session_20260329_002`
- `session_20260330_001`

Persistence rules:

- The session file is append-only for the lifetime of the Rex instance.
- The one session file allocated for a Rex instance is the same file that receives that instance's first persisted record and all later records for that instance.
- As soon as a non-empty user prompt is accepted as the current Rex request, Rex must append the user entry to the session file and flush immediately so the prompt is durably persisted before the later network call, popup completion, or answer generation can fail.
- As soon as the assistant-side outcome for that turn is available, Rex must append it to the same session file and flush immediately.
- Assistant-side outcomes include normal model answers, shell transcripts, concise error results, and concise cancellation results for turns that had already been accepted and durably logged as user requests.
- There is no user-facing clear-history command. The durable recall session file remains append-only, and `/memory` changes only what prior conversation is included in future API requests.
- The durable recall session file is distinct from Clink shell history. Shell history stores submitted command lines for Up-arrow recall; the recall session file stores the Rex conversation transcript for later inspection.

Record-shape requirements:

- The on-disk session file format must be append-friendly and self-delimiting so earlier records remain readable even if the process stops between later writes.
- Each appended record must identify at least the record role or kind (`user`, `assistant`, `shell`, `error`, or `cancel`) and the associated text payload.
- The exact encoding may be plain text or another simple append-only text format, but it must preserve multi-line prompts and multi-line answers without ambiguity.

## Dynamic Model Discovery

### Model Listing API

When the user invokes `/model` (or on first Ctrl+Enter if no model is set), the plugin fetches the current list of available models from each configured credential's model-listing endpoint:

| Provider   | Endpoint                                         | Auth header                |
|------------|--------------------------------------------------|----------------------------|
| Anthropic  | `GET https://api.anthropic.com/v1/models`        | `x-api-key: <key>`        |
| OpenAI     | `GET https://api.openai.com/v1/models`           | `Authorization: Bearer <key>` |
| GitHub     | `GET https://models.github.ai/catalog/models`    | `Authorization: Bearer <token>`, `Accept: application/vnd.github+json`, `X-GitHub-Api-Version: 2026-03-10` |
| Groq       | `GET https://api.groq.com/openai/v1/models`      | `Authorization: Bearer <key>` |
| xAI        | `GET https://api.x.ai/v1/models`                | `Authorization: Bearer <key>` |

### Response Format

- Anthropic, OpenAI, Groq, and xAI return a JSON response containing a `data` array. Each element has at minimum an `id` field.
- GitHub returns a top-level JSON array. Each element includes `id`, `name`, `publisher`, `supported_input_modalities`, `supported_output_modalities`, and other catalog metadata.

### Model Filtering

Each provider has a filter function that determines which models to show in the selector:

- **Anthropic**: Include models whose `id` starts with `claude-`
- **OpenAI**: Include models whose `id` starts with `gpt-` or `o`
- **GitHub**: Include catalog entries that support text input and text output and are usable for chat inference. Show the full catalog ID such as `openai/gpt-5.4` or `anthropic/claude-sonnet-4.6`.
- **Groq**: Include all models (no filter)
- **xAI**: Include models whose `id` starts with `grok-`

### Caching

Each credential's model list is fetched once per cmd.exe session and cached separately. The cache is invalidated when:

- The cmd.exe session ends (Clink Lua state is reset)
- The parsed `REX_API_KEY` credential set changes
- A credential changes (via config re-read, onboarding, or `/model`)

### Error Handling

If model fetching fails for one credential (network error, auth error, malformed response), the plugin:

1. Records the failure against that credential.
2. Continues loading models from the remaining credentials.
3. Shows usable models from any credential that succeeded.
4. Falls back to the model specified in the config file, if any.
5. If every credential fails and no config model is set, prints an error and does not proceed.
6. If a cached or configured model later proves unavailable for that credential, Rex must invalidate the stale assumption, keep the last known-good validated selection if one exists, and guide the user toward `/model` instead of repeatedly retrying the broken choice.

## API Keys & Provider Detection

### Environment variable: `REX_API_KEY`

Credentials are read from `$REX_API_KEY`. No config file, no other source.

`REX_API_KEY` is the authority. Any parsed in-memory credential list is just a cache derived from that environment variable.

`REX_API_KEY` may contain one or more comma-separated entries. Whitespace around commas is ignored.

Supported entry forms:

- `<raw-key>` — legacy form; provider is auto-detected when possible
- `<provider>:<key>` — recommended for multi-provider setups
- `<label>=<provider>:<key>` — recommended when multiple credentials are configured; `label` becomes the stable credential ID stored in config

Examples:

```text
REX_API_KEY=sk-ant-...,sk-...,xai-...
REX_API_KEY=anthropic:sk-ant-...,openai:sk-...,github:ghp_...
REX_API_KEY=work-openai=openai:sk-...,github-main=github:ghp_...,lab-xai=xai:xai-...
```

### Auto-detection by key pattern

| Entry prefix or provider tag | Provider   | API base URL                        |
|-----------------------------|------------|-------------------------------------|
| `anthropic:` or `sk-ant-`   | Anthropic  | `https://api.anthropic.com`         |
| `openai:` or `sk-` (other)  | OpenAI     | `https://api.openai.com`            |
| `github:`                   | GitHub Copilot / GitHub Models | `https://models.github.ai` |
| `groq:` or `gsk_`           | Groq       | `https://api.groq.com/openai`       |
| `xai:` or `xai-`            | xAI        | `https://api.x.ai`                  |

GitHub credentials should be supplied with an explicit `github:` provider tag whenever possible. GitHub token formats vary, so provider-tagged entries are more reliable than shape-based guessing.

The `provider` key in the config file records which provider the currently selected model belongs to. It is **not** a filter — `/model` and onboarding always show the full merged model list from all configured credentials regardless of the `provider` value. The `provider` is derived automatically when a model is selected; its primary use is for request routing (choosing the correct API endpoint and auth headers).

If an entry cannot be mapped to a provider, it is skipped and a plain-text warning is printed.

### Credential Lifecycle And Request-Time Resolution

Credential resolution must work on every path that needs it, not only on onboarding or `/model`.

Rules:

1. Any code path that needs credentials, including a normal LLM request send, must ensure the current `REX_API_KEY` value has been parsed before concluding that no valid credential exists.
2. A previously saved config `{credential, provider, model}` tuple does not remove the need to resolve credentials from the live environment at request time.
3. If the in-memory parsed-credential cache is nil, empty, or potentially stale, Rex must refresh it from `REX_API_KEY` before failing the request for missing credentials.
4. If the configured credential label is absent from the newly parsed environment set, Rex may fall back per the normal resolution rules, but it must not report the situation as if no key existed at all when `REX_API_KEY` is present.
5. If `REX_API_KEY` is present but the configured credential label no longer exists inside it, the visible error should say what is wrong, for example: `Configured credential "work-openai" is not present in current REX_API_KEY. Use /model or update REX_API_KEY.`
6. A generic message such as `No valid credential found.` is only acceptable after Rex has actually checked the live `REX_API_KEY` value for the current session and determined that no usable credential can be parsed from it.

Acceptance tests:

- Fresh session, valid config, valid `REX_API_KEY`, no `/model` interaction yet: the first normal prompt must send successfully without requiring onboarding or model reselection.
- Fresh session, valid config, valid `REX_API_KEY`, empty in-memory credential cache: the first normal prompt must re-parse credentials automatically rather than failing with a generic no-credential error.
- Existing session where `REX_API_KEY` was added or changed after startup: the next credential-dependent action must observe the new environment value before concluding that credentials are missing.

## LLM Integration

### Provider & Model Resolution

1. Determine credential: session state (from `/model`) → config file `credential` key → first configured credential that exposes the selected model → first valid credential in scope.
2. Determine provider: session state → config file `provider` key → provider of the selected credential.
3. Determine model: session state (from `/model`) → config file `model` key → first model exposed by the selected credential or merged selector.
4. Determine mode: session state (from `/mode`) → config file `mode` key → `"default"`.
5. Determine memory: session state (from `/memory`) → config file `memory` key → `"all"`.

Credential resolution is request-critical and must be backed by the live environment, not only by prior onboarding side effects. A normal prompt in a fresh Rex session must be able to trigger credential parsing on demand.

### System Prompt Composition

The system prompt sent to the LLM is composed of five parts, concatenated in order:

1. **Base instruction**: A concise persona statement — Rex is a terminal AI assistant. Be concise, lead with the answer, and never wrap the whole response in markdown fences or a decorative box.
2. **Turn-framing block**: A short instruction that says earlier conversation is background only, the newest user message is the request to answer now, and earlier topics must not be continued unless the newest turn explicitly refers to them.
3. **Shell-capability block**: A short host instruction that says Rex can execute one shell command when the newest user message explicitly asks for shell activity. This block must not introduce a user-facing "shell execution is not allowed for this turn" mode or denial phrasing.
4. **Skills block**: The full contents of `rex_skills.md`, read from the plugin directory.
5. **Context block**: The captured terminal context (cwd, git info, terminal dimensions). This block contains environment facts only, not prior conversation content.

### Turn Boundary Framing

Every request must make the distinction between **previous conversation** and the **current user turn** explicit. Raw chronological history alone is not sufficient; the request must also tell the model how to interpret that history.

Rex must therefore provide stable framing that means:

- Earlier turns are background context and may be irrelevant to the newest request.
- The newest user message is the active task to answer now.
- Earlier topics should be carried forward only when the newest user message clearly depends on them, for example `above`, `continue`, `same units`, `same file`, `again`, or another explicit reference.
- If the newest turn is independent, Rex should prefer a focused answer over a "combined" answer that revisits stale topics.

The framing may live in the system prompt, in a synthetic boundary message, or in a wrapper around the newest user message, but the wire format must make the boundary unambiguous.

Minimal acceptable framing for the newest turn:

```text
Current request (answer this now):
<user prompt>

Previous conversation in this request is background only.
Use it only if the current request clearly depends on it.
```

### Conversation History

- Maintained as an ordered list of `{role, content}` message pairs.
- Stored for the full Rex session.
- Persisted durably to the current recall session file as turns become available; user entries are written and flushed immediately when accepted, and assistant-side outcomes are written and flushed immediately when available.
- The full stored history is not always sent over the wire; the effective `memory` setting selects how much trailing history is included in each API request.
- Stored history remains raw, but the request sent over the wire must distinguish earlier turns from the newest turn.
- The newest user prompt must always be the final user message in the request and must not be merged into a summary blob that hides the turn boundary.
- There is no user-facing clear-history command; request-time inclusion is controlled by `/memory`.
- Persists across Ctrl+Enter presses within the same cmd.exe session.

Request-time history assembly rules:

1. Determine the effective memory setting using the normal precedence rules: session state (`/memory`) → config file `memory` → built-in default `all`.
2. Select prior stored conversation according to that effective memory setting.
3. Append the framed current user prompt as the final user message after the selected prior history.
4. Do not let `memory=none` suppress the current prompt itself; it suppresses only earlier stored conversation.
5. Do not mutate or delete stored history when applying the memory window. The window is a request-assembly choice, not a data-loss operation.

Conversation history, durable recall transcripts, and shell history are different things. Rex's conversation history stores user/assistant turns in memory for the LLM. The recall session file stores the durable append-only transcript for later inspection across failures. Clink shell history stores the literal submitted cmd lines for recall with the Up arrow. Rex must keep all three behaviors correct at the same time.

### Explicit Shell Command Execution

Rex may execute a shell command only when the current user turn explicitly asks Rex to perform shell activity, for example `run git status`, `check with the shell`, or `inspect the repo yourself`. Shell execution is opt-in per turn, not a general background capability.

There is no separate user-facing "shell-forbidden turn" mode. If the newest user message is an explicit shell request, the assistant may return the shell-command protocol. If it is not a shell request, Rex answers normally and does not execute assistant-generated command text.

Shell execution in this feature means **main-session shell execution**, not detached helper-shell execution. Unless the user explicitly asks for isolated execution, Rex must execute the requested command so that shell-visible side effects persist in the interactive cmd.exe/Clink session exactly as if the user had typed the command at the normal prompt. Commands whose purpose is to mutate session state, such as `cd`, `chdir`, `pushd`, `popd`, `set NAME=value`, or `set NAME=`, must affect the next prompt and later normal Enter-submitted commands.

For commands that are intended to mutate the current session state:

- `shell=cmd` is the default and expected shell.
- The ambient interactive shell in this product is `cmd.exe` under Clink. Unless the user explicitly asks for PowerShell, or the task explicitly requires PowerShell syntax/semantics, Rex must emit `shell=cmd` and a cmd-native command body.
- `shell=powershell` is opt-in, not a fallback. Rex must not spontaneously switch shells just because a PowerShell command happens to look convenient.
- Rex must not satisfy the request only by running the command in a detached `cmd /c`, `powershell -Command`, temp-script child process, or any other helper context whose shell state disappears when that child exits.
- Capturing stdout/stderr alone is not sufficient. If the command was meant to change cwd, current drive, environment variables, drive stack, or other live shell state, those effects must be visible in the main session before the next prompt is shown.

If the newest user message does not explicitly ask for shell activity:

- Rex must not execute any assistant-generated command.
- Any text that merely resembles the shell-command protocol is treated as normal assistant output.

This first version supports **at most one executed shell command per Ctrl+Enter turn**. After that command completes, Rex prints the executed command and captured output as the visible result for that turn. There is no second model pass and no follow-up shell-command block.

#### Cmd command design guidance

For `shell=cmd`, Rex should bias toward the simplest idiomatic command shape that is likely to work correctly on the first try.

Rules:

- Prefer a short direct interactive cmd command when the job fits naturally in one obvious line.
- If the task needs loop variables, counters, delayed expansion, multiple passes over a file, or would otherwise become a quote-heavy `&`-chained one-liner, prefer generating a short temp `.cmd` script and then `call`ing it.
- Treat user-supplied repair hints from failed attempts as hard constraints for the next attempt. If the user says the last attempt broke because of fragile quoting, indexing, `%`/`%%`, or an unwanted PowerShell fallback, the next command must respond to those constraints directly instead of reintroducing them.
- The `%` versus `%%` rule is context-sensitive, not global:
  - Direct interactive `cmd.exe` command text uses single-percent loop variables such as `%a`.
  - Lines written into a generated `.cmd` or `.bat` file use doubled loop variables such as `%%a`.
- A generated temp batch script is acceptable and often preferred for non-trivial pure-cmd work. `%%a` inside that generated script is correct batch syntax, not evidence that the command is brittle by itself.
- For slightly stateful pure-cmd tasks such as line counting, tail-like output, or two-pass file processing, a short `%TEMP%` batch script with `setlocal`, counters, and `%%a` loop variables is more idiomatic than a giant interactive one-liner.
- Keep temp scripts purpose-built and short. Favor readable sequential lines over dense interactive metaprogramming.

#### Shell-command return protocol

When the assistant wants Rex to execute a command for a shell-request turn, it must return exactly one machine-readable block in this format:

```text
<<<REX_SHELL_COMMAND>>>
shell=cmd
cwd=.
timeout_sec=30

git status --short
<<<END_REX_SHELL_COMMAND>>>
```

Rules:

- `<<<REX_SHELL_COMMAND>>>` and `<<<END_REX_SHELL_COMMAND>>>` are exact ASCII sentinels.
- Header lines are `key=value`.
- A blank line separates headers from the command body.
- `shell` is required. Allowed values are `cmd` and `powershell`.
- `cwd` is optional. `.` means the current shell working directory. If omitted, Rex uses the current shell working directory.
- `timeout_sec` is optional. If omitted, Rex uses the normal request-timeout-derived default for shell execution.
- The command body is literal shell text. It may span multiple lines.
- Rex must treat the first well-formed block as authoritative and ignore any additional blocks.

#### Retrieval and execution

Rex must inspect the raw assistant text for the shell-command protocol **before** markdown stripping, ANSI rendering, or visible printing.

When a well-formed block is present on a shell-request turn:

1. Rex extracts the block and does not print the raw protocol block to the terminal.
2. Rex executes the command in the requested shell and working directory, with the intended effect applied to the live interactive shell session rather than a detached helper shell.
3. Rex captures the exact command text, exit code, combined stdout/stderr, and the command's final working directory.
4. Session-visible shell effects must persist into the main session before the next prompt is shown. For `shell=cmd`, this includes at least current directory, current drive, and environment-variable changes from `set`/`set NAME=`.
5. Rex prints the executed command and its captured output as a plain, unboxed shell transcript. This visible transcript is Rex-rendered terminal output derived from the executed command and captured shell result; it is not a second assistant answer.
6. If the command succeeds with no stdout/stderr, Rex must still print the command plus one short visible completion line such as `Command completed.` or a brief summary of the produced side effect.
7. The turn ends after that transcript is printed. Rex does not send the shell output back to the model for interpretation, summarization, or a second answer within that same turn.

Acceptance tests:

- After an explicit shell-request turn `change cwd to home`, the next prompt starts in the home directory and a following normal Enter-submitted `cd` prints that same home directory.
- After an explicit shell-request turn `set REX_TEST_VAR=hello`, a following normal Enter-submitted `echo %REX_TEST_VAR%` prints `hello`.
- After an explicit shell-request turn whose command is side-effect-only and whose stdout/stderr is empty, Rex still prints a visible completion line instead of returning silently to the prompt.
- A design that prints `> cd /d "C:\Users\H"` but leaves the next prompt in the old directory is incorrect, even if the command appeared to run without error.

Failure handling:

- If the block is malformed, Rex must not execute it, and it must print a concise visible error instead of falling through silently.
- If command launch fails, times out, or exits non-zero, Rex must still capture and print that fact instead of crashing or returning silently.
- Shell-command blocks are host-side Rex protocol, not provider-native tool calls. They must work the same way across Anthropic, OpenAI, GitHub, Groq, and xAI transports.

### Visible Completion Requirement

Once Rex consumes a non-empty Ctrl+Enter submission, it must always leave the user with visible feedback before the next prompt appears.

Allowed outcomes are:

- A normal assistant answer.
- A shell transcript.
- A confirmation such as model or mode change.
- A short cancellation line after popup cancellation or aborted onboarding.
- A concise error.

Disallowed outcomes are:

- Returning to the prompt with no visible output after Rex already consumed the line.
- Dropping malformed shell-command blocks, empty assistant responses, popup cancellations, or side-effect-only shell commands without any visible text.

### API Request Format

#### Anthropic

- **Endpoint**: `POST https://api.anthropic.com/v1/messages`
- **Auth headers**: `x-api-key: <key>`, `anthropic-version: 2023-06-01`
- **Body**: `{ model, max_tokens, system: <system_prompt>, messages: [...], tools?: [...] }`
- **Response path**: `response.content[].text` (concatenate all text blocks)
- **Extraction rule**: a provider-level "missing content" error is valid only after Rex inspects the parsed successful response shape and confirms that it contains no usable assistant text in the provider's native content fields. Rex must distinguish between truly missing content, an unexpected successful payload shape, and content that later becomes empty only because of host-side post-processing.

#### OpenAI

- **Endpoint**: `POST https://api.openai.com/v1/chat/completions`
- **Auth header**: `Authorization: Bearer <key>`
- **Body**: `{ model, max_tokens, messages: [{role: "system", content: <system_prompt>}, ...], tools?: [...] }`
- **Response path**: `response.choices[0].message.content`

#### GitHub Copilot / GitHub Models

- **Endpoint**: `POST https://models.github.ai/inference/chat/completions`
- **Auth headers**: `Authorization: Bearer <token>`, `Accept: application/vnd.github+json`, `X-GitHub-Api-Version: 2026-03-10`
- **Body**: `{ model: "<publisher>/<model_name>", max_tokens, messages: [{role: "system", content: <system_prompt>}, ...] }`
- **Response path**: `response.choices[0].message.content`
- **Notes**:
  - The public GitHub inference API is the transport surface Rex uses for GitHub-hosted Copilot/Models access.
  - GitHub model IDs are fully qualified, for example `openai/gpt-5.4`, `anthropic/claude-sonnet-4.6`, or `google/gemini-3.1-pro`.

#### Groq / xAI (OpenAI-compatible, no web search)

- **Endpoint**: `POST <base_url>/v1/chat/completions`
- **Auth header**: `Authorization: Bearer <key>`
- **Body**: `{ model, max_tokens, messages: [{role: "system", content: <system_prompt>}, ...] }`
- **Response path**: `response.choices[0].message.content`

#### Web Search

Web search is a **model capability**, not just a provider capability. Rex must be conservative: if model-level support cannot be established, it must omit the web-search tool rather than gambling on provider-level support.

The decision process is:

1. Start with web search disabled.
2. Check the matching `modes.json` entry for `capabilities.web_search`.
3. If `capabilities.web_search` is explicitly `false`, omit the tool.
4. If `capabilities.web_search` is explicitly `true`, continue.
5. Check whether the active endpoint family supports a web-search tool format at all.
6. Check whether the selected model on that endpoint is known or proven to accept that tool type.
7. Add the tool only when both checks succeed. Otherwise omit the `tools` field entirely.
8. If the API returns an unsupported-tool validation error, remember that `{provider, credential, model}` combination as web-search-disabled for the session and retry once without the tool.

Allowed tool shapes by endpoint family:

| Endpoint family | Tool definition if the selected model supports search |
|-----------------|-------------------------------------------------------|
| Anthropic       | `{type: "web_search_20250305", name: "web_search"}`   |
| OpenAI          | `{type: "web_search_preview"}`                         |
| GitHub / Groq / xAI | Not supported — no tools field sent              |

Important rules:

- The table above is an upper bound by endpoint family, not a blanket permission for every model on that endpoint.
- `modes.json` is the preferred place to record explicit per-model web-search support or rejection.
- `capabilities.web_search = true` in `modes.json` is not, by itself, sufficient to attach a tool. Rex must still validate the active endpoint/API surface and exact tool format.
- Older or cheaper models on a search-capable endpoint may still reject the search tool.
- If provider metadata does not expose a reliable search-capability field, Rex should use a curated allow/deny rule or a runtime probe, and should default to **no web search** when uncertain.
- GitHub-hosted upstream models do not automatically inherit upstream web-search support. Unless GitHub explicitly documents and accepts a search tool for that endpoint, Rex must omit it.

The Anthropic tool definition **requires** both `type` and `name` fields. Omitting `name` produces a validation error.

#### Mode Parameter Merging

When the active mode is not `"default"`, the mode's `params` map (from `modes.json`) is deep-merged into the request body before sending.

GitHub's public catalog and inference docs currently document model IDs, modalities, generic sampling controls, and tool/function fields, but they do **not** document a first-class reasoning-capability field. For GitHub-hosted OpenAI, Anthropic, and Google models, Rex must therefore derive candidate reasoning modes from the underlying family and validate them against the GitHub inference endpoint. If GitHub rejects a mode-specific param for a given model, Rex must treat that mode as unsupported for that GitHub model/credential pair and fall back to `default`.

### HTTP Transport

HTTP requests are made by spawning `curl` via `io.popen()`. The plugin:

1. Writes the JSON request body to a temp file (`%TEMP%\rex_*.json`) to avoid shell-escaping issues on Windows.
2. Constructs the `curl` command with URL, headers, method, and `-d @<tempfile>`.
3. Reads the response from the pipe.
4. Deletes the temp file.
5. Parses the JSON response using the bundled `json.lua` module.
6. Extracts the response text and prints it.

A timeout (configurable, default 120s) is enforced via `curl --max-time`. The temp file approach is essential — constructing the JSON body inline in a `cmd.exe` command string would require escaping double quotes, backslashes, and special characters, which is fragile and error-prone.

The temp-file naming step is part of the transport contract, not a throwaway implementation detail. Rex may use clocks, random numbers, counters, or similar entropy to make `%TEMP%\rex_*.json` unique, but any non-string value must be converted explicitly before string-only operations are applied. Temp-file construction must not fail with a host-side Lua type error before `curl` starts.

Acceptance test: a normal prompt and an explicit shell request such as `list all files in this directory larger than 5kB` must both be able to reach `curl` invocation without crashing during temp-file path construction.

### Error Handling

All error conditions produce a plain-text error message:

- Missing or unrecognized API key
- Network / timeout failures
- HTTP error responses (4xx, 5xx)
- Malformed JSON responses
- Missing response content
- Unsupported model / mode / tool combinations
- Transient provider-capacity failures such as `Overloaded`, `rate_limit`, `429`, `503`, or `529`

Response-extraction rules:

- A provider-level "missing response content" error is valid only when the parsed successful provider response truly lacks usable assistant text in that provider's documented response fields.
- Rex must not report provider-level "missing content" merely because the response shape was unexpected but parseable; that case should produce a more specific extraction or protocol-shape error.
- Host-side post-processing such as shell-command stripping, markdown-fence stripping, ANSI conversion, or other output cleanup must never be reclassified as a provider-level "missing content" failure. If Rex locally strips a non-empty response down to empty, it must surface a local empty-output fallback or a specific post-processing error instead of blaming the provider for returning no content.

Unsupported selection errors must be handled gracefully:

- If the failure is mode-specific, Rex should fall back to `default` when that is safe and print a hint instead of stopping the whole flow.
- If the failure is model-specific, Rex should leave the last known-good validated model unchanged, avoid persisting the invalid choice, and tell the user to choose another model.
- During onboarding or popup-driven selection, Rex should prefer a helpful recovery path over a hard abort: print the hint, then let the user reselect or cancel.

Transient provider-capacity failures must be handled differently from invalid selections:

- They do **not** invalidate the chosen credential, provider, model, or mode.
- Rex should retry the same request a small bounded number of times with short backoff before surfacing the error.
- The retry policy applies to the very first request after onboarding as well as later turns.
- If retries still fail, Rex should print a short message such as `Anthropic is temporarily overloaded for claude-opus-4-6. Try again in a moment.` instead of making the selection look broken.

After displaying the error, control returns to the cmd prompt.

## Context Capture

The following context is captured and included in the system prompt:

| Context            | Source                                   |
|--------------------|------------------------------------------|
| Working directory  | `os.getenv("CD")` or `clink.get_cwd()`  |
| Terminal size      | `os.getenv("COLUMNS")`, `os.getenv("LINES")` |
| Git branch         | `io.popen("git rev-parse --abbrev-ref HEAD")` |

Note: Scrollback capture is not available — cmd.exe does not expose scrollback to Lua scripts.

## Invisible Operation

Rex must avoid adding persistent terminal chrome of its own. There should be no separate Rex UI layer beyond the visible result of the current turn. Specifically:

- **No screen clearing** — Rex never clears, resets, or redraws the terminal.
- **No prompt modification** — the cmd prompt is never altered or decorated.
- **No dedicated Rex indicators** — no thinking animations, no branded banners, no status widgets, and no always-on styled prefixes are printed. User-visible output may still contain ordinary answer formatting, including ANSI color and text styling, when that formatting is part of the response or terminal-friendly command output.
- **No phantom prompts during popups** — interacting with `clink.popuplist()` (arrow keys, filtering, Enter, Escape) must not reveal a duplicate, blank, or partially redrawn cmd prompt line above the popup.
- **No terminal state changes outside normal output** — Rex must not clear scrollback, repaint the screen, or leave behind stray UI state unrelated to the visible output of the current turn.
- **ANSI rendering is allowed** — ANSI escape sequences used for ordinary terminal formatting are part of the supported output surface. ANSI-colored or styled output is not a specification violation when it improves readability or expresses the intended shell or answer formatting.

The only persistent Rex behavior observable is: pressing Ctrl+Enter either produces output instead of executing the typed text as a command, or opens a popup selector. When a submitted line ultimately leads to visible output for that same line, including first-run onboarding followed by the deferred answer, the typed input remains visible on screen and the next prompt starts empty. For popup-only commands, the popup appears without any extra prompt line being drawn.

## Output

Responses are printed via `clink.print()`. Rex does not add any wrapper, prefix, suffix, or decoration around the LLM's response. The LLM is instructed (via `rex_skills.md`) to format its responses using the terminal's capabilities.

### No Decorative Boxes

Answers must not be wrapped in a decorative border or response box. This includes rounded-corner boxes, double-line panels, full-width bordered callouts, and any similar outer container around the answer.

Allowed:

- Plain paragraphs
- Simple bullet lists
- Borderless tables that use spacing and horizontal rules only
- Small diagrams where box-drawing characters are intrinsic to the diagram the user explicitly asked for

Not allowed as default answer layout:

- `╭ ... ╮` / `╰ ... ╯` wrappers around the whole answer
- Single-result cards
- Boxed command suggestions
- Boxed math display used only for decoration

`rex_skills.md` examples that suggest generic response boxes are non-normative and must not override this rule.

### ANSI Escape Rendering

LLMs cannot emit raw ESC bytes (0x1B) in text responses. Instead, `rex_skills.md` instructs them to use `\e[` notation (e.g., `\e[1;34m` for bold blue). Before printing, Rex converts these literal strings to real ANSI escape sequences via a `render_ansi()` function that handles all common notations:

| Notation      | Example             | Converted to      |
|---------------|---------------------|--------------------|
| `\e[`         | `\e[1;34m`          | `ESC[1;34m`        |
| `\033[`       | `\033[1;34m`        | `ESC[1;34m`        |
| `\x1b[`       | `\x1b[1;34m`        | `ESC[1;34m`        |

### Markdown Stripping

Despite system prompt instructions to avoid markdown, LLMs sometimes wrap responses in code fences (`` ```ansi ``, `` ```text ``, bare `` ``` ``). Rex strips leading and trailing code fences from the response before printing. This is a safety net — the system prompt is the primary defense.

### System Prompt Anti-Markdown Directive

The base instruction in the system prompt must explicitly state that output is printed raw via `clink.print()` and must never be wrapped in markdown code fences, backticks, decorative response boxes, or any other outer formatting container. The LLM must use `\e[` notation for ANSI sequences.

## Tech Stack

| Component        | Technology                              |
|------------------|-----------------------------------------|
| Plugin runtime   | Clink (cmd.exe Lua scripting, Lua 5.2)  |
| Plugin files     | `rex.lua`, `rex_state.lua`, `rex_turn.lua`, `rex_provider.lua` — balanced four-file split |
| JSON module      | Bundled `json.lua` — minimal encoder/decoder |
| Mode definitions | `modes.json` — data-driven, not hardcoded |
| Config format    | Simple key=value with `#` comments      |
| HTTP             | `curl` via `io.popen()`                 |
| Terminal output  | `clink.print()` — supports ANSI escape codes |
| Popup selection  | `clink.popuplist()`                     |
| Key binding      | `rl.setbinding()` — Ctrl+Enter → `luafunc:rex_submit` |
| Skill definitions| Markdown (`rex_skills.md`)              |
| Provider APIs    | Anthropic, OpenAI, GitHub Models/Copilot, Groq, xAI (REST)    |

## Startup Onboarding

When Rex is first invoked (first Ctrl+Enter press) and cannot resolve a valid credential/model selection (because the config file is missing, is unparseable, or does not specify a usable `credential` / `model` pair), it runs an interactive onboarding sequence:

1. **Parse credentials** — split `$REX_API_KEY` on commas, trim whitespace, resolve provider tags or auto-detect providers, and assign each entry a stable credential ID. If no valid credentials remain, print an error and abort.
2. **Fetch models** — call each in-scope credential's model-listing API. If one credential fails, continue with the rest. If every credential fails, print an error and abort.
3. **Prompt model selection** — open a merged `clink.popuplist()` with the filtered model list. The user must select a model to proceed. Pressing Esc aborts with a short visible cancellation line. The selected item determines a tentative `credential`, `provider`, and `model`.
4. **Validate model selection** — if the chosen model is unsupported, unavailable, or incompatible with the active credential/provider pair, print a concise hint and reopen model selection instead of aborting the whole onboarding flow. Only a validated model may proceed.
5. **Prompt mode selection** — look up available modes for the selected model in `modes.json`. If more than one mode exists, open a `clink.popuplist()`. If only the `default` mode exists, skip this step.
6. **Validate mode selection** — if the chosen mode is unsupported for the selected model/provider pair, print a concise hint and either reopen mode selection or continue with `default`. Invalid modes must not be saved.
7. **Save config** — write only the validated settings via `io.open()`. The file starts with the descriptive header (see [Config File Format](#config-file-format)). The directory is created if it does not exist. If the write fails, a warning is shown but execution continues.
8. **Set session state** — store the validated credential, provider, model, and mode. Print a confirmation that always includes the resolved mode, even when it is `default`, when only one mode existed, or when mode selection was skipped and Rex fell back to `default`.
9. **Process the original prompt** — after onboarding completes, the original input that triggered onboarding is sent to the LLM. The user should not need to re-type their prompt, and when Rex first prints visible text for that flow the original prompt must still be visible on screen.
10. **Handle transient provider overloads** — if the immediate post-onboarding request hits a transient capacity error such as `Overloaded`, `429`, `503`, or `529`, Rex must keep the validated selection, retry the same request with short bounded backoff, and only then print a concise temporary-capacity error if the retries still fail.

During steps 3 through 6, Rex must not call `rl_buffer:beginoutput()` or print status text until popup interaction is complete. Arrow-key navigation inside onboarding must not redraw a phantom prompt line above the selector.

Onboarding is a popup-then-print path, not a popup-only path. Rex must keep the original prompt buffered during the selector steps. Once popup interaction is complete and Rex is about to print the onboarding confirmation or LLM response, it must call `beginoutput()` first and only then clear the buffer, so the original prompt remains visible above the confirmation and answer.

The onboarding confirmation should be specific enough that the user can see the final resolved selection immediately, for example: `Configured claude-opus-4-6 on anthropic. Mode: effort_max.` or `Configured openai/gpt-5.4 on github. Mode: default.` Omitting the resolved mode from this confirmation is a specification violation.

If the config file exists and resolves to a valid `credential` + `model` pair, the onboarding is skipped entirely.

Onboarding must not trap the user in a broken loop. If every remaining option is invalid or unsupported, Rex should print a short summary, avoid writing partial config, and return control to the prompt cleanly.

## Durability

### Recall Transcript Durability

The recall session file exists to survive partial progress and late failures.

Acceptance tests:

- Start Clink and Rex once on a given local date. Exactly one new `session_<DATE>_<NNN>` file is allocated for that startup, and that same file receives the first persisted Rex record.
- Start a fresh Rex instance twice on the same local date. The first instance creates `session_<DATE>_001`; the second creates `session_<DATE>_002`.
- Accept a normal user prompt and then fail before any model answer arrives. The user prompt must already be present in the current session file because it was appended and flushed immediately when the prompt was accepted.
- Accept a normal user prompt, receive an answer, and then terminate the process abruptly. Both the user entry and the answer entry must already be present in the session file because each append was flushed immediately at availability time.
- Change `/memory` after several turns, including switching to `none`. Future API requests may include less prior conversation, but the current session file still contains the earlier persisted turns.
- Cancel onboarding or hit a request-time error after the current user prompt has already been accepted as a Rex request. The session file must still contain the user entry and the later error or cancellation outcome entry.
- Start Clink and Rex once and then inspect the recall directory. A shape where `session_<DATE>_001` is created empty and `session_<DATE>_002` receives the real transcript for that same startup is invalid.

### Defensive Input Handling

Every function must gracefully handle all possible input states:

- **Nil and missing values** — every parameter that could be nil must be checked before use.
- **Empty strings** — handled as a distinct case from nil where the semantics differ.
- **Unexpected types** — validated before use. Type mismatches produce a clear error message, not a crash.
- **Malformed external data** — JSON responses from APIs, config file content, and `modes.json` may be malformed. Every field access on parsed external data must be guarded.

### Error Propagation

- Functions that can fail return a result and an error description.
- User-visible errors are printed as plain text with a clear, actionable message.
- After an error, control returns to the cmd prompt — the plugin never gets stuck.
- Stack traces and internal details are never shown to the user.

### Code Documentation

Non-obvious code paths must include:

1. **An inline comment** explaining *why* the approach was chosen.
2. **A short proof of correctness** — a concise argument explaining why the code is correct under all expected inputs.

### Invariants

- Changing `model` clears the previous model's explicit mode selection; the effective mode after the change is `default` until another valid mode is selected.
- The Ctrl+Enter binding only fires `rex_submit` — all other keys pass through to Clink/cmd unmodified.
- Every non-empty Ctrl+Enter submission is appended to Clink shell history exactly once.
- `modes.json` is the single source of truth for model metadata such as modes and explicit capability overrides — they are not hardcoded in the Lua implementation files.
- The implementation is split across exactly four Lua files: `rex.lua`, `rex_state.lua`, `rex_turn.lua`, and `rex_provider.lua`.
- `rex_state.lua` owns durable/session state and metadata resolution; `rex_turn.lua` owns turn-scoped request/response flow and shell-command helpers.
- The four implementation files remain reasonably similar in length and none should exceed roughly 1000 lines.
- Invalid or unvalidated model/mode selections are never written to config.
- Unsupported mode selections fall back to `default` instead of leaving the session in a broken half-selected state.
- Onboarding confirmation always includes the resolved mode, including `default`.
- Decorative outer response boxes are not used for normal answers.
- There is no user-facing "shell execution is not allowed for this turn" mode; shell execution depends only on whether the newest request explicitly asks for shell activity.
- Assistant-generated shell commands are executed only on explicit shell-request turns, the raw shell-command protocol is never printed to the terminal, and session-mutating commands affect the live main shell context seen by the next prompt.
- Every non-empty Ctrl+Enter submission consumed by Rex ends with visible feedback rather than a silent return to the prompt.
- The effective conversation-memory policy is always one of: `none`, `all`, `last_answer`, `last_qa`, `last_2_qa`, `last_4_qa`.
- Changing `/memory` changes future request assembly only; it does not erase or rewrite stored conversation history.
- Every Rex instance owns exactly one recall session file named `session_<YYYYMMDD>_<NNN>` for its lifetime.
- One Clink/Rex startup must not consume more than one recall-session index for the same live Rex instance.
- Accepted user prompts are appended and flushed to the recall session file immediately; assistant-side outcomes are appended and flushed immediately when available.
- There is no `/clear` command; conversation persistence is governed by session-lifetime stored history, durable recall session files, and request-time `/memory` selection.
- A valid live `REX_API_KEY` plus a valid saved config is sufficient for the first normal prompt in a fresh session; Rex must not require `/model` or onboarding just to populate an internal credential cache.
- `state.credentials` being nil, empty, or stale is a cache-state condition, not a user-facing credential verdict.
- Rex never reports `No valid credential found.` without first checking the current `REX_API_KEY` value for the current request path.

## Non-Goals

- Separate compiled binary — everything is in Lua
- Shell prompt modification — the cmd prompt is untouched
- Full TUI chat interface
- Arbitrary autonomous file-editing workflows
- Long-running background agents
- Implicit shell execution without explicit per-turn user authorization
- Hardcoded model lists — models are always fetched from provider APIs
- Hardcoded mode definitions or per-model capability overrides — they are always read from `modes.json`
- Scrollback capture — cmd.exe does not expose scrollback to scripts
- Any visible Rex branding in the terminal
- Activation/deactivation toggle — Rex is always available via Ctrl+Enter

## Counterexamples

Things that were tried during implementation and failed. These document pitfalls so future changes do not regress.

### Don't collapse the implementation back into one giant file

An earlier shape put nearly all runtime logic into a single oversized `rex.lua`. That makes one-shot generation and regeneration unreliable once the file grows past the practical context where the model can produce one coherent pass. It also blurs semantic boundaries between Clink UI handling, durable/session state, turn-scoped request flow, and provider transport code. Keep the implementation split across exactly four balanced files: `rex.lua`, `rex_state.lua`, `rex_turn.lua`, and `rex_provider.lua`.

### Don't oversplit Rex into many tiny helper files

Swinging too far in the other direction is also a mistake. A tree of tiny files makes the plugin harder to regenerate in coherent chunks because semantic context gets scattered across too many boundaries. The goal is not "as many modules as possible"; the goal is **four** files with clear ownership and enough local context to generate each file in one homogeneous shot. In particular, do not split `rex_state.lua` into random helpers by storage mechanism or split `rex_turn.lua` into one-off formatting utilities. The point of the extra file is a real semantic boundary between durable/session concerns and turn-scoped behavior.

### Don't let `rex_state.lua` become the new catch-all file

One easy failure mode is to keep `rex.lua` small by pushing unrelated logic into `rex_state.lua` until it silently becomes the new oversized middle layer. That shape is only a rename of the original problem. If `rex_state.lua` starts absorbing prompt framing, shell-command protocol details, ANSI cleanup, or other turn-by-turn execution logic, the split has failed. Move that code into `rex_turn.lua` instead so the boundary stays semantic rather than cosmetic.

### Don't use `rl_buffer:remove(0, getlength())`

Clink's `rl_buffer` API is **1-based** with an **exclusive end**. The call `remove(0, getlength())` skips the last character, leaving it in the buffer and carrying it to the next prompt. For input "2+2" (length 3), `remove(0, 3)` removes positions 1–2 ("2+"), leaving the final "2" visible. The correct call is `remove(1, getlength() + 1)`.

### Don't call `beginoutput()` before opening a popup

Early implementation called `beginoutput()` at the start of `rex_submit()`. This works for normal printed output, but it breaks `clink.popuplist()`: as soon as the user presses an arrow key, Clink redraws the cmd prompt and a phantom prompt line appears above the popup. Popup flows must defer `beginoutput()` until after the popup closes and Rex is actually about to print visible text.

### Don't clear the input line from the display when printing output

Another early implementation cleared the input line before printing the response. This made it look like output appeared from nowhere — disorienting. When Rex is going to print visible output, the typed input must remain on screen (like any shell command), with only the next prompt starting empty. In that case, call `beginoutput()` immediately before the first print, not after the buffer has already been visually discarded.

### Don't configure Ctrl+Enter in the terminal emulator

Rex is a Clink plugin — its key binding belongs in the Clink ecosystem. The first attempt added a WezTerm key binding (`act.SendString '\x1b[13;5u'`), but this couples Rex to a specific terminal. Clink translates Win32 console input into xterm modified-key format internally. Register `\e[27;5;13~` (Clink's format) as the primary binding, with `\e[13;5u` (CSI u) as a fallback.

### Don't rely on CSI u encoding alone

The CSI u key sequence `\e[13;5u` is not sent by all terminals. Clink generates `\e[27;5;13~` (xterm modified-key format: modifier 5 = Ctrl, keycode 13 = Enter) from Win32 console input. This is the same format used by other Clink bindings (e.g., `\e[27;5;32~` for Ctrl+Space). Always register both sequences.

### Don't assume LLM output contains real ESC bytes

LLMs output text — they cannot emit the raw ESC byte (0x1B). When instructed to use ANSI formatting, they write literal `\e[1;34m` (backslash + "e" + bracket). Rex must convert `\e[`, `\033[`, and `\x1b[` to the real ESC byte before passing to `clink.print()`. Without this conversion, escape codes appear as visible text in the terminal.

### Don't assume LLMs obey the "no markdown" instruction

Even with explicit system prompt instructions to avoid markdown, LLMs routinely wrap responses in code fences (`` ```ansi ``, `` ```text ``, bare `` ``` ``). Rex must strip leading and trailing code fences from every response as a safety net. The system prompt is the primary defense; stripping is the fallback.

### Don't pass JSON body inline in the curl command

On Windows `cmd.exe`, embedding a JSON body in the curl command string requires escaping double quotes, backslashes, and special characters — a fragile process that breaks on complex prompts. Write the body to a temp file and use `curl -d @tempfile`. This avoids all shell-escaping issues.

### Don't call string methods on numeric temp-file components

The attached failure shape is:

- Rex prepares a POST request body for the provider API.
- The implementation builds the `%TEMP%\rex_*.json` filename using a numeric entropy source such as `os.clock()`.
- The code then applies a string method directly to that numeric value, for example `:gsub(...)`.
- Rex crashes before `curl` runs with a Lua error such as `attempt to index a number value`.

That behavior is incorrect. Temp-file generation is host transport plumbing and must be robust for every request path that writes a JSON body. If Rex uses numeric entropy sources, it must stringify or format them explicitly before any string-only operation. A user prompt must never be consumed by a provider-request setup crash.

### Don't use vertical lines in tables (rex_skills.md)

Unicode vertical line characters (`│`, `║`) cause alignment problems in terminal fonts because their rendered width is inconsistent. Tables should use column spacing and horizontal rules (`─`) only. Box-drawing tables with full borders look broken when column widths don't align to character cells.

### Don't wrap responses in boxes (rex_skills.md)

The Response Box pattern (wrapping output in `╭╮╰╯` borders) adds visual noise without value. Terminal output is already visually separated by the prompt lines above and below. Removing boxes keeps output clean and avoids alignment issues.

This prohibition is global, not just a style suggestion for some prompts. If `rex_skills.md` contains box-friendly examples, the system prompt and output rules in this spec still win: normal answers must remain unboxed.

### Don't omit `name` from Anthropic tool definitions

The Anthropic API requires both `type` and `name` fields in tool definitions. Sending `{type: "web_search_20250305"}` without `name` produces the error `tools.0.web_search_20250305.name: Field required`. The correct definition is `{type: "web_search_20250305", name: "web_search"}`.

### Don't add web search to every model on a search-capable provider

Provider-level support is not enough. Some models on Anthropic or OpenAI endpoints still reject web-search tool definitions. For example, Anthropic can return an error like `'<model>' does not support tool types: web_search_20250305`. Rex must therefore treat web search as a per-model capability and omit the tool when support is unknown or rejected.

### Don't let stale history compete with the newest request

Raw message history is useful for continuity, but it must not cause the assistant to answer both the old topic and the new one. If the user first asked about liters versus gallons and then asks for tonight's weather in Zagreb, the weather answer must not reopen the units discussion unless the new prompt explicitly asks for it. Rex must clearly frame earlier turns as background and the latest turn as the current task.

### Don't hide the resolved mode in the onboarding confirmation

An onboarding confirmation that prints only the chosen model and provider leaves the user guessing whether the requested mode stuck, whether the selector fell back to `default`, or whether mode validation silently changed the final request parameters. The confirmation must always include the resolved mode, even when that mode is `default`.

This includes the first-run path where mode selection is skipped because only `default` exists. The visible confirmation must still say so explicitly.

### Don't drop Ctrl+Enter submissions from shell history

If Rex consumes the line but does not append it to Clink shell history, the next Up-arrow recall feels broken: the most recent submitted line is missing even though the user just used it. The specification therefore requires a real history write, not just a conceptual "remember this line" comment.

What went wrong before:

- An earlier implementation tried to call `clink.history.add()`.
- That function does not exist in Clink's Lua API.
- The attempted history write therefore did nothing, and Ctrl+Enter submissions silently disappeared from normal shell recall.

What the fixed technique must do:

- On immediate print and popup-only paths, use `rl.invokecommand("add-history")` while the submitted text is still in `rl_buffer`. This is the working Clink-supported way to append the current line and clear the edit buffer.
- On the deferred onboarding path, do **not** call `add-history` before the popup, because it would clear the buffer too early. Save the trimmed line separately and append it later with session-scoped `clink history -s` when the deferred buffer is flushed.
- In all paths, the line must be written exactly once.

This counterexample is included because "append to history" is not enough guidance by itself; the technique matters.

### Don't use `add-history` on the deferred onboarding path

`rl.invokecommand("add-history")` is correct only while the current submission is still allowed to leave the edit line. On the first-run onboarding path, Rex must preserve the original text through popup selection so the eventual confirmation and answer still appear beneath it. Calling `add-history` before the popup would clear the line immediately and break that guarantee.

The correct deferred technique is:

- Keep `rl_buffer` intact during popup interaction.
- Save the trimmed submitted line separately.
- When Rex is finally about to print or unwind after cancellation/error, call deferred `beginoutput()` first, then `remove()`, then append the saved line via `clink history -s` scoped to the active session.

### Don't print the raw shell-command protocol

The shell-command protocol is for Rex, not for the user. If Rex prints `<<<REX_SHELL_COMMAND>>>` blocks to the terminal, the feature becomes noisy and confusing. Rex must extract the block from the raw assistant response, execute it only when the newest request explicitly asks for shell activity, and show the user only the resulting normal shell transcript. That transcript is the end of the turn; there is no follow-up final answer from the model in that same turn.

### Don't tell the user shell execution is not allowed for this turn

The attached failure shape is:

- User asks an explicit shell question such as `list all files in the dir larger than 5kB`.
- Rex answers with text like `Shell execution is not allowed for this turn, but here's the command you can run: ...`.

That behavior is incorrect. There is no user-facing "shell not allowed for this turn" mode in this product. If the newest request is an explicit shell request, Rex should either execute it through the shell-command protocol or give a normal answer without inventing internal policy-denial wording.

### Don't consume a turn and print nothing

Once Rex has consumed a non-empty Ctrl+Enter submission, returning directly to the next prompt with no visible result is a bug.

Common wrong shapes include:

- Popup cancellation with no visible cancellation line.
- Malformed shell-command blocks that are dropped silently.
- Side-effect-only shell commands that complete with empty stdout/stderr and leave no visible trace.
- Empty or fully stripped assistant output with no fallback error.

The correct behavior is always to leave one visible outcome behind: answer, transcript, confirmation, cancellation, or error.

### Don't execute session-mutating shell commands in a detached helper shell

The attached failure case is:

- User asks `change cwd to home`.
- Rex prints a transcript line such as `> cd /d "C:\Users\H"`.
- The next prompt still starts in the old directory, so later normal shell commands do not see the change.

That behavior is incorrect even if the command text itself looks right. It means Rex executed the command in a detached helper shell, simulated only the transcript, or otherwise failed to apply the shell effect back to the live interactive session.

For commands whose purpose is to mutate session state, Rex must execute them in the main shell context or otherwise make the main shell context observe the same effect before the next prompt. A cwd-changing request must change the next prompt's working directory. An environment-setting request must change what the next normal Enter-submitted command sees in `%VAR%`.

### Don't short-circuit `cd` through `os.chdir()`

For a normal shell `cd` request, Rex should let the real shell execute `cd` as a command, not print a transcript line and then try to simulate the result with Lua-side `os.chdir()` or `clink.chdir()`.

The reliable path is to inject the actual cmd command into the active Clink edit line and accept it immediately so `cmd.exe` applies its own builtin semantics in the current session. A deferred hook like `onprovideline()` is not sufficient for Ctrl+Enter execution, because it schedules a future prompt cycle rather than running the command now.

### Don't drift from `cmd` into PowerShell

Rex runs inside an interactive Clink + `cmd.exe` session. That means normal shell-command responses should target `cmd`, not PowerShell.

The attached failure shape is:

- User asks `list dir files`.
- Rex emits a shell-command block with `shell=powershell`.
- Rex uses PowerShell syntax such as `Get-ChildItem` or `Set-Location -LiteralPath $HOME` even though the session shell is `cmd.exe`.

That behavior is incorrect unless the user explicitly asked for PowerShell. Rex should not switch shells on its own for routine shell work. In this environment, the default should be `shell=cmd` with cmd-native syntax such as `dir`, `cd /d "..."`, `set`, `pushd`, and `popd`.

PowerShell remains available as an explicit option in the protocol, but it must be chosen deliberately. If the user says `use PowerShell`, asks for PowerShell-specific behavior, or needs syntax that only makes sense in PowerShell, then `shell=powershell` is acceptable. Otherwise Rex must stay in `cmd`.

### Don't teach Rex to use `cd /d "%USERPROFILE%"` for home-directory changes

That command shape has failed in real Rex sessions with `The syntax of the command is incorrect.` It should therefore be treated as a counterexample, not as the preferred transcript for `change cwd to home`.

For home-directory requests, prefer a concrete quoted absolute path when the home path is already known. If the concrete path is not known yet, Rex should resolve the home path host-side and still execute a cmd-native command such as `cd /d "C:\Users\H"` rather than switching shells or emitting `%USERPROFILE%` variants verbatim.

### Don't emit brittle `cmd` metaprogramming for routine inspection

The attached failure shape is:

- User asks for a routine `cmd` task such as showing the last lines of a file without PowerShell.
- Rex emits a complex one-liner that mixes `for /f`, nested quotes, `&`, and `%`/`%%` loop-variable ambiguity.
- The command fails with errors such as `%%a was unexpected at this time.`

This is a counterexample, not an acceptable fallback. The problem is not that `for /f` or `%%a` are universally forbidden; the problem is mixing interactive-cmd syntax, batch-file syntax, and dense quoting into one fragile line.

Preferred recovery order:

1. Use a short direct interactive cmd command if one is obvious.
2. If the task is too stateful for that, write a short temp `.cmd` script and `call` it.
3. Only use `%a` in direct interactive `cmd` text and `%%a` inside generated batch-script lines.

A successful repair may still contain `%%a` when Rex is generating a temp `.cmd` file. That is acceptable because the target context is batch syntax. What Rex must avoid is semantic soup: batch-only syntax jammed into an interactive one-liner, or a quote-heavy command whose correctness depends on the reader mentally simulating multiple parsing layers.

### Don't treat transient overload as a broken selection

If onboarding successfully picks `claude-opus-4-6` and the immediate `2+2` request returns `Overloaded`, that is a transient provider-capacity failure, not proof that the model, mode, or credential is invalid. Rex must keep the validated selection, retry the same request with short bounded backoff, and only then print a concise temporary-capacity message if the retries still fail. It must not rerun onboarding or imply that the chosen model/mode was wrong.

### Don't implement `/memory` by deleting conversation history

The `memory` setting controls how much prior conversation is included in future API requests. It does not mean "forget everything except this subset."

Wrong behavior:

- User has a longer conversation history stored in the current Rex session.
- User switches `/memory` from `all` to `last answer` or `none`.
- Rex truncates, rewrites, or discards the stored history table itself.
- Later switching `/memory` back to `all` cannot restore the earlier conversation context.

That behavior is incorrect. `/memory` is a request-window selector, not a destructive history-management command. Stored conversation persists for the Rex session, and the durable recall session file remains append-only.

### Don't delay recall-session writes until the turn ends or the process exits

The attached failure shape is:

- Rex accepts a user prompt.
- The implementation keeps that prompt only in memory and plans to write the full turn later.
- The process fails, the request errors out, onboarding is cancelled, or Clink exits before the delayed write happens.
- The durable session file is missing the prompt or the already-produced answer even though that data had existed in memory.

That behavior is incorrect. The durable recall transcript is meant to survive partial progress, not only clean shutdown.

Required behavior:

- Append and flush the user entry immediately when the prompt becomes the current accepted Rex request.
- Append and flush the assistant-side outcome immediately when it becomes available.
- Do not wait for process exit, end-of-turn cleanup, or a later batch rewrite to persist already-known transcript data.

### Don't allocate a throwaway recall session file on startup

The attached failure shape is:

- One Clink startup results in one live Rex session.
- During startup, Rex allocates `session_<DATE>_001`.
- That first file remains empty.
- Later in the same startup, Rex allocates `session_<DATE>_002` and uses it for the real conversation transcript.

That behavior is incorrect. One Clink/Rex startup must allocate exactly one durable recall session file for the live Rex instance. Startup probes, duplicate loads, speculative initialization, or abandoned startup paths must not consume an extra daily index or leave behind an empty placeholder file.

Required behavior:

- Allocate at most one recall session file for the live Rex instance created by that startup.
- Reuse that same file for the first persisted record and all later records for that instance.
- Do not create an empty `session_<DATE>_<NNN>` placeholder and then switch to `session_<DATE>_<NNN+1>` for the real transcript.

### Don't misclassify a non-empty provider response as "no content"

The attached failure shape is:

- The provider returns a successful response.
- Rex parses that response successfully.
- The response either contains usable assistant text in the provider payload or becomes empty only after Rex's own host-side cleanup.
- Rex reports a generic error such as `No content in Anthropic response`.

That behavior is incorrect. A provider-level "no content" error is only valid when the successful provider payload truly lacks usable assistant text in the provider's native response fields. If the payload shape is unexpected, Rex must report a specific extraction-shape error. If host-side stripping removes the only text, Rex must report a local empty-output or post-processing failure instead of blaming the provider for missing content.

Required behavior:

- Inspect the parsed successful provider payload before declaring a provider-level no-content failure.
- Distinguish true provider no-content from unexpected response shape.
- Distinguish provider no-content from local post-processing that empties an otherwise non-empty response.

### Don't treat an empty credential cache as proof that no key exists

The attached failure shape is:

- The user already has a valid saved config with a selected `credential`, `provider`, and `model`.
- `REX_API_KEY` is present in the live shell and contains a usable entry for that session.
- The user submits a normal prompt such as `weather in Zagreb now` or `2+2`.
- Rex replies with `Error: No valid credential found.`

That behavior is incorrect. It means the implementation treated an uninitialized or stale parsed-credential cache as the source of truth and failed before re-reading the actual environment variable.

This counterexample is intentionally code-agnostic: the bug is not tied to any particular function name. The design mistake is allowing "credential cache not populated yet" to collapse into the same user-facing outcome as "no usable credential exists in the current environment."

Required behavior:

- Before emitting a no-credential error on any request path, Rex must resolve credentials from the live `REX_API_KEY` value for that session.
- A normal first prompt in a fresh session must be able to trigger that resolution automatically.
- If `REX_API_KEY` is present but does not contain the configured credential label, Rex must say that specifically instead of pretending no credential exists at all.

### Don't drop the original prompt after onboarding

After onboarding completes, the original input that triggered it must be sent to the LLM — not discarded. An earlier approach returned early after onboarding, forcing the user to re-type their prompt. This felt broken: the user typed "2+2", pressed Ctrl+Enter, sat through model selection, and then saw nothing happen. The prompt should flow through to the LLM once a model is configured.

A later variant fixed processing but still cleared `rl_buffer` before onboarding finished. That meant the prompt was answered correctly, but the originating line had already vanished from the terminal, so the response appeared detached from the user's input. This is also incorrect. Onboarding must preserve the original prompt visually by deferring buffer clearing until after popup interaction and by calling `beginoutput()` before `remove()` when visible output begins.
