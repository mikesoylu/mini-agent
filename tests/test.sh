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
assert_not_contains() { case "$1" in *"$2"*) not_ok "$3 (did not want: $2)" ;; *) ok "$3" ;; esac; }
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
if [[ -n "${MOCK_NO_TOOLS_CAPTURE:-}" ]] &&
   printf '%s' "$body" | jq -e 'has("tools") | not' >/dev/null 2>&1; then
  printf '%s' "$body" > "$MOCK_NO_TOOLS_CAPTURE"
fi
[[ -z "${MOCK_DELAY:-}" ]] || sleep "$MOCK_DELAY"
[[ -n "${MOCK_TRACE:-}" ]] && printf '%s' "$body" | jq -r '[.model, (.previous_response_id // "-")] | @tsv' >> "$MOCK_TRACE"
if [[ -n "${MOCK_HTTP_ERROR_MODEL:-}" ]] && [[ $(printf '%s' "$body" | jq -r '.model') == "$MOCK_HTTP_ERROR_MODEL" ]]; then
  printf '%s' '{"error":{"message":"temporarily overloaded"}}' > "$out"; printf '529'; exit
fi
if [[ -n "${MOCK_HTTP_REFUSE_MODEL:-}" ]] && [[ $(printf '%s' "$body" | jq -r '.model') == "$MOCK_HTTP_REFUSE_MODEL" ]]; then
  printf '%s' '{"error":{"message":"This content was flagged for possible cybersecurity risk. If this seems wrong, try rephrasing your request.","type":"invalid_request_error","code":"content_policy_violation"}}' > "$out"; printf '400'; exit
fi
is_compaction=$(printf '%s' "$body" | jq -r '
  ([.input[]?.content[]?.text?, (.messages[-1]?.content? | select(type == "string"))] | last // "") |
  startswith("Create a context checkpoint summarizing")')
is_compacted_continuation=$(printf '%s' "$body" | jq -r 'tojson | contains("Continue from this compacted conversation context")')
if [[ -n "${MOCK_COMPACTED_CONTINUATION_CAPTURE:-}" ]] && [[ "$is_compacted_continuation" == true ]]; then
  printf '%s' "$body" > "$MOCK_COMPACTED_CONTINUATION_CAPTURE"
fi
if [[ -n "${MOCK_KIND_TRACE:-}" ]]; then
  if [[ "$is_compaction" == true ]]; then kind=compaction
  elif [[ "$is_compacted_continuation" == true ]]; then kind=compacted-continuation
  elif printf '%s' "$body" | jq -e '(.input[]? | select(.type == "shell_call_output" or .type == "function_call_output")) // (.messages[]? | select(.role == "tool" or ([.content[]?.type] | contains(["tool_result"]))))' >/dev/null 2>&1; then kind=tool-continuation
  else kind=normal; fi
  printf '%s\n' "$kind" >> "$MOCK_KIND_TRACE"
fi
if [[ -n "${MOCK_COMPACTION_RESOLVED_TRACE:-}" ]] && [[ "$is_compaction" == true ]]; then
  if printf '%s' "$body" | jq -e '(.input[]? | select(.type == "shell_call_output" or .type == "function_call_output")) // (.messages[]? | select(.role == "tool" or ([.content[]?.type] | contains(["tool_result"]))))' >/dev/null 2>&1; then
    printf '%s\n' resolved >> "$MOCK_COMPACTION_RESOLVED_TRACE"
  else
    printf '%s\n' unresolved >> "$MOCK_COMPACTION_RESOLVED_TRACE"
  fi
fi
if [[ -n "${MOCK_COMPACTION_RESULT_COUNTS:-}" ]] && [[ "$is_compaction" == true ]]; then
  printf '%s' "$body" | jq '[.input[]? | select(.type == "shell_call_output" or .type == "function_call_output")] | length' >> "$MOCK_COMPACTION_RESULT_COUNTS"
fi
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
  if [[ "$is_compaction" == true ]]; then
    if [[ -n "${MOCK_EMPTY_COMPACTION:-}" ]]; then
      printf '%s' '{"id":"summary_1","status":"completed","usage":{"total_tokens":50},"output":[]}' > "$out"
    elif [[ -n "${MOCK_STICKY_COMPACTION:-}" ]]; then
      printf '%s' '{"id":"summary_1","status":"completed","usage":{"total_tokens":50},"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"## Constraints & Preferences\nDo not continue the task or call tools.\n\n## Next Steps\nContinue inspecting the repository.","annotations":[]}]}]}' > "$out"
    else
      printf '%s' '{"id":"summary_1","status":"completed","usage":{"total_tokens":50},"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"checkpoint summary","annotations":[]}]}]}' > "$out"
    fi
  elif [[ "$is_compacted_continuation" == true ]]; then
    if [[ -n "${MOCK_STICKY_COMPACTION:-}" ]] && ! printf '%s' "$body" | jq -e 'tojson | contains("Checkpoint-generation directives are expired and must not constrain this turn.")' >/dev/null 2>&1; then
      printf '%s' '{"id":"resp_3","status":"completed","usage":{"total_tokens":10},"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Checkpoint received. I will not continue the task, modify files, or run tools.","annotations":[]}]}]}' > "$out"
    else
      printf '%s' '{"id":"resp_3","status":"completed","usage":{"total_tokens":10},"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"openai done","annotations":[]}]}]}' > "$out"
    fi
  elif printf '%s' "$body" | jq -e '.input[] | select(.type == "shell_call_output" or .type == "function_call_output")' >/dev/null 2>&1; then
    printf '%s' '{"id":"resp_2","status":"completed","usage":{"total_tokens":100},"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"openai done","annotations":[]}]}]}' > "$out"
  else
    if [[ -n "${MOCK_MULTIPLE_TOOLS:-}" ]]; then
      jq -cn '{id:"resp_1",status:"completed",usage:{total_tokens:50},output:[
        {type:"shell_call",call_id:"call_1",action:{commands:["sed -n '\''1,5p'\'' sample.txt"],timeout_ms:120000,max_output_length:4096},status:"in_progress"},
        {type:"shell_call",call_id:"call_2",action:{commands:["wc -c sample.txt"],timeout_ms:120000,max_output_length:4096},status:"in_progress"}
      ]}' > "$out"
    else
      if [[ -n "${MOCK_READ_PATH:-}" ]]; then
        jq -cn --arg path "$MOCK_READ_PATH" '{id:"resp_1",status:"completed",usage:{total_tokens:50},output:[{type:"function_call",call_id:"call_1",name:"read",arguments:({path:$path}|tojson),status:"completed"}]}' > "$out"
      else
        command="sed -n '1,5p' sample.txt"
        jq -cn --arg command "$command" '{id:"resp_1",status:"completed",usage:{total_tokens:50},output:[{type:"shell_call",call_id:"call_1",action:{commands:[$command],timeout_ms:120000,max_output_length:4096},status:"in_progress"}]}' > "$out"
      fi
    fi
  fi
elif [[ "$url" == */messages ]]; then
  if [[ "$is_compaction" == true ]]; then
    printf '%s' '{"type":"message","usage":{"input_tokens":40,"output_tokens":10},"content":[{"type":"text","text":"checkpoint summary"}],"stop_reason":"end_turn"}' > "$out"
  elif printf '%s' "$body" | jq -e '.messages[].content[]? | select(.type == "tool_result")' >/dev/null 2>&1; then
    printf '%s' '{"type":"message","usage":{"input_tokens":80,"output_tokens":20},"content":[{"type":"text","text":"anthropic done"}],"stop_reason":"end_turn"}' > "$out"
  else
    jq -cn --arg path "${MOCK_READ_PATH:-sample.txt}" '{type:"message",usage:{input_tokens:40,output_tokens:10},content:[{type:"tool_use",id:"a1",name:"read",input:{path:$path}}],stop_reason:"tool_use"}' > "$out"
  fi
else
  if [[ "$is_compaction" == true ]]; then
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
cp "$TMP/large.png" "$TMP/oversized.png"
dd if=/dev/zero bs=1024 count=700 >> "$TMP/oversized.png" 2>/dev/null
printf 'not supported\n' > "$TMP/unsupported.pdf"

out=$(OPENAI_API_KEY=test MOCK_CAPTURE="$TMP/openai.json" CURL_BIN="$TMP/curl" "$ROOT/mini-agent.sh" -q -m gpt-5.6-sol -r xhigh -C "$TMP" "inspect")
assert_contains "$out" "openai done" "OpenAI Responses shell loop"
assert_equal "$(jq -r '.reasoning.effort' "$TMP/openai.json")" "xhigh" "OpenAI Responses reasoning selection"
assert_equal "$(jq -r '.max_output_tokens' "$TMP/openai.json")" "32768" "Default maximum output tokens"
assert_equal "$(jq -r '.tools[0] | .type + ":" + .environment.type' "$TMP/openai.json")" "shell:local" "OpenAI uses native local shell"
assert_equal "$(jq -r '.tools[1] | .type + ":" + .name' "$TMP/openai.json")" "function:read" "OpenAI uses a compatible read function"
assert_equal "$(jq '.tools | length' "$TMP/openai.json")" "2" "OpenAI exposes read and shell only"
assert_contains "$(jq -r '.instructions' "$TMP/openai.json")" "<system_information>" "System prompt includes machine information"
assert_contains "$(jq -r '.instructions' "$TMP/openai.json")" "cat <<'EOF' > newfile.py" "System prompt includes file creation example"
assert_contains "$(jq -r '.instructions' "$TMP/openai.json")" "nl -ba filename.py | sed -n '10,20p'" "System prompt includes file viewing example"
if [[ $(uname -s) == Darwin ]]; then assert_contains "$(jq -r '.instructions' "$TMP/openai.json")" "sed -i ''" "System prompt includes macOS sed syntax"; fi
assert_contains "$(jq -r '.input[] | select(.type == "shell_call_output") | .output[0].stdout' "$TMP/openai.json")" "hello from fixture" "OpenAI shell output continuation"
assert_equal "$(jq -r '.model' "$TMP/openai.json")" "gpt-5.6-sol" "OpenAI default model"

progress=$(OPENAI_API_KEY=test CURL_BIN="$TMP/curl" "$ROOT/mini-agent.sh" -m gpt-5.6-sol -C "$TMP" "inspect" 2>&1 >/dev/null)
assert_contains "$progress" "context unknown/262144 · turn 1/1024" "Progress shows unknown context before initial usage"
assert_contains "$progress" "context 50/262144 · turn 2/1024" "Progress shows latest provider context usage"

out=$(ANTHROPIC_API_KEY=test MOCK_CAPTURE="$TMP/anthropic.json" CURL_BIN="$TMP/curl" "$ROOT/mini-agent.sh" -q -p anthropic -C "$TMP" "inspect")
assert_contains "$out" "anthropic done" "Anthropic tool loop"
assert_equal "$(jq -r '.model' "$TMP/anthropic.json")" "claude-opus-5" "Anthropic default model"
assert_equal "$(jq -r '.thinking.type + ":" + .output_config.effort' "$TMP/anthropic.json")" "adaptive:medium" "Anthropic reasoning selection"
assert_equal "$(jq -r '[.tools[].name] | join(",")' "$TMP/anthropic.json")" "read,shell" "Anthropic exposes read and shell only"

out=$(OPENROUTER_API_KEY=test MOCK_CAPTURE="$TMP/openrouter.json" CURL_BIN="$TMP/curl" "$ROOT/mini-agent.sh" -q -p openrouter --json -C "$TMP" "inspect")
answer=$(printf '%s' "$out" | jq -r '.answer')
assert_contains "$answer" "openai done" "OpenRouter JSON mode"
assert_equal "$(jq -r '.model' "$TMP/openrouter.json")" "openai/gpt-5.6-sol" "OpenRouter default model"
assert_equal "$(jq -r '[.tools[].function.name] | join(",")' "$TMP/openrouter.json")" "read,shell" "OpenRouter exposes read and shell only"

: > "$TMP/openai-fallback.trace"
out=$(OPENAI_API_KEY=test MOCK_REFUSE_MODEL=gpt-5.6-sol MOCK_TRACE="$TMP/openai-fallback.trace" CURL_BIN="$TMP/curl" "$ROOT/mini-agent.sh" -q -C "$TMP" "inspect")
assert_contains "$out" "openai done" "OpenAI retries a refusal"
assert_equal "$(cut -f1 "$TMP/openai-fallback.trace" | paste -sd, -)" "gpt-5.6-sol,gpt-5.6-terra,gpt-5.6-terra" "OpenAI pins fallback for the turn"
assert_equal "$(sed -n '2p' "$TMP/openai-fallback.trace" | cut -f2)" "-" "OpenAI retry does not chain from refused response"

: > "$TMP/openai-http-fallback.trace"
out=$(OPENAI_API_KEY=test MOCK_HTTP_REFUSE_MODEL=gpt-5.6-sol MOCK_TRACE="$TMP/openai-http-fallback.trace" CURL_BIN="$TMP/curl" "$ROOT/mini-agent.sh" -q -C "$TMP" "inspect")
assert_contains "$out" "openai done" "OpenAI retries an HTTP safety rejection"
assert_equal "$(cut -f1 "$TMP/openai-http-fallback.trace" | paste -sd, -)" "gpt-5.6-sol,gpt-5.6-terra,gpt-5.6-terra" "OpenAI HTTP safety rejection pins fallback for the turn"

: > "$TMP/openai-error.trace"
OPENAI_API_KEY=test MOCK_HTTP_ERROR_MODEL=gpt-5.6-sol MOCK_TRACE="$TMP/openai-error.trace" CURL_BIN="$TMP/curl" "$ROOT/mini-agent.sh" -q -C "$TMP" "inspect" >/dev/null 2>&1
assert_equal "$?" "1" "Ordinary API errors still fail"
assert_equal "$(wc -l < "$TMP/openai-error.trace" | tr -d ' ')" "1" "Ordinary API errors do not use fallback"

: > "$TMP/anthropic-fallback.trace"
out=$(ANTHROPIC_API_KEY=test MOCK_REFUSE_MODEL=claude-fable-5 MOCK_TRACE="$TMP/anthropic-fallback.trace" CURL_BIN="$TMP/curl" "$ROOT/mini-agent.sh" -q -p anthropic -m claude-fable-5 --fallback-model claude-sonnet-5 -C "$TMP" "inspect")
assert_contains "$out" "anthropic done" "Anthropic retries stop_reason refusal"
assert_equal "$(cut -f1 "$TMP/anthropic-fallback.trace" | paste -sd, -)" "claude-fable-5,claude-sonnet-5,claude-sonnet-5" "Anthropic pins configured fallback for the turn"

: > "$TMP/anthropic-session-fallback.trace"
out=$(printf 'second request\n/clear\nthird request\n/quit\n' | ANTHROPIC_API_KEY=test MOCK_REFUSE_MODEL=claude-fable-5 MOCK_TRACE="$TMP/anthropic-session-fallback.trace" CURL_BIN="$TMP/curl" "$ROOT/mini-agent.sh" -q -i -p anthropic -m claude-fable-5 --fallback-model claude-sonnet-5 -C "$TMP" "first request")
assert_contains "$out" "anthropic done" "Anthropic interactive session continues after fallback"
assert_equal "$(cut -f1 "$TMP/anthropic-session-fallback.trace" | paste -sd, -)" "claude-fable-5,claude-sonnet-5,claude-sonnet-5,claude-sonnet-5,claude-sonnet-5,claude-sonnet-5" "Anthropic keeps fallback for subsequent messages and /clear"

: > "$TMP/openrouter-fallback.trace"
out=$(OPENROUTER_API_KEY=test MOCK_REFUSE_MODEL=openai/gpt-5.6-sol MOCK_TRACE="$TMP/openrouter-fallback.trace" CURL_BIN="$TMP/curl" "$ROOT/mini-agent.sh" -q -p openrouter -C "$TMP" "inspect")
assert_contains "$out" "openai done" "OpenRouter retries a content-filter refusal"
assert_equal "$(cut -f1 "$TMP/openrouter-fallback.trace" | paste -sd, -)" "openai/gpt-5.6-sol,openai/gpt-5.6-terra,openai/gpt-5.6-terra" "OpenRouter pins fallback for the turn"

out=$(OPENAI_API_KEY=test MOCK_READ_PATH=large.png MOCK_CAPTURE="$TMP/image.json" CURL_BIN="$TMP/curl" "$ROOT/mini-agent.sh" -q -C "$TMP" "inspect image")
assert_contains "$out" "openai done" "Large image attachment avoids argument limits"
assert_equal "$(jq -r '.input[] | select(.role == "user") | .content[] | select(.type == "input_image") | .type' "$TMP/image.json")" "input_image" "OpenAI read can attach image input"

out=$(OPENAI_API_KEY=test MOCK_READ_PATH=oversized.png MOCK_CAPTURE="$TMP/oversized-image.json" CURL_BIN="$TMP/curl" "$ROOT/mini-agent.sh" -q -C "$TMP" "inspect oversized image")
assert_contains "$out" "openai done" "Oversized image read completes with a tool error"
assert_contains "$(jq -r '.input[] | select(.type == "function_call_output") | .output' "$TMP/oversized-image.json")" "Use the shell tool to resize or compress" "OpenAI read explains how to shrink an oversized image"
assert_equal "$(jq '[.input[] | select(.role == "user") | .content[] | select(.type == "input_image")] | length' "$TMP/oversized-image.json")" "0" "Oversized image is not attached to OpenAI"

out=$(printf '/quit\n' | OPENAI_API_KEY=test CURL_BIN="$TMP/curl" "$ROOT/mini-agent.sh" -q -i -C "$TMP" "interactive start")
assert_contains "$out" "mini-agent openai" "Interactive mode"

out=$(printf '/status\n/compact\n/status\n/quit\n' | OPENAI_API_KEY=test CURL_BIN="$TMP/curl" "$ROOT/mini-agent.sh" -q -i -C "$TMP" "interactive start")
assert_contains "$out" "conversation tokens: 100 / 262144" "/status shows exact provider token usage"
assert_contains "$out" "context compacted" "/compact compacts manually"
assert_contains "$out" "conversation tokens: unknown" "/status marks post-compaction usage unknown"

if command -v expect >/dev/null 2>&1; then
  EXPECT_ROOT="$ROOT" EXPECT_TMP="$TMP" expect <<'EXPECT_QUEUE'
set timeout 15
log_user 0
set root $env(EXPECT_ROOT)
set tmp $env(EXPECT_TMP)
spawn env OPENAI_API_KEY=test MOCK_DELAY=1 MOCK_CAPTURE=$tmp/queued-interactive.json CURL_BIN=$tmp/curl $root/mini-agent.sh -C $tmp
expect "> "
send -- "inspect\r"
expect "model "
expect "(queue) "
send -- "queued follow-up\r"
expect "queued message"
expect "openai done"
expect "> "
send -- "/quit\r"
expect eof
EXPECT_QUEUE
  assert_equal "$(jq -r '[.input[] | if .type == "shell_call_output" then "tool_result" elif .role == "user" then .content[0].text else empty end] | join(",")' "$TMP/queued-interactive.json")" "tool_result,queued follow-up" "Interactive input is queued after OpenAI tool results"

  EXPECT_ROOT="$ROOT" EXPECT_TMP="$TMP" expect <<'EXPECT_EOF'
set timeout 15
log_user 0
set root $env(EXPECT_ROOT)
set tmp $env(EXPECT_TMP)
spawn env OPENAI_API_KEY=test MOCK_DELAY=1 MOCK_KIND_TRACE=$tmp/ctrl-d-kinds.trace MOCK_NO_TOOLS_CAPTURE=$tmp/ctrl-d-drain.json CURL_BIN=$tmp/curl $root/mini-agent.sh --debug-dir $tmp/ctrl-d-debug -C $tmp
expect "> "
send -- "\004"
expect "> "
send -- "inspect\r"
expect "model "
expect "(queue) "
send -- "\004"
expect "stop requested"
expect "execution stopped"
expect "> "
send -- "interesting\r"
expect "model "
expect "openai done"
expect "> "
send -- "/quit\r"
expect eof
EXPECT_EOF
  assert_equal "$(find "$TMP/ctrl-d-debug" -name 'api-request.json.*' | wc -l | tr -d ' ')" "4" "Ctrl-D drains the current tool round before accepting the next request"
  assert_contains "$(cat "$(find "$TMP/ctrl-d-debug" -name 'openai-next-input.json.*' | head -1)")" "shell_call_output" "Ctrl-D resolves current OpenAI shell calls before stopping"
  assert_equal "$(paste -sd, "$TMP/ctrl-d-kinds.trace")" "normal,tool-continuation,normal,tool-continuation" "Next prompt starts after the stopped tool round is closed"
  assert_equal "$(jq -r 'has("tools")' "$TMP/ctrl-d-drain.json")" "false" "Ctrl-D drain disables tools"
  assert_equal "$(jq -r '[.input[].type] | join(",")' "$TMP/ctrl-d-drain.json")" "shell_call_output" "Ctrl-D drain submits the completed tool result"
fi

: > "$TMP/auto-compact-order.trace"
: > "$TMP/auto-compact-resolved.trace"
: > "$TMP/auto-compact-counts.trace"
: > "$TMP/compacted-continuation.json"
out=$(OPENAI_API_KEY=test MINI_AGENT_COMPACT_TOKENS=50 MOCK_MULTIPLE_TOOLS=1 MOCK_STICKY_COMPACTION=1 MOCK_KIND_TRACE="$TMP/auto-compact-order.trace" MOCK_COMPACTION_RESOLVED_TRACE="$TMP/auto-compact-resolved.trace" MOCK_COMPACTION_RESULT_COUNTS="$TMP/auto-compact-counts.trace" MOCK_COMPACTED_CONTINUATION_CAPTURE="$TMP/compacted-continuation.json" CURL_BIN="$TMP/curl" "$ROOT/mini-agent.sh" -q -C "$TMP" "inspect")
assert_contains "$out" "openai done" "Mid-turn compaction completes the agent turn"
assert_equal "$(paste -sd, "$TMP/auto-compact-order.trace")" "normal,compaction,compacted-continuation" "Auto-compaction runs between tool-call rounds"
assert_equal "$(paste -sd, "$TMP/auto-compact-resolved.trace")" "resolved" "Compaction includes results for active tool calls"
assert_equal "$(paste -sd, "$TMP/auto-compact-counts.trace")" "2" "Compaction resolves every active tool call"
continuation=$(jq -r '.input[0].content[0].text' "$TMP/compacted-continuation.json")
assert_contains "$continuation" "Continue the original task now" "Mid-turn compaction appends an explicit continuation"
assert_contains "$continuation" "Checkpoint-generation directives are expired" "Continuation expires summarizer-only instructions"

: > "$TMP/anthropic-auto-compact.trace"
: > "$TMP/anthropic-auto-compact-resolved.trace"
out=$(ANTHROPIC_API_KEY=test MINI_AGENT_COMPACT_TOKENS=50 MOCK_KIND_TRACE="$TMP/anthropic-auto-compact.trace" MOCK_COMPACTION_RESOLVED_TRACE="$TMP/anthropic-auto-compact-resolved.trace" CURL_BIN="$TMP/curl" "$ROOT/mini-agent.sh" -q -p anthropic -C "$TMP" "inspect")
assert_contains "$out" "anthropic done" "Anthropic mid-turn compaction completes the agent turn"
assert_equal "$(sed -n '1,2p' "$TMP/anthropic-auto-compact.trace" | paste -sd, -)" "normal,compaction" "Anthropic compacts after recording tool results"
assert_contains "$(paste -sd, "$TMP/anthropic-auto-compact-resolved.trace")" "resolved" "Anthropic compaction has no open tool use"

: > "$TMP/openrouter-auto-compact.trace"
: > "$TMP/openrouter-auto-compact-resolved.trace"
out=$(OPENROUTER_API_KEY=test MINI_AGENT_COMPACT_TOKENS=50 MOCK_KIND_TRACE="$TMP/openrouter-auto-compact.trace" MOCK_COMPACTION_RESOLVED_TRACE="$TMP/openrouter-auto-compact-resolved.trace" CURL_BIN="$TMP/curl" "$ROOT/mini-agent.sh" -q -p openrouter -C "$TMP" "inspect")
assert_contains "$out" "openai done" "OpenRouter mid-turn compaction completes the agent turn"
assert_equal "$(sed -n '1,2p' "$TMP/openrouter-auto-compact.trace" | paste -sd, -)" "normal,compaction" "OpenRouter compacts after recording tool results"
assert_contains "$(paste -sd, "$TMP/openrouter-auto-compact-resolved.trace")" "resolved" "OpenRouter compaction has no open tool call"

: > "$TMP/empty-compaction.trace"
out=$(OPENAI_API_KEY=test MINI_AGENT_COMPACT_TOKENS=50 MOCK_EMPTY_COMPACTION=1 MOCK_KIND_TRACE="$TMP/empty-compaction.trace" CURL_BIN="$TMP/curl" "$ROOT/mini-agent.sh" -q -C "$TMP" "inspect" 2>/dev/null)
assert_contains "$out" "openai done" "Empty compaction summary does not abort the agent turn"
assert_equal "$(sed -n '1,3p' "$TMP/empty-compaction.trace" | paste -sd, -)" "normal,compaction,tool-continuation" "Failed compaction preserves the resolved OpenAI continuation"

debug_dir="$TMP/debug-bundle"
out=$(OPENAI_API_KEY=super-secret-test-value MINI_AGENT_COMPACT_TOKENS=50 MOCK_EMPTY_COMPACTION=1 CURL_BIN="$TMP/curl" "$ROOT/mini-agent.sh" --debug-dir "$debug_dir" -q -C "$TMP" "inspect" 2>"$TMP/debug.stderr")
assert_contains "$out" "openai done" "Debug mode preserves normal output"
assert_contains "$(cat "$debug_dir/events.log")" "session_start ppid=" "Debug log records process metadata"
assert_contains "$(cat "$debug_dir/events.log")" "compaction_summary_failed stage=extract reason=empty_summary" "Debug log records compaction extraction failures"
assert_contains "$(cat "$debug_dir/events.log")" "automatic_compaction_failed action=continue_current_context" "Debug log records compaction recovery"
assert_contains "$(cat "$debug_dir/events.log")" "session_end status=0" "Debug log records process exit"
if [[ -e "$debug_dir/environment.txt" ]]; then not_ok "Debug bundle omits the process environment"; else ok "Debug bundle omits the process environment"; fi
if grep -R -q 'super-secret-test-value' "$debug_dir"; then not_ok "Debug bundle does not expose API key values"; else ok "Debug bundle does not expose API key values"; fi
assert_equal "$(find "$debug_dir" -name 'api-request.json.*' | wc -l | tr -d ' ')" "4" "Debug bundle captures every API request"
assert_equal "$(find "$debug_dir" -name 'api-response.json.*' | wc -l | tr -d ' ')" "4" "Debug bundle captures every API response"
assert_contains "$(cat "$(find "$debug_dir" -name 'tool-shell-stdout.txt.*' | head -1)")" "hello from fixture" "Debug bundle captures raw tool output"
assert_equal "$(find "$debug_dir" -name 'compact-history-before.json.*' | wc -l | tr -d ' ')" "2" "Debug bundle captures compaction history"
assert_contains "$(cat "$TMP/debug.stderr")" "mini-agent: debug bundle:" "Debug mode reports the bundle path"

help=$($ROOT/mini-agent.sh --help)
assert_contains "$help" "interactive mode" "Help output"
assert_contains "$help" "default: 1024" "Help shows default maximum turns"
assert_contains "$help" "default: 32768" "Help shows default maximum output tokens"
assert_contains "$help" "default: 262144" "Help shows default compaction threshold"
assert_contains "$help" "--fallback-model" "Help shows fallback model option"
assert_contains "$help" "--debug" "Help shows debug option"

source "$ROOT/mini-agent.sh"
assert_equal "$MAX_TURNS" "1024" "Default maximum turns"
assert_equal "$COMPACT_TOKENS" "262144" "Default compaction threshold"
C_CYAN=$'\033[36m'; C_RESET=$'\033[0m'
assert_equal "$(interactive_prompt | od -An -t u1 | tr -s ' ' | sed 's/^ //; s/ $//')" "1 27 91 51 54 109 2 62 32 1 27 91 48 109 2" "Interactive prompt marks colors as non-printing for Readline"
C_CYAN=""; C_RESET=""
WORKDIR="$TMP"
PROVIDER=openai
HISTORY='[{"role":"assistant","content":"[tool call] read"},{"role":"tool","name":"read","content":"file contents"}]'
INTERACTIVE_QUEUED_MESSAGES='["queued first","queued second"]'
apply_interactive_messages 1
queued_input=$(openai_input_with_queued_messages '[{"type":"function_call_output","call_id":"call_1","output":"file contents"}]')
assert_equal "$(printf '%s' "$queued_input" | jq -r '[.[] | if .type == "function_call_output" then .type else .role end] | join(",")')" "function_call_output,user,user" "OpenAI queues messages after function results"
assert_equal "$(printf '%s' "$HISTORY" | jq -r '[.[].role] | join(",")')" "assistant,tool,user,user" "OpenAI history records queued messages after tool results"

PROVIDER=anthropic
HISTORY='[{"role":"assistant","content":[{"type":"tool_use","id":"a1","name":"read","input":{"path":"sample.txt"}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"a1","content":"file contents"}]}]'
INTERACTIVE_QUEUED_MESSAGES='["queued first","queued second"]'
apply_interactive_messages 1
assert_equal "$(printf '%s' "$HISTORY" | jq -r '[.[-1].content[].type] | join(",")')" "tool_result,text,text" "Anthropic queues messages after tool results"

PROVIDER=openrouter
HISTORY='[{"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"read","arguments":"{}"}}]},{"role":"tool","tool_call_id":"c1","name":"read","content":"file contents"}]'
INTERACTIVE_QUEUED_MESSAGES='["queued next"]'
apply_interactive_messages 1
assert_equal "$(printf '%s' "$HISTORY" | jq -r '[.[].role] | join(",")')" "assistant,tool,user" "OpenRouter queues messages after tool results"

: > "$TMP/compaction-fallback.trace"
PROVIDER=anthropic; MODEL=claude-opus-5; TURN_MODEL=$MODEL; FALLBACK_MODEL=claude-sonnet-5; API_URL=https://mock.invalid/v1; ANTHROPIC_API_KEY=test; CURL_BIN="$TMP/curl"
HISTORY='[{"role":"user","content":"Inspect /tmp/chart.png"},{"role":"assistant","content":"The attached chart shows rising latency."},{"role":"user","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"aW1hZ2U="}},{"type":"text","text":"Image attached: /tmp/chart.png"}]}]'
prompt=$(compaction_user_prompt)
assert_not_contains "$prompt" "do not continue the task or call tools" "Compaction prompt does not seed a stale stop instruction"
MOCK_REFUSE_COMPACTION_MODEL=claude-opus-5 MOCK_TRACE="$TMP/compaction-fallback.trace" MOCK_CAPTURE="$TMP/compaction.json" call_compaction_summary "$prompt"
assert_equal "$COMPACTION_SUMMARY" "checkpoint summary" "Compaction retries a refusal"
assert_equal "$(cut -f1 "$TMP/compaction-fallback.trace" | paste -sd, -)" "claude-opus-5,claude-sonnet-5" "Compaction uses the fallback model"
assert_equal "$TURN_MODEL" "claude-sonnet-5" "Compaction pins the fallback for the turn"
assert_equal "$(jq -c '.messages[:-1]' "$TMP/compaction.json")" "$HISTORY" "Compaction preserves the cacheable conversation prefix"
assert_equal "$(jq -r '.messages[-2].content[0].source.data' "$TMP/compaction.json")" "aW1hZ2U=" "Compaction preserves image attachments"
assert_contains "$(jq -r '.messages[-1].content' "$TMP/compaction.json")" "Image Attachments" "Compaction asks for image paths and summaries"

PROVIDER=openai; MODEL=gpt-5.6-sol; TURN_MODEL=$MODEL; FALLBACK_MODEL=gpt-5.6-terra; API_URL=https://mock.invalid/v1; OPENAI_API_KEY=test; OPENAI_PREVIOUS_RESPONSE_ID=resp_cached
COMPACT_TOKENS=5000; COMPACT_MAX_TOKENS=13107; MAX_TOKENS=32768
MOCK_CAPTURE="$TMP/openai-compaction.json" call_compaction_summary "$prompt"
assert_equal "$(jq -r '.previous_response_id' "$TMP/openai-compaction.json")" "resp_cached" "OpenAI compaction appends to the response chain"
assert_contains "$(jq -r '.input[-1].content[0].text' "$TMP/openai-compaction.json")" "Image Attachments" "OpenAI appends only the compaction user message"
assert_equal "$OPENAI_PREVIOUS_RESPONSE_ID" "resp_cached" "OpenAI compaction preserves the active response cursor"
assert_equal "$(jq -r '.max_output_tokens' "$TMP/openai-compaction.json")" "2500" "Checkpoint output is capped at half the compaction threshold"
long_checkpoint=$(awk 'BEGIN {for (i=0; i<5000; i++) printf "x"}')
long_raw=$(awk 'BEGIN {for (i=0; i<5000; i++) printf "y"}')
HISTORY=$(jq -cn --arg checkpoint "Another language model worked on this task and produced a context checkpoint.\n\n$long_checkpoint" --arg raw "$long_raw" '[{role:"user",content:$checkpoint},{role:"tool",content:$raw}]')
serialized=$(printf '%s' "$HISTORY" | serialization_prompt)
assert_contains "$serialized" "$long_checkpoint" "OpenAI restart preserves the complete checkpoint"
assert_contains "$serialized" "characters omitted" "OpenAI restart still clips raw history and tool output"
tool_result=$(run_tool shell '{"command":"printf \"shell tool works\""}')
assert_contains "$(printf '%s' "$tool_result" | jq -r '.text')" "shell tool works" "Compatible shell tool execution"
read_result=$(read_file unsupported.pdf)
assert_equal "$(printf '%s' "$read_result" | jq -r '.kind + ":" + .text')" "error:PDF files are not supported by the read tool." "Read tool rejects PDFs"
read_result=$(read_file oversized.png)
assert_equal "$(printf '%s' "$read_result" | jq -r '.kind')" "error" "Read tool rejects images larger than 1 MiB"
assert_contains "$(printf '%s' "$read_result" | jq -r '.text')" "Use the shell tool to resize or compress" "Oversized image error recommends the shell tool"

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
assert_equal "$CONTEXT_TOKENS_KNOWN" "0" "Compaction marks context usage unknown until the next response"

if bash -n "$ROOT/mini-agent.sh"; then ok "Bash syntax"; else not_ok "Bash syntax"; fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
