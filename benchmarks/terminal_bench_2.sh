#!/bin/bash
set -e

# ----------------------------------------------------------------------
# Terminal-Bench 2.0 Runner (Harbor-based)
# Sources config.env for Harbor settings, LiteLLM proxy handles model params via litellm_config.yaml
# ----------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config.env"

# Check if config file exists
if [ ! -f "$CONFIG_FILE" ]; then
  echo "Error: Config file not found at $CONFIG_FILE"
  exit 1
fi

# Source the config file
source "$CONFIG_FILE"

# Model and agent config (used by Harbor)
MODEL_NAME="${TERMINAL_BENCH2_MODEL}"
AGENT_NAME="${TERMINAL_BENCH2_AGENT:-terminus-2}"
CONCURRENT="${TERMINAL_BENCH2_CONCURRENT:-4}"
TASKS="${TERMINAL_BENCH2_TASKS:-all}"
ATTEMPTS="${TERMINAL_BENCH2_ATTEMPTS:-1}"
TIMEOUT_MULTIPLIER="${TERMINAL_BENCH2_TIMEOUT_MULTIPLIER:-1.0}"
MAX_RETRIES="${TERMINAL_BENCH2_MAX_RETRIES:-0}"

# Validate required variables
if [ -z "$MODEL_NAME" ]; then
  echo "Error: TERMINAL_BENCH2_MODEL not set in config.env"
  exit 1
fi

# Results directory (in benchmark_results/terminal_bench_2/)
RESULTS_DIR="${SCRIPT_DIR}/../benchmark_results/terminal_bench_2"
mkdir -p "$RESULTS_DIR"

# Use LiteLLM proxy config if available (from config.env)
OPENAI_API_KEY="${LITELLM_PROXY_KEY:-sk-litellm-proxy-key-123}"
OPENAI_BASE_URL="${MODEL_ENDPOINT:-http://localhost:8001}/v1"
export OPENAI_API_KEY OPENAI_BASE_URL

# Suppress LiteLLM SDK verbose warnings
export LITELLM_LOG="ERROR"

# API Key check (fail if not set)
if [ -z "$OPENAI_API_KEY" ]; then
  echo "Error: OPENAI_API_KEY not set. Please set LITELLM_PROXY_KEY in config.env."
  exit 1
fi

# Harbor install/check
if command -v uv &>/dev/null; then
  uv tool install harbor &>/dev/null || uv tool upgrade harbor &>/dev/null || true
  HARBOR_CMD="uv run harbor run"
else
  pip show harbor &>/dev/null || pip install --quiet --upgrade harbor
  if command -v harbor &>/dev/null; then
    HARBOR_CMD="harbor run"
  else
    echo "Error: 'harbor' CLI not found in PATH after install. Please ensure your environment is correct." >&2
    exit 1
  fi
fi

cd "$RESULTS_DIR"

RUN_CMD="$HARBOR_CMD --dataset terminal-bench@2.0 --agent $AGENT_NAME --model $MODEL_NAME --n-concurrent $CONCURRENT --n-attempts $ATTEMPTS --timeout-multiplier $TIMEOUT_MULTIPLIER --max-retries $MAX_RETRIES"

# Add task-name argument(s) if not 'all'
if [ "$TASKS" != "all" ] && [ -n "$TASKS" ]; then
  for task in $TASKS; do
    RUN_CMD="$RUN_CMD --task-name $task"
  done
fi

echo "═══════════════════════════════════════════════════════════════════════"
echo "  Terminal-Bench 2.0 Evaluation"
echo "═══════════════════════════════════════════════════════════════════════"
echo "  Model:        $MODEL_NAME"
echo "  Agent:        $AGENT_NAME"
echo "  Concurrency:  $CONCURRENT"
echo "  Attempts:     $ATTEMPTS"
echo "  Tasks:        $TASKS"
echo "  Timeout:      ${TIMEOUT_MULTIPLIER}x"
echo "  Max Retries:  $MAX_RETRIES"
echo "  Results:      $RESULTS_DIR"
echo "  API Base:     $OPENAI_BASE_URL"
echo "  Model Params: → litellm_config.yaml (temp, top_p, thinking mode)"
echo "═══════════════════════════════════════════════════════════════════════"
echo ""
echo "→ Starting evaluation (Ctrl+C to stop)..."
echo ""

set +e
script -q /dev/null bash -c "$RUN_CMD" 2>&1 | sed -u '/litellm.ai/d;/Provider List/d;/Failed to retrieve model info/d;/fallback context limit/d;/docs\/providers/d'
RUN_EXIT=${PIPESTATUS[0]}
set -e

echo ""
echo "✓ Evaluation complete"
echo "  Results: $RESULTS_DIR/jobs/"
echo ""
exit $RUN_EXIT
