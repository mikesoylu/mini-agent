#!/usr/bin/env bash
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/mini-agent-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0

ok() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
not_ok() { printf 'not ok - %s\n' "$1"; FAIL=$((FAIL + 1)); }
assert_contains() { case "$1" in *"$2"*) ok "$3" ;; *) not_ok "$3 (wanted: $2; got: $1)" ;; esac; }
assert_equal() { if [[ "$1" == "$2" ]]; then ok "$3"; else not_ok "$3 (wanted: $2; got: $1)"; fi; }

cat > "$TMP/curl" <<'MOCK'
#!/usr/bin/env bash
out="" body="" url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    --data-binary) body=$2; shift 2 ;;
    http*) url=$1; shift ;;
    *) shift ;;
  esac
done
[[ "$body" == "@-" ]] && body=$(cat)
[[ -n "${MOCK_CAPTURE:-}" ]] && printf '%s' "$body" > "$MOCK_CAPTURE"
[[ -n "${MOCK_TRACE:-}" ]] && printf '%s' "$body" | jq -r '[.model, (.previous_response_id // "-")] | @tsv' >> "$MOCK_TRACE"
if [[ -n "${MOCK_HTTP_ERROR_MODEL:-}" ]] && [[ $(printf '%s' "$body" | jq -r '.model') == "$MOCK_HTTP_ERROR_MODEL" ]]; then
  printf '%s' '{"error":{"message":"temporarily overloaded"}}' > "$out"; printf '529'; exit
fi
is_compaction=$(printf '%s' "$body" | jq -r '(.instructions? // .system? // .messages[0].content? // "") | contains("context checkpoint")')
if { [[ -n "${MOCK_REFUSE_MODEL:-}" ]] && [[ $(printf '%s' "$body" | jq -r '.model') == "$MOCK_REFUSE_MODEL" ]]; } ||
   { [[ -n "${MOCK_REFUSE_COMPACTION_MODEL:-}" ]] && [[ "$is_compaction" == true ]] && [[ $(printf '%s' "$body" | jq -r '.model') == "$MOCK_REFUSE_COMPACTION_MODEL" ]]; }; then
  if [[ "$url" == */responses ]]; then
    printf '%s' '{"id":"refused_1","status":"completed","usage":{"total_tokens":12},"output":[{"type":"message","role":"assistant","content":[{"type":"refusal","refusal":"blocked by safety policy"}]}]}' > "$out"
  elif [[ "$url" == */messages ]]; then
    printf '%s' '{"type":"message","role":"assistant","content":[],"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber","explanation":"blocked by safety policy"},"usage":{"input_tokens":10,"output_tokens":2}}' > "$out"
  else
    printf '%s' '{"usage":{"total_tokens":12},"choices":[{"message":{"role":"assistant","content":null,"refusal":"blocked by safety policy"},"finish_reason":"content_filter"}]}' > "$out"
  fi
  printf '200'
  exit
fi
if [[ "$url" == */responses ]]; then
  if printf '%s' "$body" | jq -e '.instructions | contains("context checkpoint")' >/dev/null 2>&1; then
    printf '%s' '{"id":"summary_1","status":"completed","usage":{"total_tokens":50},"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"checkpoint summary","annotations":[]}]}]}' > "$out"
  elif printf '%s' "$body" | jq -e '.input[] | select(.type == "shell_call_output" or .type == "function_call_output")' >/dev/null 2>&1; then
    printf '%s' '{"id":"resp_2","status":"completed","usage":{"total_tokens":100},"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"openai done","annotations":[]}]}]}' > "$out"
  else
    if [[ -n "${MOCK_APPLY_PATCH:-}" ]]; then
      patch='*** Begin Patch
*** Add File: api-edit.txt
+edited through tool
*** End Patch'
      jq -cn --arg arguments "$(jq -cn --arg patch "$patch" '{patch:$patch}')" '{id:"resp_1",status:"completed",usage:{total_tokens:50},output:[{type:"function_call",call_id:"patch_1",name:"apply_patch",arguments:$arguments,status:"in_progress"}]}' > "$out"
      printf '200'
      exit
    elif [[ -n "${MOCK_READ_PATH:-}" ]]; then command="mini-agent-read ${MOCK_READ_PATH}"
    else command="sed -n '1,5p' sample.txt"; fi
    jq -cn --arg command "$command" '{id:"resp_1",status:"completed",usage:{total_tokens:50},output:[{type:"shell_call",call_id:"call_1",action:{commands:[$command],timeout_ms:120000,max_output_length:4096},status:"in_progress"}]}' > "$out"
  fi
elif [[ "$url" == */messages ]]; then
  if printf '%s' "$body" | jq -e '.system | contains("context checkpoint")' >/dev/null 2>&1; then
    printf '%s' '{"type":"message","usage":{"input_tokens":40,"output_tokens":10},"content":[{"type":"text","text":"checkpoint summary"}],"stop_reason":"end_turn"}' > "$out"
  elif printf '%s' "$body" | jq -e '.messages[].content[]? | select(.type == "tool_result")' >/dev/null 2>&1; then
    printf '%s' '{"type":"message","usage":{"input_tokens":80,"output_tokens":20},"content":[{"type":"text","text":"anthropic done"}],"stop_reason":"end_turn"}' > "$out"
  else
    jq -cn --arg path "${MOCK_READ_PATH:-sample.txt}" '{type:"message",usage:{input_tokens:40,output_tokens:10},content:[{type:"tool_use",id:"a1",name:"read",input:{path:$path}}],stop_reason:"tool_use"}' > "$out"
  fi
else
  if printf '%s' "$body" | jq -e '.messages[0].content | contains("context checkpoint")' >/dev/null 2>&1; then
    printf '%s' '{"usage":{"total_tokens":50},"choices":[{"message":{"role":"assistant","content":"checkpoint summary"},"finish_reason":"stop"}]}' > "$out"
  elif printf '%s' "$body" | jq -e '.messages[] | select(.role == "tool")' >/dev/null 2>&1; then
    printf '%s' '{"usage":{"total_tokens":100},"choices":[{"message":{"role":"assistant","content":"openai done"},"finish_reason":"stop"}]}' > "$out"
  else
    jq -cn --arg path "${MOCK_READ_PATH:-sample.txt}" '{usage:{total_tokens:50},choices:[{message:{role:"assistant",content:null,tool_calls:[{id:"c1",type:"function",function:{name:"read",arguments:({path:$path}|tojson)}}]},finish_reason:"tool_calls"}]}' > "$out"
  fi
fi
printf '200'
MOCK
chmod +x "$TMP/curl"
printf 'hello from fixture\n' > "$TMP/sample.txt"
printf '%s' 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=' | base64 -d > "$TMP/large.png"
dd if=/dev/zero bs=1024 count=400 >> "$TMP/large.png" 2>/dev/null
printf 'not supported\n' > "$TMP/unsupported.pdf"

out=$(OPENAI_API_KEY=test MOCK_CAPTURE="$TMP/openai.json" CURL_BIN="$TMP/curl" "$ROOT/mini-agent.sh" -q -m gpt-5.6-sol -r xhigh -C "$TMP" "inspect")
assert_contains "$out" "openai done" "OpenAI Responses shell loop"
assert_equal "$(jq -r '.reasoning.effort' "$TMP/openai.json")" "xhigh" "OpenAI Responses reasoning selection"
assert_equal "$(jq -r '.max_output_tokens' "$TMP/openai.json")" "32768" "Default maximum output tokens"
assert_equal "$(jq -r '.tools[0] | .type + ":" + .environment.type' "$TMP/openai.json")" "shell:local" "OpenAI uses native local shell"
assert_equal "$(jq -r '.tools[1].name' "$TMP/openai.json")" "apply_patch" "OpenAI exposes apply_patch"
assert_contains "$(jq -r '.input[] | select(.type == "shell_call_output") | .output[0].stdout' "$TMP/openai.json")" "hello from fixture" "OpenAI shell output continuation"

out=$(OPENAI_API_KEY=test MOCK_APPLY_PATCH=1 MOCK_CAPTURE="$TMP/openai-patch.json" CURL_BIN="$TMP/curl" "$ROOT/mini-agent.sh" -q -C "$TMP" "edit")
assert_contains "$out" "openai done" "OpenAI apply_patch loop"
assert_equal "$(jq -r '.model' "$TMP/openai-patch.json")" "gpt-5.6-sol" "OpenAI default model"
assert_equal "$(cat "$TMP/api-edit.txt")" "edited through tool" "OpenAI apply_patch edits files"
assert_contains "$(jq -r '.input[] | select(.type == "function_call_output") | .output' "$TMP/openai-patch.json")" "Success" "OpenAI apply_patch continuation"

out=$(ANTHROPIC_API_KEY=test MOCK_CAPTURE="$TMP/anthropic.json" CURL_BIN="$TMP/curl" "$ROOT/mini-agent.sh" -q -p anthropic -C "$TMP" "inspect")
assert_contains "$out" "anthropic done" "Anthropic tool loop"
assert_equal "$(jq -r '.model' "$TMP/anthropic.json")" "claude-opus-5" "Anthropic default model"
assert_equal "$(jq -r '.thinking.type + ":" + .output_config.effort' "$TMP/anthropic.json")" "adaptive:medium" "Anthropic reasoning selection"
assert_equal "$(jq -r '[.tools[].name] | contains(["apply_patch"])' "$TMP/anthropic.json")" "true" "Anthropic exposes apply_patch"

out=$(OPENROUTER_API_KEY=test MOCK_CAPTURE="$TMP/openrouter.json" CURL_BIN="$TMP/curl" "$ROOT/mini-agent.sh" -q -p openrouter --json -C "$TMP" "inspect")
answer=$(printf '%s' "$out" | jq -r '.answer')
assert_contains "$answer" "openai done" "OpenRouter JSON mode"
assert_equal "$(jq -r '.model' "$TMP/openrouter.json")" "openai/gpt-5.6-sol" "OpenRouter default model"

: > "$TMP/openai-fallback.trace"
out=$(OPENAI_API_KEY=test MOCK_REFUSE_MODEL=gpt-5.6-sol MOCK_TRACE="$TMP/openai-fallback.trace" CURL_BIN="$TMP/curl" "$ROOT/mini-agent.sh" -q -C "$TMP" "inspect")
assert_contains "$out" "openai done" "OpenAI retries a refusal"
assert_equal "$(cut -f1 "$TMP/openai-fallback.trace" | paste -sd, -)" "gpt-5.6-sol,gpt-5.6-terra,gpt-5.6-terra" "OpenAI pins fallback for the turn"
assert_equal "$(sed -n '2p' "$TMP/openai-fallback.trace" | cut -f2)" "-" "OpenAI retry does not chain from refused response"

: > "$TMP/openai-error.trace"
OPENAI_API_KEY=test MOCK_HTTP_ERROR_MODEL=gpt-5.6-sol MOCK_TRACE="$TMP/openai-error.trace" CURL_BIN="$TMP/curl" "$ROOT/mini-agent.sh" -q -C "$TMP" "inspect" >/dev/null 2>&1
assert_equal "$?" "1" "Ordinary API errors still fail"
assert_equal "$(wc -l < "$TMP/openai-error.trace" | tr -d ' ')" "1" "Ordinary API errors do not use fallback"

: > "$TMP/anthropic-fallback.trace"
out=$(ANTHROPIC_API_KEY=test MOCK_REFUSE_MODEL=claude-fable-5 MOCK_TRACE="$TMP/anthropic-fallback.trace" CURL_BIN="$TMP/curl" "$ROOT/mini-agent.sh" -q -p anthropic -m claude-fable-5 --fallback-model claude-sonnet-5 -C "$TMP" "inspect")
assert_contains "$out" "anthropic done" "Anthropic retries stop_reason refusal"
assert_equal "$(cut -f1 "$TMP/anthropic-fallback.trace" | paste -sd, -)" "claude-fable-5,claude-sonnet-5,claude-sonnet-5" "Anthropic pins configured fallback for the turn"

: > "$TMP/openrouter-fallback.trace"
out=$(OPENROUTER_API_KEY=test MOCK_REFUSE_MODEL=openai/gpt-5.6-sol MOCK_TRACE="$TMP/openrouter-fallback.trace" CURL_BIN="$TMP/curl" "$ROOT/mini-agent.sh" -q -p openrouter -C "$TMP" "inspect")
assert_contains "$out" "openai done" "OpenRouter retries a content-filter refusal"
assert_equal "$(cut -f1 "$TMP/openrouter-fallback.trace" | paste -sd, -)" "openai/gpt-5.6-sol,openai/gpt-5.6-terra,openai/gpt-5.6-terra" "OpenRouter pins fallback for the turn"

out=$(OPENAI_API_KEY=test MOCK_READ_PATH=large.png MOCK_CAPTURE="$TMP/image.json" CURL_BIN="$TMP/curl" "$ROOT/mini-agent.sh" -q -C "$TMP" "inspect image")
assert_contains "$out" "openai done" "Large image attachment avoids argument limits"
assert_equal "$(jq -r '.input[] | select(.role == "user") | .content[] | select(.type == "input_image") | .type' "$TMP/image.json")" "input_image" "Native shell can request image input"

out=$(printf '/quit\n' | OPENAI_API_KEY=test CURL_BIN="$TMP/curl" "$ROOT/mini-agent.sh" -q -i -C "$TMP" "interactive start")
assert_contains "$out" "mini-agent openai" "Interactive mode"

help=$($ROOT/mini-agent.sh --help)
assert_contains "$help" "interactive mode" "Help output"
assert_contains "$help" "default: 1024" "Help shows default maximum turns"
assert_contains "$help" "default: 32768" "Help shows default maximum output tokens"
assert_contains "$help" "default: 262144" "Help shows default compaction threshold"
assert_contains "$help" "--fallback-model" "Help shows fallback model option"

source "$ROOT/mini-agent.sh"
assert_equal "$MAX_TURNS" "1024" "Default maximum turns"
assert_equal "$COMPACT_TOKENS" "262144" "Default compaction threshold"
WORKDIR="$TMP"
: > "$TMP/compaction-fallback.trace"
PROVIDER=anthropic; MODEL=claude-opus-5; TURN_MODEL=$MODEL; FALLBACK_MODEL=claude-sonnet-5; API_URL=https://mock.invalid/v1; ANTHROPIC_API_KEY=test; CURL_BIN="$TMP/curl"
MOCK_REFUSE_COMPACTION_MODEL=claude-opus-5 MOCK_TRACE="$TMP/compaction-fallback.trace" call_compaction_summary "summarize this"
assert_equal "$COMPACTION_SUMMARY" "checkpoint summary" "Compaction retries a refusal"
assert_equal "$(cut -f1 "$TMP/compaction-fallback.trace" | paste -sd, -)" "claude-opus-5,claude-sonnet-5" "Compaction uses the fallback model"
assert_equal "$TURN_MODEL" "claude-sonnet-5" "Compaction pins the fallback for the turn"
tool_result=$(run_bash 'printf "bash tool works"')
assert_contains "$(printf '%s' "$tool_result" | jq -r '.text')" "bash tool works" "Bash tool execution"
read_result=$(read_file unsupported.pdf)
assert_equal "$(printf '%s' "$read_result" | jq -r '.kind + ":" + .text')" "error:PDF files are not supported by the read tool." "Read tool rejects PDFs"
attachment_result=$(native_attachment unsupported.pdf)
assert_contains "$(printf '%s' "$attachment_result" | jq -r '.error')" "not supported" "Native image reader rejects PDFs"

printf 'alpha\nbeta   \ngamma\n' > "$TMP/edit.txt"
patch='*** Begin Patch
*** Add File: transient.txt
+temporary
*** Update File: edit.txt
*** Move to: moved.txt
@@
 alpha
-beta
+BETTER
 gamma
*** Delete File: transient.txt
*** End Patch'
patch_result=$(run_tool apply_patch "$(jq -cn --arg patch "$patch" '{patch:$patch}')")
assert_equal "$(printf '%s' "$patch_result" | jq -r '.exit_status')" "0" "apply_patch add, update, move, and delete"
assert_equal "$(sed -n '2p' "$TMP/moved.txt")" "BETTER" "apply_patch uses Codex whitespace-tolerant matching"
assert_equal "$(test ! -e "$TMP/transient.txt" && printf true)" "true" "apply_patch deletes files"
escape_patch='*** Begin Patch
*** Add File: ../escape.txt
+blocked
*** End Patch'
escape_result=$(run_tool apply_patch "$(jq -cn --arg patch "$escape_patch" '{patch:$patch}')")
assert_equal "$(printf '%s' "$escape_result" | jq -r '.exit_status')" "1" "apply_patch rejects paths outside the workdir"

PROVIDER=anthropic
API_RESPONSE='{"usage":{"input_tokens":100,"output_tokens":20,"cache_read_input_tokens":30,"cache_creation_input_tokens":40}}'
assert_equal "$(response_context_tokens)" "190" "Anthropic context count includes cache tokens"
PROVIDER=openrouter; MODEL=test; TURN_MODEL=""; FALLBACK_MODEL=""; API_URL=https://mock.invalid/v1; OPENROUTER_API_KEY=test; CURL_BIN="$TMP/curl"
HISTORY='[{"role":"user","content":"old request"},{"role":"assistant","content":"old answer"},{"role":"user","content":"recent request"},{"role":"assistant","content":"recent answer"}]'
COMPACT_TOKENS=100; CONTEXT_TOKENS=100
maybe_compact
assert_equal "$(printf '%s' "$HISTORY" | jq 'length')" "3" "Compaction keeps the latest complete turn"
assert_contains "$(printf '%s' "$HISTORY" | jq -r '.[0].content')" "checkpoint summary" "Compaction injects the generated checkpoint"
assert_equal "$CONTEXT_TOKENS" "0" "Compaction resets context usage"

if bash -n "$ROOT/mini-agent.sh"; then ok "Bash syntax"; else not_ok "Bash syntax"; fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
