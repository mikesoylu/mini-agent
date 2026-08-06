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
DEBUG="${MINI_AGENT_DEBUG:-0}"
DEBUG_DIR="${MINI_AGENT_DEBUG_DIR:-}"
DEBUG_LOG=""
DEBUG_ARGV=()
OUTPUT_FORMAT="text"
INTERACTIVE=0
QUIET=0
PROMPT=""
HISTORY='[]'
OPENAI_PREVIOUS_RESPONSE_ID=""
OPENAI_NEEDS_RESTART=0
CONTEXT_TOKENS=0
CONTEXT_TOKENS_KNOWN=0
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
die() { debug_log "fatal message=$(printf '%q' "$*")"; printf '%smini-agent: %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; exit 1; }
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
      --debug             Write a diagnostic bundle under the system temp directory
      --debug-dir DIR     Write the diagnostic bundle to DIR (enables --debug)
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
  MINI_AGENT_COMPACT_MAX_TOKENS, MINI_AGENT_TOOL_TIMEOUT, MINI_AGENT_DEBUG
  MINI_AGENT_DEBUG_DIR
  OPENROUTER_HTTP_REFERER, OPENROUTER_APP_NAME

Interactive commands:
  /model NAME, /provider NAME, /reasoning LEVEL, /compact, /status, /clear, /help, /quit
EOF
}
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
is_uint() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }
debug_log() {
  [[ -n "$DEBUG_LOG" ]] || return 0
  printf '%s pid=%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$$" "$*" >> "$DEBUG_LOG"
}
debug_dump() {
  local label=$1 content=$2 path bytes
  [[ -n "$DEBUG_LOG" ]] || return 0
  path=$(mktemp "$DEBUG_DIR/$label.XXXXXX") || { debug_log "artifact_failed label=$label"; return 1; }
  printf '%s' "$content" > "$path"
  chmod 600 "$path" 2>/dev/null || true
  bytes=$(wc -c < "$path" | tr -d ' ')
  debug_log "artifact label=$label bytes=$bytes path=$path"
}
debug_dump_file() {
  local label=$1 source=$2 path bytes
  [[ -n "$DEBUG_LOG" ]] || return 0
  [[ -f "$source" ]] || { debug_log "artifact_source_missing label=$label source=$source"; return 1; }
  path=$(mktemp "$DEBUG_DIR/$label.XXXXXX") || { debug_log "artifact_failed label=$label"; return 1; }
  cp "$source" "$path" || return 1
  chmod 600 "$path" 2>/dev/null || true
  bytes=$(wc -c < "$path" | tr -d ' ')
  debug_log "artifact label=$label bytes=$bytes path=$path"
}
debug_state() {
  local label=$1 state
  [[ -n "$DEBUG_LOG" ]] || return 0
  state=$("$JQ_BIN" -cn \
    --arg provider "$PROVIDER" --arg model "$MODEL" --arg turn_model "$TURN_MODEL" \
    --arg fallback_model "$FALLBACK_MODEL" --arg reasoning "$REASONING" --arg workdir "$WORKDIR" \
    --arg api_url "${API_URL:-}" --arg previous_response_id "$OPENAI_PREVIOUS_RESPONSE_ID" \
    --arg needs_restart "$OPENAI_NEEDS_RESTART" --arg context_tokens "$CONTEXT_TOKENS" \
    --arg context_known "$CONTEXT_TOKENS_KNOWN" --arg compact_tokens "$COMPACT_TOKENS" \
    --arg history_length "$(printf '%s' "$HISTORY" | "$JQ_BIN" 'length' 2>/dev/null || printf 0)" \
    '{provider:$provider,model:$model,turn_model:$turn_model,fallback_model:$fallback_model,
      reasoning:$reasoning,workdir:$workdir,api_url:$api_url,previous_response_id:$previous_response_id,
      needs_restart:($needs_restart|tonumber),context_tokens:($context_tokens|tonumber),
      context_known:($context_known|tonumber),compact_tokens:($compact_tokens|tonumber),
      history_length:($history_length|tonumber)}') || return 1
  debug_dump "state-$label.json" "$state"
}
init_debug() {
  local arg index=0 meta
  case "$DEBUG" in
    1|true|TRUE|yes|YES|on|ON) DEBUG=1 ;;
    0|false|FALSE|no|NO|off|OFF|'') DEBUG=0; return 0 ;;
    *) die "MINI_AGENT_DEBUG must be 0 or 1" ;;
  esac
  if [[ -n "$DEBUG_DIR" ]]; then
    mkdir -p "$DEBUG_DIR" || die "cannot create debug directory: $DEBUG_DIR"
    DEBUG_DIR=$(cd "$DEBUG_DIR" 2>/dev/null && pwd -P) || die "cannot enter debug directory"
  else
    DEBUG_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mini-agent-debug.$$.XXXXXX") || die "cannot create debug directory"
  fi
  chmod 700 "$DEBUG_DIR" 2>/dev/null || true
  DEBUG_LOG="$DEBUG_DIR/events.log"
  : > "$DEBUG_LOG"
  chmod 600 "$DEBUG_LOG" 2>/dev/null || true
  printf 'mini-agent: debug bundle: %s\n' "$DEBUG_DIR" >&2
  debug_log "session_start ppid=$PPID uid=${UID:-unknown} euid=${EUID:-unknown} bash=${BASH_VERSION:-unknown} cwd=$PWD"
  for arg in "${DEBUG_ARGV[@]}"; do
    debug_log "argv[$index]=$(printf '%q' "$arg")"
    index=$((index + 1))
  done
  meta=$(printf 'script=%s\npid=%s\nppid=%s\nuid=%s\neuid=%s\nbash_version=%s\ncwd=%s\ntmpdir=%s\nuname=%s\n' \
    "${BASH_SOURCE[0]}" "$$" "$PPID" "${UID:-unknown}" "${EUID:-unknown}" "${BASH_VERSION:-unknown}" "$PWD" "${TMPDIR:-/tmp}" "$(uname -a 2>/dev/null || printf unknown)")
  debug_dump session.txt "$meta"
}
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
      --debug) DEBUG=1; shift ;;
      --debug-dir) [[ $# -ge 2 ]] || die "$1 requires a value"; DEBUG=1; DEBUG_DIR=$2; shift 2 ;;
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
  local os_name machine now tool_guidance sed_note=""
  os_name=$(uname -s 2>/dev/null || printf unknown)
  machine=$(uname -m 2>/dev/null || printf unknown)
  now=$(date '+%Y-%m-%d')
  if [[ "$PROVIDER" == "openai" ]]; then
    tool_guidance="Use the read tool to inspect files, directories, and images. Use the native shell tool for searches, file edits, builds, and tests."
  else
    tool_guidance="Use the read tool to inspect files, directories, and images. Use the shell tool for searches, file edits, builds, and tests."
  fi
  if [[ "$os_name" == "Darwin" ]]; then
    sed_note="<important>
You are on MacOS. For all the below examples, use \`sed -i ''\` instead of \`sed -i\`.
</important>"
  fi
  cat <<PROMPT_EOF
You are a concise, capable software-engineering agent.

<system_information>
$os_name $machine $now $WORKDIR
</system_information>

$tool_guidance Commands run locally in the working directory through Bash. Prefer common portable Unix utilities.

## Useful command examples

### Create a new file:

\`\`\`bash
cat <<'EOF' > newfile.py
import numpy as np
hello = "world"
print(hello)
EOF
\`\`\`

### Edit files with sed:

$sed_note

\`\`\`bash
# Replace all occurrences
sed -i 's/old_string/new_string/g' filename.py

# Replace only first occurrence
sed -i 's/old_string/new_string/' filename.py

# Replace first occurrence on line 1
sed -i '1s/old_string/new_string/' filename.py

# Replace all occurrences in lines 1-10
sed -i '1,10s/old_string/new_string/g' filename.py
\`\`\`

### View file content:

\`\`\`bash
# View specific lines with numbers
nl -ba filename.py | sed -n '10,20p'
\`\`\`

Work autonomously until the task is complete. Inspect before changing, preserve unrelated work, and verify changes. Never claim a command succeeded unless its result says so. Keep final answers brief and include changed files and verification.
Only attribute changes, commands, API calls, and verification to the current user request when they actually occurred during that request. Treat pre-existing working-tree changes as context, not work you performed. For read-only or explanatory requests, do not imply that files were changed.
PROMPT_EOF
}
tools_compatible() {
  "$JQ_BIN" -cn '[
    {type:"function",function:{name:"read",description:"Read a text file, attach an image, or list a directory.",parameters:{type:"object",properties:{path:{type:"string",description:"Absolute path or path relative to the working directory"},offset:{type:"integer",minimum:1,description:"First line to read (default 1)"},limit:{type:"integer",minimum:1,maximum:2000,description:"Maximum lines or directory entries (default 250)"}},required:["path"],additionalProperties:false}}},
    {type:"function",function:{name:"shell",description:"Run a shell command in the working directory. Use for searching, editing files, building, and testing.",parameters:{type:"object",properties:{command:{type:"string",description:"Shell command to execute through Bash"}},required:["command"],additionalProperties:false}}}
  ]'
}
tools_openai() {
  tools_compatible | "$JQ_BIN" -c '[{type:"shell",environment:{type:"local"}}, (.[0].function + {type:"function"})]'
}
tools_anthropic() {
  tools_compatible | "$JQ_BIN" -c '[.[] | {name:.function.name,description:.function.description,input_schema:.function.parameters}]'
}
api_request() {
  local url=$1 key_header=$2 key=$3 body=$4 response_file status curl_status
  shift 4
  debug_log "api_request_start provider=$PROVIDER model=${TURN_MODEL:-$MODEL} url=$url previous_response_id=${OPENAI_PREVIOUS_RESPONSE_ID:-none} body_bytes=$(printf '%s' "$body" | wc -c | tr -d ' ') extra_header_args=$#"
  debug_dump api-request.json "$body"
  response_file=$(mktemp "${TMPDIR:-/tmp}/mini-agent-response.XXXXXX") || return 1
  status=$("$CURL_BIN" -sS --connect-timeout 20 --max-time "$API_TIMEOUT" \
    -o "$response_file" -w '%{http_code}' -X POST "$url" \
    -H 'content-type: application/json' -H "$key_header: $key" "$@" \
    --data-binary @- <<< "$body")
  curl_status=$?
  API_RESPONSE=$(<"$response_file")
  debug_dump api-response.json "$API_RESPONSE"
  debug_log "api_request_end provider=$PROVIDER model=${TURN_MODEL:-$MODEL} url=$url http_status=$status curl_status=$curl_status response_bytes=$(wc -c < "$response_file" | tr -d ' ')"
  rm -f "$response_file"
  if [[ $curl_status -ne 0 ]]; then
    printf 'network error (curl exit %s)\n' "$curl_status" >&2
    return 1
  fi
  if ! printf '%s' "$API_RESPONSE" | "$JQ_BIN" -e . >/dev/null 2>&1; then
    printf 'API returned invalid JSON\n' >&2
    return 1
  fi
  if [[ ! "$status" =~ ^2 ]]; then
    response_is_refusal && return 2
    printf 'API error HTTP %s: %s\n' "$status" "$(printf '%s' "$API_RESPONSE" | "$JQ_BIN" -r '.error.message // .error // .' 2>/dev/null)" >&2
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
    openai) printf '%s' "$API_RESPONSE" | "$JQ_BIN" -e '
      any(.output[]?.content[]?; .type == "refusal") or
      (((.error.code // "") | test("content_filter|content_policy|safety|cyber"; "i")) or
       ((.error.message // "") | test("flagged for possible (cybersecurity|safety) risk|blocked by (a |the )?(safety|content) policy"; "i")))' ;;
    openrouter) printf '%s' "$API_RESPONSE" | "$JQ_BIN" -e '.choices[0].finish_reason == "content_filter" or ((.choices[0].message.refusal? // null) as $r | $r != null and $r != "")' ;;
  esac >/dev/null 2>&1
}
refusal_reason() {
  case "$PROVIDER" in
    anthropic) printf '%s' "$API_RESPONSE" | "$JQ_BIN" -r '.stop_details.explanation // "safety refusal"' ;;
    openai) printf '%s' "$API_RESPONSE" | "$JQ_BIN" -r '.error.message // ([.output[]?.content[]? | select(.type == "refusal") | .refusal] | first) // "safety refusal"' ;;
    openrouter) printf '%s' "$API_RESPONSE" | "$JQ_BIN" -r '.choices[0].message.refusal // .choices[0].finish_reason // "safety refusal" | if type == "string" then . else tojson end' ;;
  esac
}
call_with_fallback() {
  local fn=$1 previous=$OPENAI_PREVIOUS_RESPONSE_ID refused reason status=0
  shift
  "$fn" "$@" || status=$?
  if [[ "$status" -ne 0 ]] && ! response_is_refusal; then return "$status"; fi
  response_is_refusal || return 0
  refused=${TURN_MODEL:-$MODEL}; reason=$(refusal_reason)
  if [[ -z "$FALLBACK_MODEL" || "$FALLBACK_MODEL" == "none" || "$FALLBACK_MODEL" == "$refused" ]]; then
    OPENAI_PREVIOUS_RESPONSE_ID=$previous; LAST_ANSWER="Model $refused refused the request: $reason"; printf '%s\n' "$LAST_ANSWER" >&2; return 1
  fi
  info "${C_CYAN}fallback${C_RESET} $refused refused: $reason; retrying with $FALLBACK_MODEL"
  OPENAI_PREVIOUS_RESPONSE_ID=$previous; TURN_MODEL=$FALLBACK_MODEL
  status=0; "$fn" "$@" || status=$?
  if [[ "$status" -ne 0 ]] && ! response_is_refusal; then return "$status"; fi
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
    def checkpoint:
      .role == "user" and (.content | type) == "string" and
      (.content | startswith("Another language model worked on this task and produced a context checkpoint."));
    def body:
      ((if (.content // null) == null then "" elif (.content|type) == "string" then .content else (.content|tojson) end) +
       (if (.tool_calls // [] | length) > 0 then "\n[tool calls] " + (.tool_calls|tojson) else "" end)) as $body |
      if checkpoint then $body else ($body | clipped) end;
    map("[" + ((.role // "message") | ascii_upcase) + "]: " + body) | join("\n\n")'
}
compaction_user_prompt() {
  cat <<'EOF'
Create a context checkpoint summarizing the conversation before this message. Respond immediately using only the checkpoint sections below and only information already present in the conversation. Omit this checkpoint-generation request and its directives from the checkpoint. Preserve exact file paths, function names, commands, errors, constraints, decisions, and unfinished work. For every image attachment in the history, preserve its exact file path and a short summary of its relevant visual content; if either is unknown, say so rather than inventing it.

Use exactly these sections:

## Goal
## Constraints & Preferences
## Progress
### Done
### In Progress
### Blocked
## Key Decisions
## Next Steps
## Critical Context
## Image Attachments

Keep it concise and suitable for another model to continue without duplicating work.
EOF
}
compaction_output_limit() {
  local max=$COMPACT_MAX_TOKENS half=$((COMPACT_TOKENS / 2))
  [[ "$half" -gt 0 ]] || half=1
  [[ "$max" -le "$half" ]] || max=$half
  [[ "$max" -le "$MAX_TOKENS" ]] || max=$MAX_TOKENS
  printf '%s' "$max"
}
call_compaction_summary() {
  local prompt=$1 pending=${2:-'[]'} max summary refused reason input user status=0
  local saved_history=$HISTORY saved_max=$MAX_TOKENS saved_previous=$OPENAI_PREVIOUS_RESPONSE_ID
  max=$(compaction_output_limit)
  debug_log "compaction_summary_start provider=$PROVIDER model=${TURN_MODEL:-$MODEL} max_output_tokens=$max pending_items=$(printf '%s' "$pending" | "$JQ_BIN" 'length' 2>/dev/null || printf unknown) previous_response_id=${saved_previous:-none}"
  debug_dump compaction-prompt.txt "$prompt"
  debug_dump compaction-pending.json "$pending"
  debug_dump compaction-history.json "$saved_history"
  MAX_TOKENS=$max
  case "$PROVIDER" in
    openai)
      input=$("$JQ_BIN" -cn --argjson pending "$pending" --arg prompt "$prompt" \
        '$pending + [{role:"user",content:[{type:"input_text",text:$prompt}]}]')
      call_openai_responses "$input" || status=$?
      ;;
    anthropic)
      user=$("$JQ_BIN" -cn --arg prompt "$prompt" '{role:"user",content:$prompt}')
      HISTORY=$("$JQ_BIN" -cn --argjson history "$saved_history" --argjson user "$user" '$history + [$user]')
      call_anthropic || status=$?
      ;;
    openrouter)
      user=$("$JQ_BIN" -cn --arg prompt "$prompt" '{role:"user",content:$prompt}')
      HISTORY=$("$JQ_BIN" -cn --argjson history "$saved_history" --argjson user "$user" '$history + [$user]')
      call_openrouter || status=$?
      ;;
  esac
  HISTORY=$saved_history; MAX_TOKENS=$saved_max; OPENAI_PREVIOUS_RESPONSE_ID=$saved_previous
  debug_log "compaction_summary_response status=$status restored_previous_response_id=${OPENAI_PREVIOUS_RESPONSE_ID:-none}"
  if [[ "$status" -ne 0 ]] && ! response_is_refusal; then debug_log "compaction_summary_failed stage=api status=$status"; return "$status"; fi
  case "$PROVIDER" in
    openai) summary=$(printf '%s' "$API_RESPONSE" | "$JQ_BIN" -r '[.output[]? | select(.type == "message") | .content[]? | select(.type == "output_text") | .text] | join("\n")') ;;
    anthropic) summary=$(printf '%s' "$API_RESPONSE" | "$JQ_BIN" -r '[.content[]? | select(.type == "text") | .text] | join("\n")') ;;
    openrouter) summary=$(printf '%s' "$API_RESPONSE" | "$JQ_BIN" -r '.choices[0].message.content // ""') ;;
  esac
  if response_is_refusal; then
    refused=${TURN_MODEL:-$MODEL}; reason=$(refusal_reason)
    if [[ -n "$FALLBACK_MODEL" && "$FALLBACK_MODEL" != "none" && "$FALLBACK_MODEL" != "$refused" ]]; then
      info "${C_CYAN}fallback${C_RESET} $refused refused compaction: $reason; retrying with $FALLBACK_MODEL"
      TURN_MODEL=$FALLBACK_MODEL; call_compaction_summary "$prompt" "$pending"; return
    fi
    printf 'compaction model %s refused: %s\n' "$refused" "$reason" >&2; return 1
  fi
  debug_dump compaction-summary.txt "$summary"
  [[ -n "$summary" ]] || { debug_log "compaction_summary_failed stage=extract reason=empty_summary"; printf 'compaction returned an empty summary\n' >&2; return 1; }
  COMPACTION_SUMMARY=$summary
  debug_log "compaction_summary_complete bytes=$(printf '%s' "$summary" | wc -c | tr -d ' ')"
}
compact_history() {
  local pending=${1:-'[]'} resume=${2:-0} cut kept prompt summary prefix continuation
  cut=$(printf '%s' "$HISTORY" | "$JQ_BIN" -r '
    ([to_entries[] | select(.value.role == "user" and (.value.content|type) == "string") | .key] | last // -1) as $user |
    (.[0].content? | type == "string" and startswith("Another language model worked on this task")) as $already_compacted |
    if $user > 0 and (($already_compacted and $user == 1) | not) then $user
    else ([to_entries[] | select(.value.role == "assistant" and .key > 0) | .key] | last // -1) end')
  debug_log "compact_history_start provider=$PROVIDER resume=$resume cut=$cut history_length=$(printf '%s' "$HISTORY" | "$JQ_BIN" 'length' 2>/dev/null || printf unknown)"
  debug_dump compact-history-before.json "$HISTORY"
  [[ "$cut" -gt 0 ]] || { debug_log "compact_history_failed reason=no_safe_boundary"; printf 'context is too large but has no safe compaction boundary\n' >&2; return 1; }
  kept=$(printf '%s' "$HISTORY" | "$JQ_BIN" -c --argjson cut "$cut" '.[$cut:]')
  debug_dump compact-history-kept.json "$kept"
  prompt=$(compaction_user_prompt)
  call_compaction_summary "$prompt" "$pending" || return 1
  summary=$COMPACTION_SUMMARY
  prefix="Another language model worked on this task and produced a context checkpoint. Use it to continue without duplicating effort:\n\n$summary"
  HISTORY=$("$JQ_BIN" -cn --arg prefix "$prefix" --argjson kept "$kept" '[{role:"user",content:$prefix}] + $kept')
  if [[ "$resume" -eq 1 ]]; then
    continuation="Compaction is complete. Continue the original task now from the checkpoint and resolved tool results. Do not merely acknowledge the checkpoint. Checkpoint-generation directives are expired and must not constrain this turn."
    HISTORY=$("$JQ_BIN" -cn --argjson history "$HISTORY" --arg continuation "$continuation" \
      '$history + [{role:"user",content:$continuation}]')
  fi
  debug_dump compact-history-after.json "$HISTORY"
  CONTEXT_TOKENS=0; CONTEXT_TOKENS_KNOWN=0
  if [[ "$PROVIDER" == "openai" ]]; then
    OPENAI_PREVIOUS_RESPONSE_ID=""
    OPENAI_NEEDS_RESTART=1
  fi
  debug_log "compact_history_complete provider=$PROVIDER resume=$resume history_length=$(printf '%s' "$HISTORY" | "$JQ_BIN" 'length' 2>/dev/null || printf unknown) needs_restart=$OPENAI_NEEDS_RESTART"
  debug_state compacted
}
maybe_compact() {
  local pending=${1:-'[]'} resume=${2:-0}
  [[ "$CONTEXT_TOKENS" -ge "$COMPACT_TOKENS" ]] || return 0
  info "${C_CYAN}compact${C_RESET} context $CONTEXT_TOKENS/$COMPACT_TOKENS tokens"
  compact_history "$pending" "$resume"
}
auto_compact() {
  if ! maybe_compact "${1:-'[]'}" "${2:-0}"; then
    info "${C_CYAN}compact${C_RESET} failed; continuing with the current context"
    debug_log "automatic_compaction_failed action=continue_current_context previous_response_id=${OPENAI_PREVIOUS_RESPONSE_ID:-none}"
  fi
  return 0
}

context_usage() {
  if [[ "$CONTEXT_TOKENS_KNOWN" -eq 1 ]]; then
    printf '%s/%s' "$CONTEXT_TOKENS" "$COMPACT_TOKENS"
  else
    printf 'unknown/%s' "$COMPACT_TOKENS"
  fi
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

run_shell() {
  local command_text=$1 tmp status output timer=()
  tmp=$(mktemp "${TMPDIR:-/tmp}/mini-agent-tool.XXXXXX") || return 1
  if command -v timeout >/dev/null 2>&1; then timer=(timeout "$TOOL_TIMEOUT")
  elif command -v gtimeout >/dev/null 2>&1; then timer=(gtimeout "$TOOL_TIMEOUT"); fi
  (cd "$WORKDIR" && "${timer[@]}" bash -lc "$command_text") > "$tmp" 2>&1
  status=$?
  debug_log "tool_shell_compatible command=$(printf '%q' "$command_text") status=$status"
  debug_dump_file tool-shell-compatible-output.txt "$tmp"
  output=$(truncate_file "$tmp")
  rm -f "$tmp"
  [[ -n "$output" ]] || output="(no output)"
  "$JQ_BIN" -cn --arg text "$output\n\n[exit status: $status]" --argjson status "$status" \
    '{kind:"text",text:$text,exit_status:$status}'
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
  debug_log "tool_shell command=$(printf '%q' "$command_text") status=$status requested_limit=$requested_limit effective_limit=$cap timeout_seconds=$timeout_seconds"
  debug_dump_file tool-shell-stdout.txt "$out_file"
  debug_dump_file tool-shell-stderr.txt "$err_file"
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

process_openai_tool_calls() {
  local next='[]' attachments='[]' call type call_id name args requested_limit timeout_ms timeout_seconds outputs command_text result result_text attachment tool_output message
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
      if [[ $(printf '%s' "$result" | "$JQ_BIN" -r '.kind') == "image" ]]; then
        attachment=$(printf '%s' "$result" | "$JQ_BIN" -c \
          '{type:"input_image",image_url:("data:"+.media_type+";base64,"+.data)}')
        attachments=$("$JQ_BIN" -cs '.[0] + [.[1]]' \
          <(printf '%s\n' "$attachments") <(printf '%s\n' "$attachment"))
      fi
      continue
    fi
    requested_limit=$(printf '%s' "$call" | "$JQ_BIN" -r ".action.max_output_length // $MAX_TOOL_OUTPUT")
    timeout_ms=$(printf '%s' "$call" | "$JQ_BIN" -r ".action.timeout_ms // ($TOOL_TIMEOUT * 1000)")
    timeout_seconds=$(( (timeout_ms + 999) / 1000 ))
    outputs='[]'
    while IFS= read -r command_text; do
      [[ -n "$command_text" ]] || continue
      result=$(run_native_command "$command_text" "$requested_limit" "$timeout_seconds")
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
      '{role:"user",content:([{type:"input_text",text:"Images returned by the read tool are attached."}] + $files[0])}')
    next=$("$JQ_BIN" -cs '.[0] + [.[1]]' \
      <(printf '%s\n' "$next") <(printf '%s\n' "$message"))
  fi
  OPENAI_NEXT_INPUT=$next
  debug_dump openai-next-input.json "$OPENAI_NEXT_INPUT"
  debug_log "openai_tool_calls_resolved results=$(printf '%s' "$next" | "$JQ_BIN" '[.[] | select(.type == "shell_call_output" or .type == "function_call_output")] | length' 2>/dev/null || printf unknown) attachments=$(printf '%s' "$attachments" | "$JQ_BIN" 'length' 2>/dev/null || printf unknown)"
}

run_tool() {
  local name=$1 input=$2 command_text path offset limit
  case "$name" in
    read)
      path=$(printf '%s' "$input" | "$JQ_BIN" -r '.path // empty')
      offset=$(printf '%s' "$input" | "$JQ_BIN" -r '.offset // 1')
      limit=$(printf '%s' "$input" | "$JQ_BIN" -r '.limit // 250')
      [[ -n "$path" ]] || { "$JQ_BIN" -cn '{kind:"error",text:"read requires path"}'; return; }
      info "${C_CYAN}read${C_RESET} $path"
      debug_log "tool_read path=$(printf '%q' "$path") offset=$offset limit=$limit"
      read_file "$path" "$offset" "$limit"
      ;;
    shell)
      command_text=$(printf '%s' "$input" | "$JQ_BIN" -r '.command // empty')
      [[ -n "$command_text" ]] || { "$JQ_BIN" -cn '{kind:"error",text:"shell requires command"}'; return; }
      info "${C_CYAN}shell${C_RESET} $command_text"
      debug_log "tool_shell_compatible_requested command=$(printf '%q' "$command_text")"
      run_shell "$command_text"
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
  debug_dump history-after-openrouter-tools.json "$HISTORY"
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
  debug_dump history-after-anthropic-tools.json "$HISTORY"
}

agent_turn_openai() {
  local user_text=$1 turn call_count text input user_message
  input=$(printf '%s' "$user_text" | "$JQ_BIN" -Rsc '[{role:"user",content:[{type:"input_text",text:.}]}]')
  user_message=$(printf '%s' "$user_text" | "$JQ_BIN" -Rsc '{role:"user",content:.}')
  HISTORY=$("$JQ_BIN" -cn --argjson history "$HISTORY" --argjson message "$user_message" '$history + [$message]')
  LAST_ANSWER=""
  turn=1
  while [[ "$turn" -le "$MAX_TURNS" ]]; do
    debug_log "model_turn_start provider=openai model=${TURN_MODEL:-$MODEL} turn=$turn context=$(context_usage) previous_response_id=${OPENAI_PREVIOUS_RESPONSE_ID:-none} needs_restart=$OPENAI_NEEDS_RESTART"
    debug_state model-turn-openai
    info "model ${TURN_MODEL:-$MODEL} · openai responses · reasoning $REASONING · context $(context_usage) · turn $turn/$MAX_TURNS"
    if [[ "$OPENAI_NEEDS_RESTART" -eq 1 ]]; then input=$(openai_history_input); OPENAI_NEEDS_RESTART=0; fi
    debug_dump model-input-openai.json "$input"
    debug_dump history-model-turn-openai.json "$HISTORY"
    call_with_fallback call_openai_responses "$input" || return 1
    CONTEXT_TOKENS=$(response_context_tokens); CONTEXT_TOKENS_KNOWN=1
    call_count=$(printf '%s' "$API_RESPONSE" | "$JQ_BIN" '[.output[]? | select(.type == "shell_call" or .type == "function_call")] | length')
    text=$(printf '%s' "$API_RESPONSE" | "$JQ_BIN" -r \
      '[.output[]? | select(.type == "message") | .content[]? | select(.type == "output_text") | .text] | join("\n")')
    record_openai_response
    if [[ "$call_count" -gt 0 ]]; then
      process_openai_tool_calls
      input=$OPENAI_NEXT_INPUT
      auto_compact "$input" 1
    else
      LAST_ANSWER=$text
      auto_compact
      return 0
    fi
    turn=$((turn + 1))
  done
  LAST_ANSWER="Stopped after reaching the $MAX_TURNS-turn limit."
  return 2
}

agent_turn() {
  local user_text=$1 turn text call_count user_message assistant_content
  [[ -n "$TURN_MODEL" ]] || TURN_MODEL=$MODEL
  if [[ "$PROVIDER" == "openai" ]]; then agent_turn_openai "$user_text"; return; fi
  user_message=$(printf '%s' "$user_text" | "$JQ_BIN" -Rsc '{role:"user",content:.}')
  HISTORY=$("$JQ_BIN" -cs '.[0] + [.[1]]' \
    <(printf '%s\n' "$HISTORY") <(printf '%s\n' "$user_message"))
  LAST_ANSWER=""
  turn=1
  while [[ "$turn" -le "$MAX_TURNS" ]]; do
    debug_log "model_turn_start provider=$PROVIDER model=${TURN_MODEL:-$MODEL} turn=$turn context=$(context_usage)"
    debug_state "model-turn-$PROVIDER"
    info "model ${TURN_MODEL:-$MODEL} · $PROVIDER · reasoning $REASONING · context $(context_usage) · turn $turn/$MAX_TURNS"
    debug_dump "history-model-turn-$PROVIDER.json" "$HISTORY"
    if [[ "$PROVIDER" == "anthropic" ]]; then
      call_with_fallback call_anthropic || return 1
      CONTEXT_TOKENS=$(response_context_tokens); CONTEXT_TOKENS_KNOWN=1
      call_count=$(printf '%s' "$API_RESPONSE" | "$JQ_BIN" '[.content[] | select(.type == "tool_use")] | length')
      text=$(printf '%s' "$API_RESPONSE" | "$JQ_BIN" -r '[.content[] | select(.type == "text") | .text] | join("\n")')
      if [[ "$call_count" -gt 0 ]]; then
        process_anthropic_calls
        auto_compact '[]' 1
      else
        assistant_content=$(printf '%s' "$API_RESPONSE" | "$JQ_BIN" -c '.content')
        HISTORY=$("$JQ_BIN" -cs '.[0] + [{role:"assistant",content:.[1]}]' \
          <(printf '%s\n' "$HISTORY") <(printf '%s\n' "$assistant_content"))
        LAST_ANSWER=$text; auto_compact; return 0
      fi
    else
      call_with_fallback call_openrouter || return 1
      CONTEXT_TOKENS=$(response_context_tokens); CONTEXT_TOKENS_KNOWN=1
      call_count=$(printf '%s' "$API_RESPONSE" | "$JQ_BIN" '.choices[0].message.tool_calls // [] | length')
      text=$(printf '%s' "$API_RESPONSE" | "$JQ_BIN" -r '.choices[0].message.content // ""')
      if [[ "$call_count" -gt 0 ]]; then
        process_openai_calls
        auto_compact '[]' 1
      else
        assistant_content=$(printf '%s' "$API_RESPONSE" | "$JQ_BIN" -c '.choices[0].message')
        HISTORY=$("$JQ_BIN" -cs '.[0] + [.[1]]' \
          <(printf '%s\n' "$HISTORY") <(printf '%s\n' "$assistant_content"))
        LAST_ANSWER=$text; auto_compact; return 0
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

print_status() {
  local messages remaining percent
  messages=$(printf '%s' "$HISTORY" | "$JQ_BIN" 'length')
  printf 'provider: %s\nmodel: %s\nfallback model: %s\nmessages: %s\n' "$PROVIDER" "${TURN_MODEL:-$MODEL}" "$FALLBACK_MODEL" "$messages"
  if [[ "$CONTEXT_TOKENS_KNOWN" -eq 1 ]]; then
    remaining=$((COMPACT_TOKENS - CONTEXT_TOKENS)); [[ "$remaining" -lt 0 ]] && remaining=0
    percent=$((CONTEXT_TOKENS * 100 / COMPACT_TOKENS))
    printf 'conversation tokens: %s / %s (%s%%)\ntokens until compaction: %s\n' "$CONTEXT_TOKENS" "$COMPACT_TOKENS" "$percent" "$remaining"
  else
    printf 'conversation tokens: unknown (next model response will refresh them)\ncompaction threshold: %s\n' "$COMPACT_TOKENS"
  fi
  printf 'maximum output tokens: %s\nmaximum turns: %s\n' "$MAX_TOKENS" "$MAX_TURNS"
  [[ -z "$DEBUG_DIR" || -z "$DEBUG_LOG" ]] || printf 'debug bundle: %s\n' "$DEBUG_DIR"
}

interactive_help() {
  cat <<'EOF'
/model NAME       switch model and clear history
/provider NAME    switch provider and clear history
/reasoning LEVEL  change reasoning effort
/compact          compact conversation context now
/status           show conversation token statistics
/clear            clear conversation history
/help             show these commands
/quit             exit
EOF
}

interactive_prompt() {
  if [[ -n "$C_CYAN" ]]; then
    printf '\001%s\002> \001%s\002' "$C_CYAN" "$C_RESET"
  else
    printf '> '
  fi
}

interactive_loop() {
  local line value prompt
  printf 'mini-agent %s · %s · reasoning %s · %s\n' "$PROVIDER" "$MODEL" "$REASONING" "$WORKDIR"
  prompt=$(interactive_prompt)
  while true; do
    IFS= read -e -r -p "$prompt" line || { printf '\n'; break; }
    [[ -n "$line" ]] || continue
    debug_log "interactive_input value=$(printf '%q' "$line")"
    history -s "$line"
    case "$line" in
      /quit|/exit) break ;;
      /help) interactive_help ;;
      /compact) if compact_history; then printf 'context compacted\n'; else printf 'compaction failed\n' >&2; fi ;;
      /status) print_status ;;
      /clear) HISTORY='[]'; OPENAI_PREVIOUS_RESPONSE_ID=""; OPENAI_NEEDS_RESTART=0; CONTEXT_TOKENS=0; CONTEXT_TOKENS_KNOWN=0; printf 'history cleared\n' ;;
      /model\ *) value=${line#* }; MODEL=$value; TURN_MODEL=""; HISTORY='[]'; OPENAI_PREVIOUS_RESPONSE_ID=""; OPENAI_NEEDS_RESTART=0; CONTEXT_TOKENS=0; CONTEXT_TOKENS_KNOWN=0; printf 'model: %s (history cleared)\n' "$MODEL" ;;
      /provider\ *) value=${line#* }; PROVIDER=$value; MODEL=""; FALLBACK_MODEL=""; TURN_MODEL=""; HISTORY='[]'; OPENAI_PREVIOUS_RESPONSE_ID=""; OPENAI_NEEDS_RESTART=0; CONTEXT_TOKENS=0; CONTEXT_TOKENS_KNOWN=0; select_provider; printf 'provider: %s, model: %s (history cleared)\n' "$PROVIDER" "$MODEL" ;;
      /reasoning\ *) value=${line#* }; REASONING=$value; case "$REASONING" in default|none|minimal|low|medium|high|xhigh|max) printf 'reasoning: %s\n' "$REASONING" ;; *) printf 'invalid reasoning level\n'; REASONING="medium" ;; esac ;;
      /*) printf 'unknown command; use /help\n' ;;
      *) if agent_turn "$line"; then print_answer; else printf 'request failed\n' >&2; fi ;;
    esac
  done
}

main() {
  DEBUG_ARGV=("$@")
  parse_args "$@"
  need_cmd "$CURL_BIN"; need_cmd "$JQ_BIN"; need_cmd base64; need_cmd awk
  init_debug
  select_provider; validate_config
  debug_log "configured provider=$PROVIDER model=$MODEL fallback_model=$FALLBACK_MODEL reasoning=$REASONING workdir=$WORKDIR api_url=$API_URL max_turns=$MAX_TURNS max_tokens=$MAX_TOKENS compact_tokens=$COMPACT_TOKENS compact_max_tokens=$COMPACT_MAX_TOKENS max_tool_output=$MAX_TOOL_OUTPUT tool_timeout=$TOOL_TIMEOUT api_timeout=$API_TIMEOUT"
  debug_state configured
  if [[ -z "$PROMPT" && ! -t 0 ]]; then PROMPT=$(cat); fi
  if [[ -n "$PROMPT" ]]; then
    agent_turn "$PROMPT" || { [[ -n "$LAST_ANSWER" ]] && print_answer; return 1; }
    print_answer
    [[ "$INTERACTIVE" -eq 1 ]] || return 0
  fi
  interactive_loop
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
  status=$?
  debug_log "session_end status=$status"
  exit "$status"
fi
