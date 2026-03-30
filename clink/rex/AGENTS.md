# Agent Notes

## Scratch Rewrite Rule

When the task is to create a new implementation, rewrite a module, or "start from scratch", do **not** consult any previous implementation as reference material.

Required behavior:

- Treat prior code as potentially misleading.
- Build the new implementation from the spec, current user instructions, and external documentation only.
- Do not read the current or older implementation files just to reuse structure, logic, naming, or control flow.
- Do not compare against `HEAD`, git history, other branches, stashes, patches, or diffs in order to guide the rewrite.
- Do not use `git show`, `git diff`, `git log`, `git blame`, or similar history inspection during a scratch implementation task.
- Do not continue from partially written code unless the user explicitly says to reuse it.

Allowed inputs for a scratch implementation:

- `spec.md`
- `README.md`
- `AGENTS.md`
- data files such as `modes.json` when they are part of the required runtime contract
- official external docs needed to implement or verify behavior

If a previous implementation has already been opened by mistake, stop treating it as input, say so plainly, and restart the design from the spec and current requirements instead of blending old and new approaches.

## Lua Compiler

Available at `c:\Users\H\AppData\Local\Programs\lua-5.2\`.

Use for syntax checking:

```
c:\Users\H\AppData\Local\Programs\lua-5.2\luac52.exe -p plugin/init.lua
```

## OpenAI Reasoning Effort Discovery

Use the following Python script to detect which `reasoning_effort` levels a given OpenAI model supports. Results are used to populate `modes.json`.

Candidates: `none`, `minimal`, `low`, `medium`, `high`, `xhigh`

```python
CANDIDATES = ["none", "minimal", "low", "medium", "high", "xhigh"]

def detect_supported_reasoning_efforts(client, model):
    supported = []
    for effort in CANDIDATES:
        try:
            client.chat.completions.create(
                model=model,
                messages=[{"role": "user", "content": "ping"}],
                max_completion_tokens=1,
                reasoning_effort=effort,
            )
            supported.append(effort)
        except Exception as e:
            if "reasoning_effort" in str(e) or "unsupported" in str(e):
                continue
            raise
    return supported
```
