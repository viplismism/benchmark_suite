#!/bin/bash
# =============================================================================
# Terminal-Bench Evaluation Script
# Production-grade benchmark for evaluating agent coding capabilities
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config.env"

# Load configuration
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

# Configuration
PROXY_ENDPOINT="http://localhost:8001"
TERMINAL_BENCH_RESUME="${TERMINAL_BENCH_RESUME:-}"

# Track the main process PID for cleanup
TB_PID=""

# Cleanup function - kills everything aggressively
cleanup() {
    echo ""
    echo "→ Cleaning up..."
    
    # Kill the tb process and all its children
    if [ -n "$TB_PID" ] && kill -0 "$TB_PID" 2>/dev/null; then
        # Kill entire process group
        pkill -TERM -P "$TB_PID" 2>/dev/null || true
        kill -TERM "$TB_PID" 2>/dev/null || true
        sleep 2
        pkill -KILL -P "$TB_PID" 2>/dev/null || true
        kill -KILL "$TB_PID" 2>/dev/null || true
    fi
    
    # Kill any tb processes
    pkill -KILL -f "tb run" 2>/dev/null || true
    pkill -KILL -f "terminal-bench" 2>/dev/null || true
    
    # Kill Docker containers
    docker ps -q --filter "name=tb-" 2>/dev/null | xargs -r docker kill 2>/dev/null || true
    docker ps -aq --filter "name=tb-" 2>/dev/null | xargs -r docker rm -f 2>/dev/null || true
    
    # Kill containers matching terminal-bench pattern
    docker ps -q 2>/dev/null | while read cid; do
        name=$(docker inspect --format '{{.Name}}' "$cid" 2>/dev/null || true)
        if echo "$name" | grep -qE '[0-9]+-of-[0-9]+-[0-9]{4}-[0-9]{2}-[0-9]{2}'; then
            docker kill "$cid" 2>/dev/null || true
        fi
    done
    
    docker container prune -f 2>/dev/null || true
    
    echo "✓ Cleanup complete"
}

# Handle Ctrl+C and other signals
handle_interrupt() {
    echo ""
    echo "⚠ Interrupted! Stopping benchmark..."
    cleanup
    exit 130
}

trap handle_interrupt INT TERM
trap cleanup EXIT

# Get completed tasks from results
get_completed_tasks() {
    python3 - "$1" << 'EOF'
import json, sys
from pathlib import Path
completed = set()
for f in Path(sys.argv[1]).glob("**/results.json"):
    try:
        for r in json.load(open(f)).get("results", []):
            if r.get("task_id"): completed.add(r["task_id"])
    except: pass
print(" ".join(sorted(completed)))
EOF
}

# Initial cleanup
cleanup >/dev/null 2>&1

# Handle resume mode
if [ -n "$TERMINAL_BENCH_RESUME" ] && [ -d "$TERMINAL_BENCH_RESUME" ]; then
    RESULTS_DIR="$TERMINAL_BENCH_RESUME"
    [ -f "${RESULTS_DIR}/run_config.env" ] && source "${RESULTS_DIR}/run_config.env"
    COMPLETED_TASKS=$(get_completed_tasks "$RESULTS_DIR")
    COMPLETED_COUNT=$(echo $COMPLETED_TASKS | wc -w | tr -d ' ')
    echo "Resuming from $RESULTS_DIR ($COMPLETED_COUNT tasks completed)"
else
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    RESULTS_DIR="${SCRIPT_DIR}/../benchmark_results/terminal_bench/terminal_bench_${TIMESTAMP}"
    mkdir -p "$RESULTS_DIR"
    COMPLETED_TASKS=""
    
    # Save config
    cat > "${RESULTS_DIR}/run_config.env" << EOF
MODEL_NAME="${TERMINAL_BENCH_MODEL:-${TAU_BENCH_AGENT_MODEL:-glm45air-lora}}"
TERMINAL_BENCH_TASKS="${TERMINAL_BENCH_TASKS:-all}"
TERMINAL_BENCH_CONCURRENT="${TERMINAL_BENCH_CONCURRENT:-8}"
TERMINAL_BENCH_AGENT_TIMEOUT="${TERMINAL_BENCH_AGENT_TIMEOUT:-7200}"
TERMINAL_BENCH_TEST_TIMEOUT="${TERMINAL_BENCH_TEST_TIMEOUT:-3600}"
EOF
fi

# Set variables
MODEL_NAME="${MODEL_NAME:-${TERMINAL_BENCH_MODEL:-glm45air-lora}}"
TERMINAL_BENCH_TASKS="${TERMINAL_BENCH_TASKS:-all}"
TERMINAL_BENCH_CONCURRENT="${TERMINAL_BENCH_CONCURRENT:-8}"
TERMINAL_BENCH_AGENT_TIMEOUT="${TERMINAL_BENCH_AGENT_TIMEOUT:-7200}"
TERMINAL_BENCH_TEST_TIMEOUT="${TERMINAL_BENCH_TEST_TIMEOUT:-3600}"

BENCHMARK_DIR="${SCRIPT_DIR}/terminal_bench"

# Print configuration
echo "═══════════════════════════════════════════════════════════════════════"
echo "  Terminal-Bench Evaluation"
echo "═══════════════════════════════════════════════════════════════════════"
echo "  Model:        $MODEL_NAME"
echo "  Tasks:        $TERMINAL_BENCH_TASKS"
echo "  Concurrency:  $TERMINAL_BENCH_CONCURRENT"
echo "  Results:      $RESULTS_DIR"
echo "═══════════════════════════════════════════════════════════════════════"
echo ""

# Check LiteLLM proxy
if ! curl -s "${PROXY_ENDPOINT}/health" >/dev/null 2>&1; then
    echo "Error: LiteLLM proxy not running at ${PROXY_ENDPOINT}"
    exit 1
fi

# Setup repository
[ ! -d "$BENCHMARK_DIR" ] && git clone --quiet https://github.com/laude-institute/terminal-bench.git "$BENCHMARK_DIR"

# Install terminal-bench
if command -v uv &>/dev/null; then
    uv tool install terminal-bench 2>/dev/null || uv tool upgrade terminal-bench 2>/dev/null || true
    TB_CMD="tb"
else
    VENV_DIR="${BENCHMARK_DIR}/venv"
    PYTHON_CMD=$(command -v python3.13 || command -v python3.12)
    [ -z "$PYTHON_CMD" ] && { echo "Error: Python 3.12+ required"; exit 1; }
    [ ! -d "$VENV_DIR" ] && $PYTHON_CMD -m venv "$VENV_DIR"
    source "$VENV_DIR/bin/activate"
    pip install --quiet --upgrade pip terminal-bench
    TB_CMD="tb"
fi

# Check Docker
docker info &>/dev/null || { echo "Error: Docker not running"; exit 1; }

# Setup environment
export OPENAI_API_KEY="${LITELLM_PROXY_KEY}"
export OPENAI_BASE_URL="${PROXY_ENDPOINT}/v1"

cd "$BENCHMARK_DIR"

# Get task list
HARDCODED_TASKS="blind-maze-explorer-5x5 blind-maze-explorer-algorithm blind-maze-explorer-algorithm.easy blind-maze-explorer-algorithm.hard build-initramfs-qemu build-linux-kernel-qemu build-tcc-qemu cartpole-rl-training chess-best-move conda-env-conflict-resolution configure-git-webserver count-dataset-tokens crack-7z-hash crack-7z-hash.easy crack-7z-hash.hard create-bucket cron-broken-network csv-to-parquet decommissioning-service-with-sensitive-data download-youtube eval-mteb eval-mteb.hard extract-moves-from-video extract-safely fibonacci-server fix-git fix-pandas-version fix-permissions get-bitcoin-nodes git-multibranch git-workflow-hack gpt2-codegolf grid-pattern-transform hello-world heterogeneous-dates hf-model-inference incompatible-python-fasttext incompatible-python-fasttext.base_with_hint intrusion-detection jupyter-notebook-server modernize-fortran-build new-encrypt-command nginx-request-logging oom openssl-selfsigned-cert organization-json-generator password-recovery path-tracing path-tracing-reverse play-zork polyglot-c-py polyglot-rust-c processing-pipeline prove-plus-comm pytorch-model-cli pytorch-model-cli.easy pytorch-model-cli.hard qemu-alpine-ssh qemu-startup raman-fitting raman-fitting.easy reshard-c4-data run-pdp11-code sanitize-git-repo sanitize-git-repo.hard security-vulhub-minio simple-sheets-put simple-web-scraper solana-data sqlite-db-truncate sqlite-with-gcov super-benchmark-upet swe-bench-astropy-1 swe-bench-astropy-2 swe-bench-fsspec swe-bench-langcodes tmux-advanced-workflow train-fasttext vim-terminal-task write-compressor"

if [ "$TERMINAL_BENCH_TASKS" = "all" ] || [ "$TERMINAL_BENCH_TASKS" = "ALL" ]; then
    ALL_TASKS="$HARDCODED_TASKS"
else
    # Random N tasks
    ALL_TASKS=$(echo "$HARDCODED_TASKS" | tr ' ' '\n' | sort -R | head -n "$TERMINAL_BENCH_TASKS" | tr '\n' ' ')
fi

# Filter completed tasks
TASKS_TO_RUN=""
for task in $ALL_TASKS; do
    echo "$COMPLETED_TASKS" | grep -qw "$task" || TASKS_TO_RUN="$TASKS_TO_RUN $task"
done
TASKS_TO_RUN=$(echo $TASKS_TO_RUN | xargs)
TOTAL_REMAINING=$(echo $TASKS_TO_RUN | wc -w | tr -d ' ')

echo "→ Tasks to run: $TOTAL_REMAINING"
echo ""

if [ "$TOTAL_REMAINING" -eq 0 ]; then
    echo "All tasks completed!"
else
    SESSION_OUTPUT="${RESULTS_DIR}/session_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$SESSION_OUTPUT"
    
    RUN_CMD="$TB_CMD run --agent terminus --model openai/${MODEL_NAME} \
        --dataset-name terminal-bench-core --dataset-version 0.1.1 \
        --n-concurrent ${TERMINAL_BENCH_CONCURRENT} \
        --global-agent-timeout-sec ${TERMINAL_BENCH_AGENT_TIMEOUT} \
        --global-test-timeout-sec ${TERMINAL_BENCH_TEST_TIMEOUT} \
        --output-path ${SESSION_OUTPUT}"
    
    for task in $TASKS_TO_RUN; do
        RUN_CMD="$RUN_CMD --task-id $task"
    done
    
    echo "→ Starting evaluation (Ctrl+C to stop)..."
    echo ""
    
    set +e
    # Run in background and track PID
    eval $RUN_CMD &
    TB_PID=$!
    
    # Wait for the process, allowing signals to interrupt
    wait $TB_PID
    RUN_EXIT=$?
    TB_PID=""
    set -e
fi

# Generate summary
python3 - "$RESULTS_DIR" "$MODEL_NAME" << 'PYTHON_EOF'
import json, sys
from datetime import datetime
from pathlib import Path

results_dir, model = Path(sys.argv[1]), sys.argv[2]
all_results, seen = [], set()

for f in sorted(results_dir.glob("**/results.json")):
    try:
        for r in json.load(open(f)).get("results", []):
            if r.get("task_id") and r["task_id"] not in seen:
                all_results.append(r)
                seen.add(r["task_id"])
    except: pass

if not all_results:
    print("No results found")
    sys.exit(0)

passed = sum(1 for r in all_results if r.get("is_resolved"))
failed = len(all_results) - passed
total_in = sum(r.get("total_input_tokens", 0) or 0 for r in all_results)
total_out = sum(r.get("total_output_tokens", 0) or 0 for r in all_results)

summary = {
    "benchmark": "terminal-bench",
    "timestamp": datetime.now().isoformat(),
    "model": model,
    "results": {"total": len(all_results), "passed": passed, "failed": failed,
                "accuracy": round(passed / len(all_results) * 100, 2)},
    "token_usage": {"input": total_in, "output": total_out, "total": total_in + total_out}
}

with open(results_dir / "summary.json", "w") as f:
    json.dump(summary, f, indent=2)

print()
print("═" * 70)
print("  TERMINAL-BENCH RESULTS")
print("═" * 70)
print(f"  Model:     {model}")
print(f"  Tasks:     {passed}/{len(all_results)} passed ({summary['results']['accuracy']}%)")
print(f"  Tokens:    {total_in + total_out:,}")
print("═" * 70)
PYTHON_EOF

[ -n "$VIRTUAL_ENV" ] && deactivate

echo ""
echo "✓ Evaluation complete"
echo "  Results: $RESULTS_DIR"
echo ""