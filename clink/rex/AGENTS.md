# Agent Notes

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
