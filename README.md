# mini-agent.sh

A deliberately small coding-agent harness inspired by mini-swe-agent. It is implemented as one Bash script, has no package installation step, and works with OpenAI, Anthropic, and OpenRouter.

## Features

- Runs complete agent loops: the model can inspect files, execute commands, edit code, run tests, and continue until it produces a final answer.
- Supports one-shot tasks, piped prompts, and persistent interactive sessions.
- Uses OpenAI's Responses API with its native local `shell` tool.
- Gives Anthropic and OpenRouter portable `read` and `bash` tools, including image attachments.
- Supports configurable reasoning effort, model-call and output limits, command timeouts, and machine-readable JSON output.
- Automatically compacts long conversations using exact provider-reported token usage while preserving the latest complete turn.
- Can retry recognized safety refusals once with a configured fallback model and keep that model selected for the session.
- Keeps tool progress on stderr so normal and JSON answers on stdout are easy to pipe.

## Requirements

- Bash 3.2+
- `curl` and `jq`
- Standard Unix utilities used by the harness: `awk`, `base64`, `cat`, `date`, `find`, `head`, `mktemp`, `rm`, `sort`, `tail`, `tr`, `uname`, and `wc`
- Standard agent editing and inspection utilities: `sed` and `nl`
- The install one-liner additionally uses `mkdir` and `chmod`
- Optional: `file` for MIME detection, `strings` for extracting text from unknown binary files, and GNU `timeout` (or `gtimeout`) to enforce command timeouts

## Install

Download the latest version from this repository into `~/.local/bin`:

```bash
mkdir -p "$HOME/.local/bin" && curl -fsSL https://raw.githubusercontent.com/mikesoylu/mini-agent/main/mini-agent.sh -o "$HOME/.local/bin/mini-agent" && chmod +x "$HOME/.local/bin/mini-agent"
```

This installs the script only; the requirements above must already be available. Make sure `~/.local/bin` is on your `PATH`, then run `mini-agent`. To use a local clone without installing it, run `chmod +x mini-agent.sh` followed by `./mini-agent.sh`.

## Quick start

```bash
# Configure one provider.
export OPENAI_API_KEY=...
# export ANTHROPIC_API_KEY=...
# export OPENROUTER_API_KEY=...

mini-agent "Find and fix the failing tests"
```

When several API keys are present, automatic provider selection prefers OpenAI, then Anthropic, then OpenRouter. Pass `--provider` to choose explicitly.

## Usage

```text
mini-agent.sh [options] "task"
mini-agent.sh [options]                 # interactive mode in a terminal
```

Examples:

```bash
# One-shot tasks
./mini-agent.sh -m gpt-5.6-sol -r xhigh "Find and fix the failing tests"
./mini-agent.sh -p anthropic -m claude-opus-5 "Explain this repository"
./mini-agent.sh -p openrouter -C ./project "Review the current diff"

# Read a task from stdin
printf 'List the main components' | ./mini-agent.sh -p openai

# Emit one JSON object on stdout
./mini-agent.sh --json "Summarize the repository"

# Complete the initial task, then stay in an interactive session
./mini-agent.sh -i "Start by reading README.md"
```

### CLI options

| Option | Description | Default |
|---|---|---|
| `-p, --provider NAME` | `openai`, `anthropic`, or `openrouter` | Inferred from API keys |
| `-m, --model MODEL` | Provider model name | Provider-specific |
| `--fallback-model MODEL` | Retry a recognized safety refusal once; `none` disables fallback | Provider-specific |
| `-r, --reasoning LEVEL` | Reasoning effort | `medium` |
| `-C, --chdir DIR` | Working directory exposed to the agent | Current directory |
| `-n, --max-turns N` | Maximum model calls for each user request | `1024` |
| `--max-tokens N` | Maximum output tokens for each model call | `32768` |
| `--compact-tokens N` | Provider-reported context usage that triggers compaction | `262144` |
| `-i, --interactive` | Stay interactive after an initial task | Off |
| `--json` | Return `{provider, model, fallback_model, reasoning, answer}` | Off |
| `-q, --quiet` | Hide model and tool progress written to stderr | Off |
| `-h, --help` | Show command help | |
| `-v, --version` | Show the mini-agent version | |

Reasoning levels are `default`, `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, and `max`. Provider and model support varies. `default` omits explicit reasoning controls. OpenAI and Anthropic map `minimal` to `low`; OpenRouter maps `max` to `xhigh`.

## Interactive sessions

Run `./mini-agent.sh` with no task in a terminal, or add `-i` after an initial task. Conversation history and the active fallback model are retained between requests.

| Command | Action |
|---|---|
| `/model NAME` | Switch models and clear conversation history |
| `/provider NAME` | Switch providers, select that provider's defaults, and clear history |
| `/reasoning LEVEL` | Change reasoning effort without clearing history |
| `/compact` | Create a context checkpoint immediately |
| `/status` | Show the active models, message count, exact token usage, compaction budget, and limits |
| `/clear` | Clear conversation history and token state |
| `/help` | Show interactive commands |
| `/quit` or `/exit` | End the session |

After a refusal fallback, `/clear` preserves the active fallback model. `/model` or `/provider` selects a new primary model.

## Configuration

Command-line model and provider values take precedence over their environment-variable equivalents.

### Provider settings

| Provider | Required | Optional | Default primary / fallback |
|---|---|---|---|
| OpenAI | `OPENAI_API_KEY` | `OPENAI_MODEL`, `OPENAI_FALLBACK_MODEL`, `OPENAI_BASE_URL` | `gpt-5.6-sol` / `gpt-5.6-terra` |
| Anthropic | `ANTHROPIC_API_KEY` | `ANTHROPIC_MODEL`, `ANTHROPIC_FALLBACK_MODEL`, `ANTHROPIC_BASE_URL`, `ANTHROPIC_VERSION` | `claude-opus-5` / `claude-sonnet-5` |
| OpenRouter | `OPENROUTER_API_KEY` | `OPENROUTER_MODEL`, `OPENROUTER_FALLBACK_MODEL`, `OPENROUTER_BASE_URL`, `OPENROUTER_HTTP_REFERER`, `OPENROUTER_APP_NAME` | `openai/gpt-5.6-sol` / `openai/gpt-5.6-terra` |

The default base URLs are the providers' public APIs. `ANTHROPIC_VERSION` defaults to `2023-06-01`, and the default OpenRouter app title is `mini-agent`.

### Shared settings

| Variable | Purpose | Default |
|---|---|---|
| `MINI_AGENT_PROVIDER` | Provider selection | Inferred from API keys |
| `MINI_AGENT_MODEL` | Primary model | Provider-specific |
| `MINI_AGENT_FALLBACK_MODEL` | Refusal fallback model | Provider-specific |
| `MINI_AGENT_REASONING` | Reasoning effort | `medium` |
| `MINI_AGENT_MAX_TURNS` | Model calls per user request | `1024` |
| `MINI_AGENT_MAX_TOKENS` | Output tokens per model call | `32768` |
| `MINI_AGENT_COMPACT_TOKENS` | Automatic compaction threshold | `262144` |
| `MINI_AGENT_COMPACT_MAX_TOKENS` | Maximum checkpoint-summary output | `13107` |
| `MINI_AGENT_MAX_TOOL_OUTPUT` | Maximum captured bytes for each stdout/stderr stream or compatible-tool result | `30000` |
| `MINI_AGENT_TOOL_TIMEOUT` | Maximum command runtime in seconds when `timeout` or `gtimeout` is installed | `120` |
| `MINI_AGENT_API_TIMEOUT` | Maximum API request time in seconds | `600` |
| `MINI_AGENT_WORKDIR` | Agent working directory | Current directory |

`CURL_BIN` and `JQ_BIN` may also be set to alternate executable paths, primarily for testing.

## Provider tools and file support

OpenAI receives one native local `shell` tool. Shell calls execute through `bash -lc` in the configured working directory. To inspect an image, the model can issue the virtual command `mini-agent-read PATH`; mini-agent intercepts it and attaches the file as `input_image` on the next Responses API call.

Anthropic and OpenRouter receive two compatible tools:

- `read` lists a directory, returns numbered slices of text files (up to 2,000 lines per call), extracts printable strings from otherwise unknown files when `strings` is available, and attaches PNG, JPEG, GIF, or WebP images.
- `bash` executes a command through `bash -lc` in the configured working directory and reports its combined output and exit status.

PDF input is not supported. Tool output larger than `MINI_AGENT_MAX_TOOL_OUTPUT` is truncated by retaining its beginning and end. Each tool call starts in the configured working directory, so a `cd` in one call does not carry over to later calls.

## Context compaction

After each model response, mini-agent records exact context usage reported by the provider; Anthropic cache-read and cache-creation tokens are included. Automatic compaction waits for the current agent loop to finish so no tool call is left unresolved.

Compaction asks the active model for a structured checkpoint, replaces older history with that checkpoint, and retains the latest complete turn. The request is appended to the existing provider-native conversation to preserve the cacheable prefix. OpenAI keeps its `previous_response_id` chain for the summary request, then starts a fresh chain from the compacted transcript. Image paths and short visual summaries are explicitly preserved in the checkpoint. Token usage is shown as unknown until the next normal response refreshes it.

## Refusal fallback

If a provider returns a recognized safety refusal, mini-agent retries the same request once with the fallback model. A successful fallback becomes the active model for the rest of the interactive session, including later requests, compaction, and `/clear`. Use `--fallback-model none` to disable this behavior.

Recognized signals are Anthropic `stop_reason: "refusal"`, OpenAI refusal output and matching HTTP content-policy or cybersecurity rejections, and OpenRouter `content_filter` or `message.refusal` responses. Network failures, rate limits, overloads, and ordinary API errors are returned without switching models.

## Security and execution notes

The native OpenAI shell and provider-compatible `bash` tool can run arbitrary commands with the same permissions and environment as mini-agent. Use a working directory and environment you are comfortable exposing to the selected model, and avoid placing unrelated secrets in that environment.

API requests are non-streaming to keep the script compact and provider-neutral. When GNU `timeout` or `gtimeout` is unavailable, command execution still works but the harness cannot enforce `MINI_AGENT_TOOL_TIMEOUT`.

## Tests

The test suite uses mocked provider responses and does not require real API keys:

```bash
bash tests/test.sh
```
