#!/usr/bin/env bash
# mini-agent: a deliberately small, Bash-only coding agent harness.
set -uo pipefail
VERSION="0.2.0"
PROVIDER="${MINI_AGENT_PROVIDER:-}"
MODEL="${MINI_AGENT_MODEL:-}"
FALLBACK_MODEL="${MINI_AGENT_FALLBACK_MODEL:-}"
TURN_MODEL=""
REASONING="${MINI_AGENT_REASONING:-medium}"
MAX_TURNS="${MINI_AGENT_MAX_TURNS:-1024}"
MAX_TOKENS="${MINI_AGENT_MAX_TOKENS:-32768}"
COMPACT_TOKENS="${MINI_AGENT_COMPACT_TOKENS:-262144}"
COMPACT_MAX_TOKENS="${MINI_AGENT_COMPACT_MAX_TOKENS:-13107}"
MAX_TOOL_OUTPUT="${MINI_AGENT_MAX_TOOL_OUTPUT:-30000}"
TOOL_TIMEOUT="${MINI_AGENT_TOOL_TIMEOUT:-120}"
API_TIMEOUT="${MINI_AGENT_API_TIMEOUT:-600}"
WORKDIR="${MINI_AGENT_WORKDIR:-$PWD}"
OUTPUT_FORMAT="text"
INTERACTIVE=0
QUIET=0
PROMPT=""
HISTORY='[]'
OPENAI_PREVIOUS_RESPONSE_ID=""
OPENAI_NEEDS_RESTART=0
CONTEXT_TOKENS=0
COMPACTION_SUMMARY=""
LAST_ANSWER=""
CURL_BIN="${CURL_BIN:-curl}"
JQ_BIN="${JQ_BIN:-jq}"
if [[ -t 2 ]]; then
  C_DIM=$'\033[2m'; C_CYAN=$'\033[36m'; C_RED=$'\033[31m'; C_RESET=$'\033[0m'
else
  C_DIM=""; C_CYAN=""; C_RED=""; C_RESET=""
fi
say() { [[ "$QUIET" -eq 1 ]] || printf '%s\n' "$*" >&2; }
info() { say "${C_DIM}$*${C_RESET}"; }
die() { printf '%smini-agent: %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; exit 1; }
usage() {
  cat <<'EOF'
mini-agent - a tiny Bash-only coding agent

Usage:
  mini-agent.sh [options] "task"
  mini-agent.sh [options]                 # interactive mode

Options:
  -p, --provider NAME     openai, anthropic, or openrouter
  -m, --model MODEL       Provider model name
      --fallback-model M  Retry safety refusals once with model M (none disables)
  -r, --reasoning LEVEL   default, none, minimal, low, medium, high, xhigh, max
  -C, --chdir DIR         Working directory available to the agent
  -n, --max-turns N       Maximum model calls per user turn (default: 1024)
      --max-tokens N      Maximum output tokens per model call (default: 32768)
      --compact-tokens N  Compact context at this token count (default: 262144)
  -i, --interactive       Stay interactive after an initial task
      --json              JSON output in CLI mode
  -q, --quiet             Hide tool progress
  -h, --help              Show help
  -v, --version           Show version

Environment:
  OPENAI_API_KEY, OPENAI_BASE_URL, OPENAI_MODEL, OPENAI_FALLBACK_MODEL
  ANTHROPIC_API_KEY, ANTHROPIC_BASE_URL, ANTHROPIC_MODEL, ANTHROPIC_FALLBACK_MODEL
  OPENROUTER_API_KEY, OPENROUTER_BASE_URL, OPENROUTER_MODEL, OPENROUTER_FALLBACK_MODEL
  MINI_AGENT_PROVIDER, MINI_AGENT_MODEL, MINI_AGENT_FALLBACK_MODEL, MINI_AGENT_REASONING
  MINI_AGENT_MAX_TURNS, MINI_AGENT_MAX_TOKENS, MINI_AGENT_COMPACT_TOKENS
  MINI_AGENT_COMPACT_MAX_TOKENS, MINI_AGENT_TOOL_TIMEOUT
  OPENROUTER_HTTP_REFERER, OPENROUTER_APP_NAME

Interactive commands:
  /model NAME, /provider NAME, /reasoning LEVEL, /clear, /help, /quit
EOF
}
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
is_uint() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }
parse_args() {
  local parts=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -p|--provider) [[ $# -ge 2 ]] || die "$1 requires a value"; PROVIDER=$2; shift 2 ;;
      -m|--model) [[ $# -ge 2 ]] || die "$1 requires a value"; MODEL=$2; shift 2 ;;
      --fallback-model) [[ $# -ge 2 ]] || die "$1 requires a value"; FALLBACK_MODEL=$2; shift 2 ;;
      -r|--reasoning) [[ $# -ge 2 ]] || die "$1 requires a value"; REASONING=$2; shift 2 ;;
      -C|--chdir) [[ $# -ge 2 ]] || die "$1 requires a value"; WORKDIR=$2; shift 2 ;;
      -n|--max-turns) [[ $# -ge 2 ]] || die "$1 requires a value"; MAX_TURNS=$2; shift 2 ;;
      --max-tokens) [[ $# -ge 2 ]] || die "$1 requires a value"; MAX_TOKENS=$2; shift 2 ;;
      --compact-tokens) [[ $# -ge 2 ]] || die "$1 requires a value"; COMPACT_TOKENS=$2; shift 2 ;;
      -i|--interactive) INTERACTIVE=1; shift ;;
      --json) OUTPUT_FORMAT="json"; shift ;;
      -q|--quiet) QUIET=1; shift ;;
      -h|--help) usage; exit 0 ;;
      -v|--version) printf 'mini-agent %s\n' "$VERSION"; exit 0 ;;
      --) shift; while [[ $# -gt 0 ]]; do parts+=("$1"); shift; done ;;
      -*) die "unknown option: $1" ;;
      *) parts+=("$1"); shift ;;
    esac
  done
  if [[ ${#parts[@]} -gt 0 ]]; then PROMPT="${parts[*]}"; fi
}
select_provider() {
  if [[ -z "$PROVIDER" ]]; then
    if [[ -n "${OPENAI_API_KEY:-}" ]]; then PROVIDER="openai"
    elif [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then PROVIDER="anthropic"
    elif [[ -n "${OPENROUTER_API_KEY:-}" ]]; then PROVIDER="openrouter"
    else die "set OPENAI_API_KEY, ANTHROPIC_API_KEY, or OPENROUTER_API_KEY"
    fi
  fi
  case "$PROVIDER" in
    openai)
      : "${OPENAI_API_KEY:?OPENAI_API_KEY is required}"
      MODEL="${MODEL:-${OPENAI_MODEL:-gpt-5.6-sol}}"
      FALLBACK_MODEL="${FALLBACK_MODEL:-${OPENAI_FALLBACK_MODEL:-gpt-5.6-terra}}"
      API_URL="${OPENAI_BASE_URL:-https://api.openai.com/v1}"
      ;;
    anthropic)
      : "${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY is required}"
      MODEL="${MODEL:-${ANTHROPIC_MODEL:-claude-opus-5}}"
      FALLBACK_MODEL="${FALLBACK_MODEL:-${ANTHROPIC_FALLBACK_MODEL:-claude-sonnet-5}}"
      API_URL="${ANTHROPIC_BASE_URL:-https://api.anthropic.com/v1}"
      ;;
    openrouter)
      : "${OPENROUTER_API_KEY:?OPENROUTER_API_KEY is required}"
      MODEL="${MODEL:-${OPENROUTER_MODEL:-openai/gpt-5.6-sol}}"
      FALLBACK_MODEL="${FALLBACK_MODEL:-${OPENROUTER_FALLBACK_MODEL:-openai/gpt-5.6-terra}}"
      API_URL="${OPENROUTER_BASE_URL:-https://openrouter.ai/api/v1}"
      ;;
    *) die "unsupported provider: $PROVIDER" ;;
  esac
  API_URL="${API_URL%/}"
}
validate_config() {
  case "$REASONING" in default|none|minimal|low|medium|high|xhigh|max) ;; *) die "invalid reasoning level: $REASONING" ;; esac
  is_uint "$MAX_TURNS" || die "--max-turns must be a positive integer"
  is_uint "$MAX_TOKENS" || die "--max-tokens must be a positive integer"
  is_uint "$COMPACT_TOKENS" || die "--compact-tokens must be a positive integer"
  is_uint "$COMPACT_MAX_TOKENS" || die "MINI_AGENT_COMPACT_MAX_TOKENS must be a positive integer"
  [[ -d "$WORKDIR" ]] || die "working directory does not exist: $WORKDIR"
  WORKDIR=$(cd "$WORKDIR" 2>/dev/null && pwd -P) || die "cannot enter working directory"
}
system_prompt() {
  if [[ "$PROVIDER" == "openai" ]]; then
    cat <<EOF
You are a capable software-engineering agent working in: $WORKDIR

Use the native shell tool for inspection, searches, builds, and tests. Use the apply_patch tool for file edits. Commands run locally in the working directory through Bash. Prefer common portable Unix utilities. To visually inspect an image, issue exactly one command of the form: mini-agent-read PATH. The harness intercepts that virtual command and attaches the image to your next turn.

Work autonomously until the task is complete. Inspect before changing, preserve unrelated work, and verify changes. Never claim a command succeeded unless its result says so. Keep final answers brief and include changed files and verification.
EOF
    return
  fi
  cat <<EOF
You are a concise, capable software-engineering agent working in: $WORKDIR

Use the read tool to inspect files, directories, and images. Use the bash tool for searches, builds, and tests, and apply_patch for file edits. Prefer common portable Unix utilities. Work autonomously until the task is complete. Inspect before changing, preserve unrelated work, and verify changes. Never claim a command succeeded unless its result says so. Keep final answers brief and include changed files and verification.
EOF
}
tools_compatible() {
  "$JQ_BIN" -cn '[
    {type:"function",function:{name:"read",description:"Read a text file, attach an image, or list a directory.",parameters:{type:"object",properties:{path:{type:"string",description:"Absolute path or path relative to the working directory"},offset:{type:"integer",minimum:1,description:"First line to read (default 1)"},limit:{type:"integer",minimum:1,maximum:2000,description:"Maximum lines or directory entries (default 250)"}},required:["path"],additionalProperties:false}}},
    {type:"function",function:{name:"bash",description:"Run a Bash command in the working directory. Use for searching, building, and testing.",parameters:{type:"object",properties:{command:{type:"string",description:"Bash command to execute"}},required:["command"],additionalProperties:false}}},
    {type:"function",function:{name:"apply_patch",description:"Edit files with Codex apply_patch syntax. The patch must start with *** Begin Patch and end with *** End Patch, using Add File, Delete File, or Update File sections and optional Move to headers.",parameters:{type:"object",properties:{patch:{type:"string",description:"Complete Codex apply_patch text"}},required:["patch"],additionalProperties:false}}}
  ]'
}
tools_openai() {
  "$JQ_BIN" -cn '[
    {type:"shell",environment:{type:"local"}},
    {type:"function",name:"apply_patch",description:"Edit files with Codex apply_patch syntax. Use an envelope from *** Begin Patch through *** End Patch with Add File, Delete File, or Update File sections and optional Move to headers.",parameters:{type:"object",properties:{patch:{type:"string",description:"Complete Codex apply_patch text"}},required:["patch"],additionalProperties:false},strict:false}
  ]'
}
tools_anthropic() {
  tools_compatible | "$JQ_BIN" -c '[.[] | {name:.function.name,description:.function.description,input_schema:.function.parameters}]'
}
api_request() {
  local url=$1 key_header=$2 key=$3 body=$4 response_file status curl_status
  shift 4
  response_file=$(mktemp "${TMPDIR:-/tmp}/mini-agent-response.XXXXXX") || return 1
  status=$("$CURL_BIN" -sS --connect-timeout 20 --max-time "$API_TIMEOUT" \
    -o "$response_file" -w '%{http_code}' -X POST "$url" \
    -H 'content-type: application/json' -H "$key_header: $key" "$@" \
    --data-binary @- <<< "$body")
  curl_status=$?
  API_RESPONSE=$(<"$response_file")
  rm -f "$response_file"
  if [[ $curl_status -ne 0 ]]; then
    printf 'network error (curl exit %s)\n' "$curl_status" >&2
    return 1
  fi
  if [[ ! "$status" =~ ^2 ]]; then
    printf 'API error HTTP %s: %s\n' "$status" "$(printf '%s' "$API_RESPONSE" | "$JQ_BIN" -r '.error.message // .error // .' 2>/dev/null)" >&2
    return 1
  fi
  if ! printf '%s' "$API_RESPONSE" | "$JQ_BIN" -e . >/dev/null 2>&1; then
    printf 'API returned invalid JSON\n' >&2
    return 1
  fi
}
call_openrouter() {
  local body tools reason_args='{}' key url
  local extra_headers=(-H "X-Title: ${OPENROUTER_APP_NAME:-mini-agent}")
  tools=$(tools_compatible)
  if [[ "$REASONING" != "default" ]]; then
    local effort=$REASONING
    [[ "$effort" == "max" ]] && effort="xhigh"
    reason_args=$("$JQ_BIN" -cn --arg e "$effort" '{reasoning:{effort:$e}}')
  fi
  body=$("$JQ_BIN" -cn --arg model "${TURN_MODEL:-$MODEL}" --arg system "$(system_prompt)" \
    --slurpfile history <(printf '%s\n' "$HISTORY") --argjson tools "$tools" --argjson extra "$reason_args" \
    --argjson max "$MAX_TOKENS" \
    '{model:$model,messages:([{role:"system",content:$system}] + $history[0]),tools:$tools,tool_choice:"auto",parallel_tool_calls:false,max_completion_tokens:$max} + $extra')
  key=$OPENROUTER_API_KEY; url="$API_URL/chat/completions"
  [[ -n "${OPENROUTER_HTTP_REFERER:-}" ]] && extra_headers+=( -H "HTTP-Referer: $OPENROUTER_HTTP_REFERER" )
  [[ -n "${OPENROUTER_APP_NAME:-}" ]] && extra_headers+=( -H "X-Title: $OPENROUTER_APP_NAME" )
  api_request "$url" "authorization" "Bearer $key" "$body" "${extra_headers[@]}" || return 1
  if printf '%s' "$API_RESPONSE" | "$JQ_BIN" -e '.error' >/dev/null 2>&1; then
    printf 'API error: %s\n' "$(printf '%s' "$API_RESPONSE" | "$JQ_BIN" -r '.error.message // .error')" >&2
    return 1
  fi
}
call_openai_responses() {
  local input=$1 body tools reason_args='{}' previous_args='{}' effort
  tools=$(tools_openai)
  if [[ "$REASONING" != "default" ]]; then
    effort=$REASONING
    [[ "$effort" == "minimal" ]] && effort="low"
    reason_args=$("$JQ_BIN" -cn --arg e "$effort" '{reasoning:{effort:$e}}')
  fi
  if [[ -n "$OPENAI_PREVIOUS_RESPONSE_ID" ]]; then
    previous_args=$("$JQ_BIN" -cn --arg id "$OPENAI_PREVIOUS_RESPONSE_ID" '{previous_response_id:$id}')
  fi
  body=$("$JQ_BIN" -cn --arg model "${TURN_MODEL:-$MODEL}" --arg instructions "$(system_prompt)" \
    --slurpfile input <(printf '%s\n' "$input") --argjson reason "$reason_args" \
    --argjson previous "$previous_args" --argjson tools "$tools" --argjson max "$MAX_TOKENS" \
    '{model:$model,instructions:$instructions,input:$input[0],tools:$tools,tool_choice:"auto",parallel_tool_calls:false,max_output_tokens:$max} + $reason + $previous')
  api_request "$API_URL/responses" "authorization" "Bearer $OPENAI_API_KEY" "$body" || return 1
  if printf '%s' "$API_RESPONSE" | "$JQ_BIN" -e '.error != null or .status == "failed"' >/dev/null 2>&1; then
    printf 'API error: %s\n' "$(printf '%s' "$API_RESPONSE" | "$JQ_BIN" -r '.error.message // .error // "response failed"')" >&2
    return 1
  fi
  OPENAI_PREVIOUS_RESPONSE_ID=$(printf '%s' "$API_RESPONSE" | "$JQ_BIN" -r '.id // empty')
  [[ -n "$OPENAI_PREVIOUS_RESPONSE_ID" ]] || { printf 'API response missing id\n' >&2; return 1; }
}
call_anthropic() {
  local body tools thinking='{}'
  tools=$(tools_anthropic)
  case "$REASONING" in
    default) thinking='{}' ;;
    none) thinking='{"thinking":{"type":"disabled"}}' ;;
    *)
      local effort=$REASONING
      [[ "$effort" == "minimal" ]] && effort="low"
      thinking=$("$JQ_BIN" -cn --arg e "$effort" '{thinking:{type:"adaptive"},output_config:{effort:$e}}')
      ;;
  esac
  body=$("$JQ_BIN" -cn --arg model "${TURN_MODEL:-$MODEL}" --arg system "$(system_prompt)" \
    --slurpfile history <(printf '%s\n' "$HISTORY") --argjson tools "$tools" --argjson extra "$thinking" \
    --argjson max "$MAX_TOKENS" \
    '{model:$model,system:$system,messages:$history[0],tools:$tools,tool_choice:{type:"auto"},max_tokens:$max} + $extra')
  api_request "$API_URL/messages" "x-api-key" "$ANTHROPIC_API_KEY" "$body" \
    -H "anthropic-version: ${ANTHROPIC_VERSION:-2023-06-01}" || return 1
  if printf '%s' "$API_RESPONSE" | "$JQ_BIN" -e '.type == "error"' >/dev/null 2>&1; then
    printf 'API error: %s\n' "$(printf '%s' "$API_RESPONSE" | "$JQ_BIN" -r '.error.message // .error')" >&2
    return 1
  fi
}
response_is_refusal() {
  case "$PROVIDER" in
    anthropic) printf '%s' "$API_RESPONSE" | "$JQ_BIN" -e '.stop_reason == "refusal"' ;;
    openai) printf '%s' "$API_RESPONSE" | "$JQ_BIN" -e 'any(.output[]?.content[]?; .type == "refusal")' ;;
    openrouter) printf '%s' "$API_RESPONSE" | "$JQ_BIN" -e '.choices[0].finish_reason == "content_filter" or ((.choices[0].message.refusal? // null) as $r | $r != null and $r != "")' ;;
  esac >/dev/null 2>&1
}
refusal_reason() {
  case "$PROVIDER" in
    anthropic) printf '%s' "$API_RESPONSE" | "$JQ_BIN" -r '.stop_details.explanation // "safety refusal"' ;;
    openai) printf '%s' "$API_RESPONSE" | "$JQ_BIN" -r '[.output[]?.content[]? | select(.type == "refusal") | .refusal] | first // "safety refusal"' ;;
    openrouter) printf '%s' "$API_RESPONSE" | "$JQ_BIN" -r '.choices[0].message.refusal // .choices[0].finish_reason // "safety refusal" | if type == "string" then . else tojson end' ;;
  esac
}
call_with_fallback() {
  local fn=$1 previous=$OPENAI_PREVIOUS_RESPONSE_ID refused reason
  shift
  "$fn" "$@" || return 1
  response_is_refusal || return 0
  refused=${TURN_MODEL:-$MODEL}; reason=$(refusal_reason)
  if [[ -z "$FALLBACK_MODEL" || "$FALLBACK_MODEL" == "none" || "$FALLBACK_MODEL" == "$refused" ]]; then
    OPENAI_PREVIOUS_RESPONSE_ID=$previous; LAST_ANSWER="Model $refused refused the request: $reason"; printf '%s\n' "$LAST_ANSWER" >&2; return 1
  fi
  info "${C_CYAN}fallback${C_RESET} $refused refused: $reason; retrying with $FALLBACK_MODEL"
  OPENAI_PREVIOUS_RESPONSE_ID=$previous; TURN_MODEL=$FALLBACK_MODEL
  "$fn" "$@" || return 1
  if response_is_refusal; then
    OPENAI_PREVIOUS_RESPONSE_ID=$previous; reason=$(refusal_reason); LAST_ANSWER="Fallback model $TURN_MODEL refused the request: $reason"
    printf '%s\n' "$LAST_ANSWER" >&2; return 1
  fi
}
response_context_tokens() {
  case "$PROVIDER" in
    openai)
      printf '%s' "$API_RESPONSE" | "$JQ_BIN" -r \
        '(.usage.total_tokens // ((.usage.input_tokens // 0) + (.usage.output_tokens // 0))) | floor'
      ;;
    anthropic)
      printf '%s' "$API_RESPONSE" | "$JQ_BIN" -r \
        '((.usage.input_tokens // 0) + (.usage.output_tokens // 0) + (.usage.cache_read_input_tokens // 0) + (.usage.cache_creation_input_tokens // 0)) | floor'
      ;;
    openrouter)
      printf '%s' "$API_RESPONSE" | "$JQ_BIN" -r \
        '(.usage.total_tokens // ((.usage.prompt_tokens // 0) + (.usage.completion_tokens // 0))) | floor'
      ;;
  esac
}
serialization_prompt() {
  "$JQ_BIN" -r '
    def clipped:
      if length <= 2000 then . else .[0:1000] + "\n... " + ((length - 2000)|tostring) + " characters omitted ...\n" + .[-1000:] end;
    def body:
      ((if (.content // null) == null then "" elif (.content|type) == "string" then .content else (.content|tojson) end) +
       (if (.tool_calls // [] | length) > 0 then "\n[tool calls] " + (.tool_calls|tojson) else "" end)) | clipped;
    map("[" + ((.role // "message") | ascii_upcase) + "]: " + body) | join("\n\n")'
}
compaction_system_prompt() {
  cat <<'EOF'
You create context checkpoint summaries for another coding agent. Preserve exact file paths, function names, commands, errors, constraints, decisions, and unfinished work. Do not continue the task or call tools.
EOF
}
compaction_user_prompt() {
  local conversation=$1
  cat <<EOF
<conversation>
$conversation
</conversation>

The messages above are a conversation to summarize. Create a structured context checkpoint using exactly these sections:

## Goal
## Constraints & Preferences
## Progress
### Done
### In Progress
### Blocked
## Key Decisions
## Next Steps
## Critical Context

Keep it concise and suitable for another model to continue without duplicating work.
EOF
}
call_compaction_summary() {
  local prompt=$1 body max=$COMPACT_MAX_TOKENS summary refused reason
  [[ "$max" -gt "$MAX_TOKENS" ]] && max=$MAX_TOKENS
  case "$PROVIDER" in
    openai)
      body=$("$JQ_BIN" -cn --arg model "${TURN_MODEL:-$MODEL}" --arg instructions "$(compaction_system_prompt)" \
        --arg prompt "$prompt" --argjson max "$max" \
        '{model:$model,instructions:$instructions,input:[{role:"user",content:[{type:"input_text",text:$prompt}]}],max_output_tokens:$max}')
      api_request "$API_URL/responses" "authorization" "Bearer $OPENAI_API_KEY" "$body" || return 1
      summary=$(printf '%s' "$API_RESPONSE" | "$JQ_BIN" -r \
        '[.output[]? | select(.type == "message") | .content[]? | select(.type == "output_text") | .text] | join("\n")')
      ;;
    anthropic)
      body=$("$JQ_BIN" -cn --arg model "${TURN_MODEL:-$MODEL}" --arg system "$(compaction_system_prompt)" \
        --arg prompt "$prompt" --argjson max "$max" \
        '{model:$model,system:$system,messages:[{role:"user",content:$prompt}],max_tokens:$max}')
      api_request "$API_URL/messages" "x-api-key" "$ANTHROPIC_API_KEY" "$body" \
        -H "anthropic-version: ${ANTHROPIC_VERSION:-2023-06-01}" || return 1
      summary=$(printf '%s' "$API_RESPONSE" | "$JQ_BIN" -r '[.content[]? | select(.type == "text") | .text] | join("\n")')
      ;;
    openrouter)
      body=$("$JQ_BIN" -cn --arg model "${TURN_MODEL:-$MODEL}" --arg system "$(compaction_system_prompt)" \
        --arg prompt "$prompt" --argjson max "$max" \
        '{model:$model,messages:[{role:"system",content:$system},{role:"user",content:$prompt}],max_completion_tokens:$max}')
      local headers=(-H "X-Title: ${OPENROUTER_APP_NAME:-mini-agent}")
      [[ -n "${OPENROUTER_HTTP_REFERER:-}" ]] && headers+=( -H "HTTP-Referer: $OPENROUTER_HTTP_REFERER" )
      api_request "$API_URL/chat/completions" "authorization" "Bearer $OPENROUTER_API_KEY" "$body" "${headers[@]}" || return 1
      summary=$(printf '%s' "$API_RESPONSE" | "$JQ_BIN" -r '.choices[0].message.content // ""')
      ;;
  esac
  if response_is_refusal; then
    refused=${TURN_MODEL:-$MODEL}; reason=$(refusal_reason)
    if [[ -n "$FALLBACK_MODEL" && "$FALLBACK_MODEL" != "none" && "$FALLBACK_MODEL" != "$refused" ]]; then
      info "${C_CYAN}fallback${C_RESET} $refused refused compaction: $reason; retrying with $FALLBACK_MODEL"
      TURN_MODEL=$FALLBACK_MODEL; call_compaction_summary "$prompt"; return
    fi
    printf 'compaction model %s refused: %s\n' "$refused" "$reason" >&2; return 1
  fi
  [[ -n "$summary" ]] || { printf 'compaction returned an empty summary\n' >&2; return 1; }
  COMPACTION_SUMMARY=$summary
}
compact_history() {
  local cut old kept conversation prompt summary prefix
  cut=$(printf '%s' "$HISTORY" | "$JQ_BIN" -r '
    ([to_entries[] | select(.value.role == "user" and (.value.content|type) == "string") | .key] | last // -1) as $user |
    (.[0].content? | type == "string" and startswith("Another language model worked on this task")) as $already_compacted |
    if $user > 0 and (($already_compacted and $user == 1) | not) then $user
    else ([to_entries[] | select(.value.role == "assistant" and .key > 0) | .key] | last // -1) end')
  [[ "$cut" -gt 0 ]] || { printf 'context is too large but has no safe compaction boundary\n' >&2; return 1; }
  old=$(printf '%s' "$HISTORY" | "$JQ_BIN" -c --argjson cut "$cut" '.[0:$cut]')
  kept=$(printf '%s' "$HISTORY" | "$JQ_BIN" -c --argjson cut "$cut" '.[$cut:]')
  conversation=$(printf '%s' "$old" | serialization_prompt)
  prompt=$(compaction_user_prompt "$conversation")
  call_compaction_summary "$prompt" || return 1
  summary=$COMPACTION_SUMMARY
  prefix="Another language model worked on this task and produced a context checkpoint. Use it to continue without duplicating effort:\n\n$summary"
  HISTORY=$("$JQ_BIN" -cn --arg prefix "$prefix" --argjson kept "$kept" '[{role:"user",content:$prefix}] + $kept')
  CONTEXT_TOKENS=0
  if [[ "$PROVIDER" == "openai" ]]; then
    OPENAI_PREVIOUS_RESPONSE_ID=""
    OPENAI_NEEDS_RESTART=1
  fi
}
maybe_compact() {
  [[ "$CONTEXT_TOKENS" -ge "$COMPACT_TOKENS" ]] || return 0
  info "${C_CYAN}compact${C_RESET} context $CONTEXT_TOKENS/$COMPACT_TOKENS tokens"
  compact_history
}
openai_history_input() {
  local conversation
  conversation=$(printf '%s' "$HISTORY" | serialization_prompt)
  "$JQ_BIN" -cn --arg text "Continue from this compacted conversation context:\n\n$conversation" \
    '[{role:"user",content:[{type:"input_text",text:$text}]}]'
}

record_openai_response() {
  local content
  content=$(printf '%s' "$API_RESPONSE" | "$JQ_BIN" -r '
    [.output[]? |
      if .type == "message" then ([.content[]? | select(.type == "output_text") | .text] | join("\n"))
      elif .type == "shell_call" then "[shell call] " + (.action.commands | join("; "))
      elif .type == "function_call" then "[tool call] " + .name + " " + (.arguments // "{}")
      else empty end] | map(select(length > 0)) | join("\n")')
  [[ -n "$content" ]] || return 0
  HISTORY=$("$JQ_BIN" -cn --argjson history "$HISTORY" --arg content "$content" '$history + [{role:"assistant",content:$content}]')
}

record_openai_tool_result() {
  local name=$1 text=$2
  HISTORY=$("$JQ_BIN" -cn --argjson history "$HISTORY" --arg name "$name" --arg text "$text" \
    '$history + [{role:"tool",name:$name,content:$text}]')
}

mime_type() {
  if command -v file >/dev/null 2>&1; then file -b --mime-type "$1" 2>/dev/null && return; fi
  case "$1" in *.png) echo image/png;; *.jpg|*.jpeg) echo image/jpeg;; *.gif) echo image/gif;; *.webp) echo image/webp;; *) echo application/octet-stream;; esac
}

b64_file() { base64 < "$1" | tr -d '\r\n'; }

image_result() {
  local path=$1 text=$2 mime=$3
  "$JQ_BIN" -Rsc --arg text "$text" --arg mime "$mime" \
    '{kind:"image",text:$text,media_type:$mime,data:.}' < <(b64_file "$path")
}

number_lines() {
  local offset=$1 limit=$2
  awk -v first="$offset" -v last="$((offset + limit - 1))" 'NR >= first && NR <= last {printf "%6d\t%s\n", NR, $0} NR > last {exit}'
}

read_file() {
  local requested=$1 offset=${2:-1} limit=${3:-250} path mime text
  [[ "$offset" =~ ^[1-9][0-9]*$ ]] || offset=1
  [[ "$limit" =~ ^[1-9][0-9]*$ ]] || limit=250
  [[ "$limit" -gt 2000 ]] && limit=2000
  if [[ "$requested" = /* ]]; then path=$requested; else path="$WORKDIR/$requested"; fi
  if [[ ! -e "$path" ]]; then "$JQ_BIN" -cn --arg t "Not found: $requested" '{kind:"error",text:$t}'; return; fi
  case "$path" in *.pdf|*.PDF) "$JQ_BIN" -cn '{kind:"error",text:"PDF files are not supported by the read tool."}'; return ;; esac
  if [[ -d "$path" ]]; then
    text=$(find "$path" -mindepth 1 -maxdepth 1 -print 2>/dev/null | sort | awk -v n="$limit" 'NR<=n')
    "$JQ_BIN" -cn --arg text "$text" '{kind:"text",text:$text}'
    return
  fi
  mime=$(mime_type "$path")
  case "$mime" in
    image/png|image/jpeg|image/gif|image/webp)
      image_result "$path" "Image attached: $requested ($mime)" "$mime"
      ;;
    application/pdf) "$JQ_BIN" -cn '{kind:"error",text:"PDF files are not supported by the read tool."}' ;;
    text/*|application/json|application/xml|application/javascript|application/x-shellscript)
      text=$(number_lines "$offset" "$limit" < "$path")
      "$JQ_BIN" -cn --arg text "$text" '{kind:"text",text:$text}'
      ;;
    *)
      if command -v strings >/dev/null 2>&1; then text=$(strings "$path" 2>/dev/null | number_lines "$offset" "$limit")
      else text="Binary file: $requested ($mime)"; fi
      "$JQ_BIN" -cn --arg text "$text" '{kind:"text",text:$text}'
      ;;
  esac
}

truncate_file() {
  local path=$1 size half
  size=$(wc -c < "$path" | tr -d ' ')
  if [[ "$size" -le "$MAX_TOOL_OUTPUT" ]]; then cat "$path"; return; fi
  half=$((MAX_TOOL_OUTPUT / 2))
  head -c "$half" "$path"
  printf '\n... %s bytes omitted ...\n' "$((size - MAX_TOOL_OUTPUT))"
  tail -c "$half" "$path"
}

run_bash() {
  local command_text=$1 tmp status output timer=()
  tmp=$(mktemp "${TMPDIR:-/tmp}/mini-agent-tool.XXXXXX") || return 1
  if command -v timeout >/dev/null 2>&1; then timer=(timeout "$TOOL_TIMEOUT")
  elif command -v gtimeout >/dev/null 2>&1; then timer=(gtimeout "$TOOL_TIMEOUT"); fi
  (cd "$WORKDIR" && "${timer[@]}" bash -lc "$command_text") > "$tmp" 2>&1
  status=$?
  output=$(truncate_file "$tmp")
  rm -f "$tmp"
  [[ -n "$output" ]] || output="(no output)"
  "$JQ_BIN" -cn --arg text "$output\n\n[exit status: $status]" --argjson status "$status" \
    '{kind:"text",text:$text,exit_status:$status}'
}

safe_patch_path() {
  local requested=$1 rest part current=$WORKDIR
  case "$requested" in ""|/*|.|..|./*|../*|*/./*|*/../*|*/.|*/..) return 1 ;; esac
  rest=$requested
  while [[ "$rest" == */* ]]; do
    part=${rest%%/*}; rest=${rest#*/}
    [[ -n "$part" ]] || return 1
    current="$current/$part"
    [[ ! -L "$current" ]] || return 1
  done
  [[ -n "$rest" && ! -L "$current/$rest" ]]
}

apply_update_section() {
  local source=$1 section=$2 output=$3
  awk -v patch_file="$section" -v source_name="$source" '
    function fail(message) { print message > "/dev/stderr"; failed=1; exit 2 }
    function rstrip(value) { sub(/[ \t\r]+$/, "", value); return value }
    function trim(value) { sub(/^[ \t\r]+/, "", value); sub(/[ \t\r]+$/, "", value); return value }
    function equal_line(a, b, mode) {
      if (mode == 1) return a == b
      if (mode == 2) return rstrip(a) == rstrip(b)
      return trim(a) == trim(b)
    }
    function seek_line(value, first,    mode,i) {
      for (mode=1; mode<=3; mode++) for (i=first; i<=line_count; i++) if (equal_line(lines[i], value, mode)) return i
      return 0
    }
    function sequence_matches(pos, chunk, mode,    j) {
      for (j=1; j<=old_count[chunk]; j++) if (!equal_line(lines[pos+j-1], old[chunk,j], mode)) return 0
      return 1
    }
    function seek_sequence(chunk, first, eof,    mode,i,last,start) {
      if (old_count[chunk] == 0) return first
      last=line_count-old_count[chunk]+1
      if (last < first) return 0
      start=eof ? last : first
      for (mode=1; mode<=3; mode++) for (i=start; i<=last; i++) if (sequence_matches(i, chunk, mode)) return i
      return 0
    }
    { lines[++line_count]=$0 }
    END {
      if (failed) exit 2
      while ((getline patch_line < patch_file) > 0) {
        sub(/\r$/, "", patch_line)
        if (patch_line == "@@" || substr(patch_line,1,3) == "@@ ") {
          chunk_count++
          if (length(patch_line) > 3) context[chunk_count]=substr(patch_line,4)
        } else if (patch_line == "*** End of File") {
          if (chunk_count == 0) fail("Invalid patch: End of File outside a hunk")
          at_eof[chunk_count]=1
        } else {
          if (chunk_count == 0) fail("Invalid patch: update lines must follow @@")
          prefix=substr(patch_line,1,1); value=substr(patch_line,2)
          if (prefix == " " || prefix == "-") old[chunk_count,++old_count[chunk_count]]=value
          if (prefix == " " || prefix == "+") new[chunk_count,++new_count[chunk_count]]=value
          if (prefix != " " && prefix != "-" && prefix != "+") fail("Invalid patch line: " patch_line)
        }
      }
      close(patch_file)
      if (chunk_count == 0) fail("Invalid patch: update has no hunks")
      cursor=1
      for (chunk=1; chunk<=chunk_count; chunk++) {
        if (context[chunk] != "") {
          found=seek_line(context[chunk],cursor)
          if (!found) fail("Failed to find context \"" context[chunk] "\" in " source_name)
          cursor=found+1
        }
        if (old_count[chunk] == 0) found=line_count+1
        else found=seek_sequence(chunk,cursor,at_eof[chunk])
        if (!found) {
          expected=""; for (j=1; j<=old_count[chunk]; j++) expected=expected (j>1 ? "\\n" : "") old[chunk,j]
          fail("Failed to find expected lines in " source_name ": " expected)
        }
        replace_at[chunk]=found
        cursor=found+old_count[chunk]
      }
      for (chunk=chunk_count; chunk>=1; chunk--) {
        start=replace_at[chunk]; removed=old_count[chunk]; added=new_count[chunk]; delta=added-removed
        if (delta > 0) for (i=line_count; i>=start+removed; i--) lines[i+delta]=lines[i]
        else if (delta < 0) for (i=start+removed; i<=line_count; i++) lines[i+delta]=lines[i]
        for (i=1; i<=added; i++) lines[start+i-1]=new[chunk,i]
        line_count+=delta
      }
      for (i=1; i<=line_count; i++) print lines[i]
    }
  ' "$source" > "$output"
}

apply_patch_section() {
  local action=$1 path=$2 move=$3 section=$4 target parent tmp
  safe_patch_path "$path" || { printf 'Invalid patch path: %s\n' "$path" >&2; return 1; }
  target="$WORKDIR/$path"
  case "$action" in
    add)
      parent=${target%/*}; [[ "$parent" != "$target" ]] || parent=$WORKDIR
      mkdir -p "$parent" || return 1
      [[ -s "$section" ]] || { printf 'Invalid Add File section: %s\n' "$path" >&2; return 1; }
      tmp=$(mktemp "${TMPDIR:-/tmp}/mini-agent-patch.XXXXXX") || return 1
      awk 'substr($0,1,1)!="+" {print "Invalid Add File line: " $0 > "/dev/stderr"; exit 2} {print substr($0,2)}' \
        "$section" > "$tmp" || { rm -f "$tmp"; return 1; }
      cp "$tmp" "$target" || { rm -f "$tmp"; return 1; }
      rm -f "$tmp"
      printf 'A %s\n' "$path"
      ;;
    delete)
      [[ ! -s "$section" ]] || { printf 'Invalid Delete File section: %s\n' "$path" >&2; return 1; }
      [[ -f "$target" ]] || { printf 'Failed to delete missing file: %s\n' "$path" >&2; return 1; }
      rm "$target" || return 1
      printf 'D %s\n' "$path"
      ;;
    update)
      [[ -f "$target" ]] || { printf 'Failed to read file to update: %s\n' "$path" >&2; return 1; }
      tmp=$(mktemp "${TMPDIR:-/tmp}/mini-agent-patch.XXXXXX") || return 1
      if [[ -s "$section" ]]; then apply_update_section "$target" "$section" "$tmp" || { rm -f "$tmp"; return 1; }
      else cp "$target" "$tmp" || { rm -f "$tmp"; return 1; }
      fi
      if [[ -n "$move" ]]; then
        safe_patch_path "$move" || { printf 'Invalid move path: %s\n' "$move" >&2; rm -f "$tmp"; return 1; }
        parent="$WORKDIR/${move%/*}"; [[ "$move" == */* ]] || parent=$WORKDIR
        mkdir -p "$parent" || { rm -f "$tmp"; return 1; }
        cp "$tmp" "$WORKDIR/$move" && rm "$target" || { rm -f "$tmp"; return 1; }
      else
        cp "$tmp" "$target" || { rm -f "$tmp"; return 1; }
      fi
      rm -f "$tmp"
      printf 'M %s%s\n' "$path" "${move:+ -> $move}"
      ;;
  esac
}

apply_patch_text() {
  local patch=$1 patch_file section action="" path="" move="" line first=1 ended=0 count=0 summary="" result
  patch_file=$(mktemp "${TMPDIR:-/tmp}/mini-agent-patch-input.XXXXXX") || return 1
  section=$(mktemp "${TMPDIR:-/tmp}/mini-agent-patch-section.XXXXXX") || { rm -f "$patch_file"; return 1; }
  printf '%s\n' "$patch" > "$patch_file"
  : > "$section"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%$'\r'}
    if [[ "$first" -eq 1 ]]; then
      first=0
      [[ "$line" == "*** Begin Patch" ]] || { printf 'Invalid patch: missing Begin Patch marker\n' >&2; rm -f "$patch_file" "$section"; return 1; }
      continue
    fi
    case "$line" in
      "*** Add File: "*|"*** Delete File: "*|"*** Update File: "*|"*** End Patch")
        if [[ -n "$action" ]]; then
          result=$(apply_patch_section "$action" "$path" "$move" "$section") || { rm -f "$patch_file" "$section"; return 1; }
          summary="${summary}${result}"$'\n'; count=$((count + 1))
          action=""; path=""; move=""; : > "$section"
        fi
        case "$line" in
          "*** Add File: "*) action=add; path=${line#"*** Add File: "} ;;
          "*** Delete File: "*) action=delete; path=${line#"*** Delete File: "} ;;
          "*** Update File: "*) action=update; path=${line#"*** Update File: "} ;;
          "*** End Patch") ended=1 ;;
        esac
        ;;
      "*** Move to: "*)
        [[ "$action" == update && -z "$move" && ! -s "$section" ]] || { printf 'Invalid Move to header\n' >&2; rm -f "$patch_file" "$section"; return 1; }
        move=${line#"*** Move to: "}
        ;;
      *)
        [[ "$ended" -eq 0 && -n "$action" ]] || { printf 'Invalid patch line: %s\n' "$line" >&2; rm -f "$patch_file" "$section"; return 1; }
        printf '%s\n' "$line" >> "$section"
        ;;
    esac
  done < "$patch_file"
  rm -f "$patch_file" "$section"
  [[ "$ended" -eq 1 && "$count" -gt 0 ]] || { printf 'Invalid patch: missing End Patch marker or file sections\n' >&2; return 1; }
  printf 'Success. Updated the following files:\n%s' "$summary"
}

run_apply_patch() {
  local patch=$1 output status
  output=$(apply_patch_text "$patch" 2>&1); status=$?
  [[ -n "$output" ]] || output="No files were modified."
  "$JQ_BIN" -cn --arg text "$output" --argjson status "$status" '{kind:"text",text:$text,exit_status:$status}'
}

native_attachment() {
  local requested=$1 path mime
  if [[ "$requested" = /* ]]; then path=$requested; else path="$WORKDIR/$requested"; fi
  if [[ ! -f "$path" ]]; then "$JQ_BIN" -cn --arg e "Not found: $requested" '{error:$e}'; return; fi
  case "$path" in *.pdf|*.PDF) "$JQ_BIN" -cn '{error:"PDF files are not supported by mini-agent-read."}'; return ;; esac
  mime=$(mime_type "$path")
  case "$mime" in
    image/png|image/jpeg|image/gif|image/webp)
      "$JQ_BIN" -Rsc --arg mime "$mime" '{type:"input_image",image_url:("data:"+$mime+";base64,"+.)}' < <(b64_file "$path")
      ;;
    application/pdf) "$JQ_BIN" -cn '{error:"PDF files are not supported by mini-agent-read."}' ;;
    *) "$JQ_BIN" -cn --arg e "mini-agent-read supports images only; use shell utilities for $mime" '{error:$e}' ;;
  esac
}

run_native_command() {
  local command_text=$1 requested_limit=$2 timeout_seconds=$3 out_file err_file status stdout stderr cap timer=()
  out_file=$(mktemp "${TMPDIR:-/tmp}/mini-agent-stdout.XXXXXX") || return 1
  err_file=$(mktemp "${TMPDIR:-/tmp}/mini-agent-stderr.XXXXXX") || { rm -f "$out_file"; return 1; }
  cap=$requested_limit
  [[ "$cap" =~ ^[1-9][0-9]*$ ]] || cap=$MAX_TOOL_OUTPUT
  [[ "$cap" -gt "$MAX_TOOL_OUTPUT" ]] && cap=$MAX_TOOL_OUTPUT
  [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || timeout_seconds=$TOOL_TIMEOUT
  [[ "$timeout_seconds" -gt "$TOOL_TIMEOUT" ]] && timeout_seconds=$TOOL_TIMEOUT
  if command -v timeout >/dev/null 2>&1; then timer=(timeout "$timeout_seconds")
  elif command -v gtimeout >/dev/null 2>&1; then timer=(gtimeout "$timeout_seconds"); fi
  info "${C_CYAN}shell${C_RESET} $command_text"
  (cd "$WORKDIR" && "${timer[@]}" bash -lc "$command_text") > "$out_file" 2> "$err_file"
  status=$?
  stdout=$(MAX_TOOL_OUTPUT=$cap truncate_file "$out_file")
  stderr=$(MAX_TOOL_OUTPUT=$cap truncate_file "$err_file")
  rm -f "$out_file" "$err_file"
  if [[ "$status" -eq 124 || "$status" -eq 137 ]]; then
    "$JQ_BIN" -cn --arg stdout "$stdout" --arg stderr "$stderr" \
      '{stdout:$stdout,stderr:$stderr,outcome:{type:"timeout"}}'
  else
    "$JQ_BIN" -cn --arg stdout "$stdout" --arg stderr "$stderr" --argjson status "$status" \
      '{stdout:$stdout,stderr:$stderr,outcome:{type:"exit",exit_code:$status}}'
  fi
}

process_openai_shell_calls() {
  local next='[]' attachments='[]' call type call_id name args requested_limit timeout_ms timeout_seconds outputs command_text result result_text attachment error tool_output message
  while IFS= read -r call; do
    [[ -n "$call" ]] || continue
    type=$(printf '%s' "$call" | "$JQ_BIN" -r '.type')
    call_id=$(printf '%s' "$call" | "$JQ_BIN" -r '.call_id')
    if [[ "$type" == "function_call" ]]; then
      name=$(printf '%s' "$call" | "$JQ_BIN" -r '.name')
      args=$(printf '%s' "$call" | "$JQ_BIN" -r '.arguments // "{}"' | "$JQ_BIN" -c '.' 2>/dev/null) || args='{}'
      result=$(run_tool "$name" "$args")
      result_text=$(printf '%s' "$result" | "$JQ_BIN" -r '.text')
      tool_output=$("$JQ_BIN" -cn --arg id "$call_id" --arg output "$result_text" \
        '{type:"function_call_output",call_id:$id,output:$output}')
      next=$("$JQ_BIN" -cs '.[0] + [.[1]]' <(printf '%s\n' "$next") <(printf '%s\n' "$tool_output"))
      record_openai_tool_result "$name" "$result_text"
      continue
    fi
    requested_limit=$(printf '%s' "$call" | "$JQ_BIN" -r ".action.max_output_length // $MAX_TOOL_OUTPUT")
    timeout_ms=$(printf '%s' "$call" | "$JQ_BIN" -r ".action.timeout_ms // ($TOOL_TIMEOUT * 1000)")
    timeout_seconds=$(( (timeout_ms + 999) / 1000 ))
    outputs='[]'
    while IFS= read -r command_text; do
      [[ -n "$command_text" ]] || continue
      if [[ "$command_text" == "mini-agent-read "* ]]; then
        local requested=${command_text#mini-agent-read }
        case "$requested" in
          \"*\") requested=${requested#\"}; requested=${requested%\"} ;;
          \'*\') requested=${requested#\'}; requested=${requested%\'} ;;
        esac
        info "${C_CYAN}read attachment${C_RESET} $requested"
        attachment=$(native_attachment "$requested")
        error=$(printf '%s' "$attachment" | "$JQ_BIN" -r '.error // empty')
        if [[ -n "$error" ]]; then
          result=$("$JQ_BIN" -cn --arg error "$error" '{stdout:"",stderr:$error,outcome:{type:"exit",exit_code:1}}')
        else
          result=$("$JQ_BIN" -cn --arg text "Attached $requested to the next model turn." '{stdout:$text,stderr:"",outcome:{type:"exit",exit_code:0}}')
          attachments=$("$JQ_BIN" -cs '.[0] + [.[1]]' \
            <(printf '%s\n' "$attachments") <(printf '%s\n' "$attachment"))
        fi
      else
        result=$(run_native_command "$command_text" "$requested_limit" "$timeout_seconds")
      fi
      outputs=$("$JQ_BIN" -cs '.[0] + [.[1]]' \
        <(printf '%s\n' "$outputs") <(printf '%s\n' "$result"))
    done < <(printf '%s' "$call" | "$JQ_BIN" -r '.action.commands[]')
    tool_output=$("$JQ_BIN" -cn --arg id "$call_id" --argjson max "$requested_limit" \
      --slurpfile outputs <(printf '%s\n' "$outputs") \
      '{type:"shell_call_output",call_id:$id,max_output_length:$max,output:$outputs[0]}')
    next=$("$JQ_BIN" -cs '.[0] + [.[1]]' \
      <(printf '%s\n' "$next") <(printf '%s\n' "$tool_output"))
    record_openai_tool_result "shell" "$(printf '%s' "$outputs" | "$JQ_BIN" -c '.')"
  done < <(printf '%s' "$API_RESPONSE" | "$JQ_BIN" -c '.output[] | select(.type == "shell_call" or .type == "function_call")')
  if [[ $(printf '%s' "$attachments" | "$JQ_BIN" 'length') -gt 0 ]]; then
    message=$("$JQ_BIN" -cn --slurpfile files <(printf '%s\n' "$attachments") \
      '{role:"user",content:([{type:"input_text",text:"Files requested through mini-agent-read are attached."}] + $files[0])}')
    next=$("$JQ_BIN" -cs '.[0] + [.[1]]' \
      <(printf '%s\n' "$next") <(printf '%s\n' "$message"))
  fi
  OPENAI_NEXT_INPUT=$next
}

run_tool() {
  local name=$1 input=$2 command_text patch path offset limit
  case "$name" in
    read)
      path=$(printf '%s' "$input" | "$JQ_BIN" -r '.path // empty')
      offset=$(printf '%s' "$input" | "$JQ_BIN" -r '.offset // 1')
      limit=$(printf '%s' "$input" | "$JQ_BIN" -r '.limit // 250')
      [[ -n "$path" ]] || { "$JQ_BIN" -cn '{kind:"error",text:"read requires path"}'; return; }
      info "${C_CYAN}read${C_RESET} $path"
      read_file "$path" "$offset" "$limit"
      ;;
    bash)
      command_text=$(printf '%s' "$input" | "$JQ_BIN" -r '.command // empty')
      [[ -n "$command_text" ]] || { "$JQ_BIN" -cn '{kind:"error",text:"bash requires command"}'; return; }
      info "${C_CYAN}bash${C_RESET} $command_text"
      run_bash "$command_text"
      ;;
    apply_patch)
      patch=$(printf '%s' "$input" | "$JQ_BIN" -r '.patch // empty')
      [[ -n "$patch" ]] || { "$JQ_BIN" -cn '{kind:"error",text:"apply_patch requires patch"}'; return; }
      info "${C_CYAN}apply_patch${C_RESET}"
      run_apply_patch "$patch"
      ;;
    *) "$JQ_BIN" -cn --arg t "Unknown tool: $name" '{kind:"error",text:$t}' ;;
  esac
}

process_openai_calls() {
  local assistant calls images='[]' id name args result result_text tool_message
  assistant=$(printf '%s' "$API_RESPONSE" | "$JQ_BIN" -c '.choices[0].message')
  HISTORY=$("$JQ_BIN" -cs '.[0] + [.[1]]' \
    <(printf '%s\n' "$HISTORY") <(printf '%s\n' "$assistant"))
  calls=$(printf '%s' "$assistant" | "$JQ_BIN" -c '.tool_calls // []')
  while IFS= read -r call; do
    [[ -n "$call" ]] || continue
    id=$(printf '%s' "$call" | "$JQ_BIN" -r '.id')
    name=$(printf '%s' "$call" | "$JQ_BIN" -r '.function.name')
    args=$(printf '%s' "$call" | "$JQ_BIN" -r '.function.arguments' | "$JQ_BIN" -c '.' 2>/dev/null) || args='{}'
    result=$(run_tool "$name" "$args")
    result_text=$(printf '%s' "$result" | "$JQ_BIN" -r '.text')
    tool_message=$("$JQ_BIN" -cn --arg id "$id" --arg name "$name" --arg text "$result_text" \
      '{role:"tool",tool_call_id:$id,name:$name,content:$text}')
    HISTORY=$("$JQ_BIN" -cs '.[0] + [.[1]]' \
      <(printf '%s\n' "$HISTORY") <(printf '%s\n' "$tool_message"))
    if [[ $(printf '%s' "$result" | "$JQ_BIN" -r '.kind') == "image" ]]; then
      images=$("$JQ_BIN" -cs '.[0] as $a | .[1] as $r | $a + [{type:"text",text:$r.text},{type:"image_url",image_url:{url:("data:"+$r.media_type+";base64,"+$r.data)}}]' \
        <(printf '%s\n' "$images") <(printf '%s\n' "$result"))
    fi
  done < <(printf '%s' "$calls" | "$JQ_BIN" -c '.[]')
  if [[ $(printf '%s' "$images" | "$JQ_BIN" 'length') -gt 0 ]]; then
    HISTORY=$("$JQ_BIN" -cs '.[0] + [{role:"user",content:.[1]}]' \
      <(printf '%s\n' "$HISTORY") <(printf '%s\n' "$images"))
  fi
}

process_anthropic_calls() {
  local content results='[]' id name input result result_text block
  content=$(printf '%s' "$API_RESPONSE" | "$JQ_BIN" -c '.content')
  HISTORY=$("$JQ_BIN" -cs '.[0] + [{role:"assistant",content:.[1]}]' \
    <(printf '%s\n' "$HISTORY") <(printf '%s\n' "$content"))
  while IFS= read -r call; do
    [[ -n "$call" ]] || continue
    id=$(printf '%s' "$call" | "$JQ_BIN" -r '.id'); name=$(printf '%s' "$call" | "$JQ_BIN" -r '.name')
    input=$(printf '%s' "$call" | "$JQ_BIN" -c '.input')
    result=$(run_tool "$name" "$input"); result_text=$(printf '%s' "$result" | "$JQ_BIN" -r '.text')
    if [[ $(printf '%s' "$result" | "$JQ_BIN" -r '.kind') == "image" ]]; then
      block=$(printf '%s' "$result" | "$JQ_BIN" -c --arg id "$id" \
        '{type:"tool_result",tool_use_id:$id,content:[{type:"text",text:.text},{type:"image",source:{type:"base64",media_type:.media_type,data:.data}}]}')
    else
      block=$("$JQ_BIN" -cn --arg id "$id" --arg text "$result_text" '{type:"tool_result",tool_use_id:$id,content:$text}')
    fi
    results=$("$JQ_BIN" -cs '.[0] + [.[1]]' <(printf '%s\n' "$results") <(printf '%s\n' "$block"))
  done < <(printf '%s' "$content" | "$JQ_BIN" -c '.[] | select(.type == "tool_use")')
  HISTORY=$("$JQ_BIN" -cs '.[0] + [{role:"user",content:.[1]}]' \
    <(printf '%s\n' "$HISTORY") <(printf '%s\n' "$results"))
}

strip_media_history() {
  HISTORY=$(printf '%s' "$HISTORY" | "$JQ_BIN" -c '
    ((.. | objects | select(.type? == "image_url") | .image_url.url) = "data:image/omitted;base64,") |
    ((.. | objects | select(.type? == "image" and .source.type? == "base64") | .source.data) = "(image already delivered)")')
}

agent_turn_openai() {
  local user_text=$1 turn call_count text input user_message
  input=$(printf '%s' "$user_text" | "$JQ_BIN" -Rsc '[{role:"user",content:[{type:"input_text",text:.}]}]')
  user_message=$(printf '%s' "$user_text" | "$JQ_BIN" -Rsc '{role:"user",content:.}')
  HISTORY=$("$JQ_BIN" -cn --argjson history "$HISTORY" --argjson message "$user_message" '$history + [$message]')
  LAST_ANSWER=""
  turn=1
  while [[ "$turn" -le "$MAX_TURNS" ]]; do
    info "model ${TURN_MODEL:-$MODEL} · openai responses · reasoning $REASONING · turn $turn/$MAX_TURNS"
    if [[ "$OPENAI_NEEDS_RESTART" -eq 1 ]]; then input=$(openai_history_input); OPENAI_NEEDS_RESTART=0; fi
    call_with_fallback call_openai_responses "$input" || return 1
    CONTEXT_TOKENS=$(response_context_tokens)
    call_count=$(printf '%s' "$API_RESPONSE" | "$JQ_BIN" '[.output[]? | select(.type == "shell_call" or .type == "function_call")] | length')
    text=$(printf '%s' "$API_RESPONSE" | "$JQ_BIN" -r \
      '[.output[]? | select(.type == "message") | .content[]? | select(.type == "output_text") | .text] | join("\n")')
    record_openai_response
    if [[ "$call_count" -gt 0 ]]; then
      process_openai_shell_calls
      maybe_compact || return 1
      if [[ "$OPENAI_NEEDS_RESTART" -eq 1 ]]; then input='[]'; else input=$OPENAI_NEXT_INPUT; fi
    else
      LAST_ANSWER=$text
      maybe_compact || return 1
      return 0
    fi
    turn=$((turn + 1))
  done
  LAST_ANSWER="Stopped after reaching the $MAX_TURNS-turn limit."
  return 2
}

agent_turn() {
  local user_text=$1 turn text call_count user_message assistant_content
  TURN_MODEL=$MODEL
  if [[ "$PROVIDER" == "openai" ]]; then agent_turn_openai "$user_text"; return; fi
  user_message=$(printf '%s' "$user_text" | "$JQ_BIN" -Rsc '{role:"user",content:.}')
  HISTORY=$("$JQ_BIN" -cs '.[0] + [.[1]]' \
    <(printf '%s\n' "$HISTORY") <(printf '%s\n' "$user_message"))
  LAST_ANSWER=""
  turn=1
  while [[ "$turn" -le "$MAX_TURNS" ]]; do
    info "model ${TURN_MODEL:-$MODEL} · $PROVIDER · reasoning $REASONING · turn $turn/$MAX_TURNS"
    if [[ "$PROVIDER" == "anthropic" ]]; then
      call_with_fallback call_anthropic || return 1
      CONTEXT_TOKENS=$(response_context_tokens)
      strip_media_history
      call_count=$(printf '%s' "$API_RESPONSE" | "$JQ_BIN" '[.content[] | select(.type == "tool_use")] | length')
      text=$(printf '%s' "$API_RESPONSE" | "$JQ_BIN" -r '[.content[] | select(.type == "text") | .text] | join("\n")')
      if [[ "$call_count" -gt 0 ]]; then process_anthropic_calls; maybe_compact || return 1
      else
        assistant_content=$(printf '%s' "$API_RESPONSE" | "$JQ_BIN" -c '.content')
        HISTORY=$("$JQ_BIN" -cs '.[0] + [{role:"assistant",content:.[1]}]' \
          <(printf '%s\n' "$HISTORY") <(printf '%s\n' "$assistant_content"))
        LAST_ANSWER=$text; maybe_compact || return 1; return 0
      fi
    else
      call_with_fallback call_openrouter || return 1
      CONTEXT_TOKENS=$(response_context_tokens)
      strip_media_history
      call_count=$(printf '%s' "$API_RESPONSE" | "$JQ_BIN" '.choices[0].message.tool_calls // [] | length')
      text=$(printf '%s' "$API_RESPONSE" | "$JQ_BIN" -r '.choices[0].message.content // ""')
      if [[ "$call_count" -gt 0 ]]; then process_openai_calls; maybe_compact || return 1
      else
        assistant_content=$(printf '%s' "$API_RESPONSE" | "$JQ_BIN" -c '.choices[0].message')
        HISTORY=$("$JQ_BIN" -cs '.[0] + [.[1]]' \
          <(printf '%s\n' "$HISTORY") <(printf '%s\n' "$assistant_content"))
        LAST_ANSWER=$text; maybe_compact || return 1; return 0
      fi
    fi
    turn=$((turn + 1))
  done
  LAST_ANSWER="Stopped after reaching the $MAX_TURNS-turn limit."
  return 2
}

print_answer() {
  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    "$JQ_BIN" -cn --arg provider "$PROVIDER" --arg model "${TURN_MODEL:-$MODEL}" --arg fallback_model "$FALLBACK_MODEL" --arg reasoning "$REASONING" \
      --rawfile answer <(printf '%s' "$LAST_ANSWER") \
      '{provider:$provider,model:$model,fallback_model:$fallback_model,reasoning:$reasoning,answer:$answer}'
  else printf '%s\n' "$LAST_ANSWER"
  fi
}

interactive_help() {
  cat <<'EOF'
/model NAME       switch model and clear history
/provider NAME    switch provider and clear history
/reasoning LEVEL  change reasoning effort
/clear            clear conversation history
/help             show these commands
/quit             exit
EOF
}

interactive_loop() {
  local line value
  printf 'mini-agent %s · %s · reasoning %s · %s\n' "$PROVIDER" "$MODEL" "$REASONING" "$WORKDIR"
  while true; do
    printf '%s> %s' "$C_CYAN" "$C_RESET"
    IFS= read -e -r line || { printf '\n'; break; }
    [[ -n "$line" ]] || continue
    history -s "$line"
    case "$line" in
      /quit|/exit) break ;;
      /help) interactive_help ;;
      /clear) HISTORY='[]'; OPENAI_PREVIOUS_RESPONSE_ID=""; OPENAI_NEEDS_RESTART=0; CONTEXT_TOKENS=0; printf 'history cleared\n' ;;
      /model\ *) value=${line#* }; MODEL=$value; HISTORY='[]'; OPENAI_PREVIOUS_RESPONSE_ID=""; OPENAI_NEEDS_RESTART=0; CONTEXT_TOKENS=0; printf 'model: %s (history cleared)\n' "$MODEL" ;;
      /provider\ *) value=${line#* }; PROVIDER=$value; MODEL=""; FALLBACK_MODEL=""; HISTORY='[]'; OPENAI_PREVIOUS_RESPONSE_ID=""; OPENAI_NEEDS_RESTART=0; CONTEXT_TOKENS=0; select_provider; printf 'provider: %s, model: %s (history cleared)\n' "$PROVIDER" "$MODEL" ;;
      /reasoning\ *) value=${line#* }; REASONING=$value; case "$REASONING" in default|none|minimal|low|medium|high|xhigh|max) printf 'reasoning: %s\n' "$REASONING" ;; *) printf 'invalid reasoning level\n'; REASONING="medium" ;; esac ;;
      /*) printf 'unknown command; use /help\n' ;;
      *) if agent_turn "$line"; then print_answer; else printf 'request failed\n' >&2; fi ;;
    esac
  done
}

main() {
  parse_args "$@"
  need_cmd "$CURL_BIN"; need_cmd "$JQ_BIN"; need_cmd base64; need_cmd awk
  select_provider; validate_config
  if [[ -z "$PROMPT" && ! -t 0 ]]; then PROMPT=$(cat); fi
  if [[ -n "$PROMPT" ]]; then
    agent_turn "$PROMPT" || { [[ -n "$LAST_ANSWER" ]] && print_answer; return 1; }
    print_answer
    [[ "$INTERACTIVE" -eq 1 ]] || return 0
  fi
  interactive_loop
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
