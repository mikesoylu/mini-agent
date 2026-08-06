# mini-agent.sh

A deliberately small coding-agent harness inspired by mini-swe-agent, implemented in one Bash script. OpenAI uses the Responses API's native local `shell` tool, while Anthropic and OpenRouter use provider-compatible `read` and `bash` tools.

## Requirements

- Bash 3.2+
- `curl`, `jq`, `awk`, `base64`
- Optional: `file` and `strings` for file detection, GNU `timeout` (or `gtimeout`) for command timeouts

## Setup

```bash
chmod +x mini-agent.sh

# Choose one provider:
export OPENAI_API_KEY=...
export ANTHROPIC_API_KEY=...
export OPENROUTER_API_KEY=...
```

When multiple keys are set, automatic selection prefers OpenAI, then Anthropic, then OpenRouter. Use `--provider` to choose explicitly.

## CLI mode

```bash
./mini-agent.sh -m gpt-5.6-sol -r xhigh "Find and fix the failing tests"
./mini-agent.sh -p anthropic -m claude-fable-5 --fallback-model claude-sonnet-5 "Explain this repository"
./mini-agent.sh -p openrouter --json "List the main components"
printf 'Review the current diff' | ./mini-agent.sh -p openai
```

## Interactive mode

Run with no task, or add `-i` to continue chatting after a CLI task:

```bash
./mini-agent.sh
./mini-agent.sh -i "Start by reading README.md"
```

Inside the prompt, use `/model`, `/provider`, `/reasoning`, `/compact`, `/status`, `/clear`, `/help`, and `/quit`. `/compact` creates a checkpoint immediately; `/status` reports the latest exact provider token count, compaction threshold and remaining budget, message count, and model limits.

## Configuration

Provider-specific variables:

| Provider | Required | Optional |
|---|---|---|
| OpenAI | `OPENAI_API_KEY` | `OPENAI_MODEL`, `OPENAI_FALLBACK_MODEL`, `OPENAI_BASE_URL` |
| Anthropic | `ANTHROPIC_API_KEY` | `ANTHROPIC_MODEL`, `ANTHROPIC_FALLBACK_MODEL`, `ANTHROPIC_BASE_URL`, `ANTHROPIC_VERSION` |
| OpenRouter | `OPENROUTER_API_KEY` | `OPENROUTER_MODEL`, `OPENROUTER_FALLBACK_MODEL`, `OPENROUTER_BASE_URL`, `OPENROUTER_HTTP_REFERER`, `OPENROUTER_APP_NAME` |

Shared variables include `MINI_AGENT_PROVIDER`, `MINI_AGENT_MODEL`, `MINI_AGENT_FALLBACK_MODEL`, `MINI_AGENT_REASONING`, `MINI_AGENT_MAX_TURNS`, `MINI_AGENT_MAX_TOKENS`, `MINI_AGENT_COMPACT_TOKENS`, `MINI_AGENT_COMPACT_MAX_TOKENS`, `MINI_AGENT_TOOL_TIMEOUT`, `MINI_AGENT_API_TIMEOUT`, `MINI_AGENT_MAX_TOOL_OUTPUT`, and `MINI_AGENT_WORKDIR`. `--compact-tokens` or `MINI_AGENT_COMPACT_TOKENS` sets the automatic compaction threshold, which defaults to 262144 tokens (256k). Summary output is capped at 13107 tokens by default.

Default primary/fallback pairs are OpenAI `gpt-5.6-sol` → `gpt-5.6-terra`, Anthropic `claude-opus-5` → `claude-sonnet-5`, and OpenRouter `openai/gpt-5.6-sol` → `openai/gpt-5.6-terra`. Override the fallback with `--fallback-model`, the shared environment variable, or its provider-specific counterpart; use `--fallback-model none` to disable it. A recognized safety refusal is retried once, then the fallback remains pinned for the rest of the session (including after `/clear`; `/model` or `/provider` selects a new primary). Anthropic is triggered specifically by `stop_reason: "refusal"`; OpenAI refusal content and HTTP 400 content-policy/cybersecurity rejections, plus OpenRouter `content_filter`/`message.refusal` responses, are also recognized. Network, rate-limit, overload, and ordinary API errors are not retried on another model.

Reasoning levels are `default`, `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, and `max`. Providers and models support different subsets. `default` omits reasoning controls and uses the model's native behavior. OpenAI uses `reasoning.effort` on Responses (`minimal` maps to `low`); Anthropic uses adaptive thinking (`minimal` maps to `low`); OpenRouter maps `max` to `xhigh` for compatibility.

## Context compaction

After every model response, mini-agent uses the provider-reported context usage rather than estimating it. Anthropic cache-read and cache-creation tokens are included. Automatic compaction waits for the agent turn to finish with every tool call resolved, so the conversation may exceed the threshold slightly.

The summary request preserves the existing provider-native conversation, system prompt, tools, and settings, then appends one user compaction message. This keeps the prior request prefix eligible for provider token caching. OpenAI appends the message to its existing `previous_response_id` chain; Anthropic and OpenRouter append it to their unchanged message arrays. Image blocks remain in history until compaction, and the checkpoint prompt requires exact attachment paths plus short visual-content summaries.

After generating the summary, mini-agent injects it as a user message and retains the latest complete turn. If one turn remains oversized, later compactions split its older prefix from its recent assistant/tool suffix. OpenAI then clears its response chain and resumes from the compacted transcript. Token usage is marked unknown until the next normal model response supplies an exact count.

## File support and safety

The system prompt includes the operating system, machine architecture, current date, working directory, and examples for creating, editing, and viewing files with shell commands. On macOS it explicitly uses the BSD `sed -i ''` form.

On OpenAI, the model reads and edits through the native local shell. For visual input it can issue `mini-agent-read PATH`; the harness intercepts that virtual command and supplies the image as `input_image` on the next Responses turn. No legacy `local_shell` calls are used.

Anthropic and OpenRouter retain the portable `read` adapter: it returns numbered text, directory listings, and actual image data for PNG/JPEG/GIF/WebP. PDF files are not supported by either read path.

The native OpenAI shell and the provider-compatible `bash` tool can execute arbitrary commands with the same permissions as the harness. Run it only in a directory and environment you are comfortable giving to the selected model. Commands run from `--chdir`; directory changes do not persist between calls.

API calls are non-streaming to keep the implementation compact and provider-neutral. Tool progress goes to stderr, so `--json` keeps stdout machine-readable.
