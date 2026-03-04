#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config.env"
[ ! -f "$CONFIG_FILE" ] && echo "Error: Config file not found at $CONFIG_FILE" && exit 1
source "$CONFIG_FILE"

# Config defaults
BIGCODEBENCH_MODEL="${BIGCODEBENCH_MODEL:-${TERMINAL_BENCH_MODEL:-}}"
BIGCODEBENCH_SPLIT="${BIGCODEBENCH_SPLIT:-instruct}"
BIGCODEBENCH_SUBSET="${BIGCODEBENCH_SUBSET:-hard}"
BIGCODEBENCH_LIMIT="${BIGCODEBENCH_LIMIT:-}"   # empty = all, or a number
PROXY_ENDPOINT="${MODEL_ENDPOINT:-http://localhost:8001}"
API_KEY="${LITELLM_PROXY_KEY:-sk-litellm-proxy-key-123}"

[ -z "$BIGCODEBENCH_MODEL" ] && echo "Error: BIGCODEBENCH_MODEL not set in config.env" && exit 1

# Timestamped results directory
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BIGCODEBENCH_RESULTS_DIR="${SCRIPT_DIR}/../benchmark_results/bigcodebench/bigcodebench_${TIMESTAMP}_${BIGCODEBENCH_MODEL}"
mkdir -p "$BIGCODEBENCH_RESULTS_DIR"
BIGCODEBENCH_RESULTS_DIR=$(cd "$BIGCODEBENCH_RESULTS_DIR" && pwd)
BENCHMARK_DIR="${SCRIPT_DIR}/../.cache/bigcodebench"
VENV_DIR="${BENCHMARK_DIR}/venv"

TASK_COUNT="1140"
[ "$BIGCODEBENCH_SUBSET" = "hard" ] && TASK_COUNT="150"

echo "═══════════════════════════════════════════════════════════════════════"
echo "  BigCodeBench Evaluation"
echo "═══════════════════════════════════════════════════════════════════════"
echo "  Model:    $BIGCODEBENCH_MODEL"
echo "  Split:    $BIGCODEBENCH_SPLIT"
echo "  Subset:   $BIGCODEBENCH_SUBSET ($TASK_COUNT tasks)"
echo "  Results:  $BIGCODEBENCH_RESULTS_DIR"
echo "═══════════════════════════════════════════════════════════════════════"
echo ""

# ─── Python & Venv ────────────────────────────────────────────────────────────

find_python() {
    for cmd in python3.11 python3.10 python3.12 python3; do
        if command -v "$cmd" >/dev/null 2>&1; then
            local version=$($cmd -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null)
            local major=$(echo "$version" | cut -d. -f1)
            local minor=$(echo "$version" | cut -d. -f2)
            [ "$major" -ge 3 ] && [ "$minor" -ge 10 ] && echo "$cmd" && return 0
        fi
    done
    return 1
}

PYTHON_CMD=$(find_python) || { echo "Error: Python 3.10+ required"; exit 1; }

if [ ! -d "$BENCHMARK_DIR" ]; then
    mkdir -p "$BENCHMARK_DIR"
fi

if [ ! -d "$VENV_DIR" ]; then
    echo "→ Creating virtual environment..."
    "$PYTHON_CMD" -m venv "$VENV_DIR"
fi
source "$VENV_DIR/bin/activate"

echo "→ Installing dependencies..."
pip install --quiet --upgrade pip

# BigCodeBench requires vllm/torch — only available on Linux with CUDA.
# On macOS, try installing without vllm and hope the openai backend works.
if pip install --quiet bigcodebench 2>/dev/null; then
    echo "  ✓ bigcodebench installed"
else
    echo "  ⚠ Full install failed (likely missing torch/vllm). Trying without GPU deps..."
    pip install --quiet --no-deps bigcodebench 2>/dev/null
    pip install --quiet openai datasets tqdm numpy transformers tree_sitter 'tree-sitter-python>=0.21.0' wget multipledispatch pqdm tempdir termcolor 2>/dev/null
    # Verify the generate command is available
    if ! python -c "from bigcodebench.generate import main" 2>/dev/null; then
        echo "  ✗ BigCodeBench requires PyTorch/vllm which is not available on this platform."
        echo "    Run this benchmark on a Linux machine with CUDA."
        deactivate
        exit 1
    fi
fi

# ─── Phase 1: Code Generation ────────────────────────────────────────────────

echo ""
echo "→ Phase 1: Generating code solutions..."
echo ""

export OPENAI_API_KEY="$API_KEY"

GENERATE_OUTPUT="${BIGCODEBENCH_RESULTS_DIR}/generated_${BIGCODEBENCH_SPLIT}_${BIGCODEBENCH_SUBSET}.jsonl"

GENERATE_CMD="bigcodebench.generate \
    --model $BIGCODEBENCH_MODEL \
    --split $BIGCODEBENCH_SPLIT \
    --subset $BIGCODEBENCH_SUBSET \
    --backend openai \
    --base_url ${PROXY_ENDPOINT}/v1 \
    --temperature 0.0 \
    --n_samples 1 \
    --greedy"

if [ -n "$BIGCODEBENCH_LIMIT" ]; then
    GENERATE_CMD="$GENERATE_CMD --limit $BIGCODEBENCH_LIMIT"
fi

eval $GENERATE_CMD 2>&1 | tee "${BIGCODEBENCH_RESULTS_DIR}/generate.log"

GENERATE_EXIT=${PIPESTATUS[0]}

if [ $GENERATE_EXIT -ne 0 ]; then
    echo "✗ Code generation failed (exit code: $GENERATE_EXIT)"
    deactivate
    exit $GENERATE_EXIT
fi

# Move generated samples to results dir
for f in BigCodeBench*.jsonl bigcodebench*.jsonl; do
    [ -f "$f" ] && mv "$f" "$BIGCODEBENCH_RESULTS_DIR/" 2>/dev/null
done

echo ""
echo "✓ Code generation complete"
echo ""

# ─── Phase 2: Evaluation ─────────────────────────────────────────────────────

echo "→ Phase 2: Evaluating generated code..."
echo ""

# Find the generated samples file
SAMPLES_FILE=$(ls -t "${BIGCODEBENCH_RESULTS_DIR}"/*.jsonl 2>/dev/null | head -1)

if [ -z "$SAMPLES_FILE" ]; then
    # Check current directory too
    SAMPLES_FILE=$(ls -t *.jsonl 2>/dev/null | grep -i bigcodebench | head -1)
    [ -n "$SAMPLES_FILE" ] && mv "$SAMPLES_FILE" "$BIGCODEBENCH_RESULTS_DIR/"
    SAMPLES_FILE=$(ls -t "${BIGCODEBENCH_RESULTS_DIR}"/*.jsonl 2>/dev/null | head -1)
fi

if [ -z "$SAMPLES_FILE" ]; then
    echo "⚠ No generated samples file found, skipping evaluation"
    deactivate
    exit 1
fi

bigcodebench.evaluate \
    --split "$BIGCODEBENCH_SPLIT" \
    --subset "$BIGCODEBENCH_SUBSET" \
    --samples "$SAMPLES_FILE" 2>&1 | tee "${BIGCODEBENCH_RESULTS_DIR}/evaluate.log"

EVAL_EXIT=${PIPESTATUS[0]}

# Move any evaluation result files
for f in eval_results*.json *_eval*.json; do
    [ -f "$f" ] && mv "$f" "$BIGCODEBENCH_RESULTS_DIR/" 2>/dev/null
done

# ─── Results Aggregation ─────────────────────────────────────────────────────

echo ""
echo "→ Aggregating results..."

python3 - "$BIGCODEBENCH_RESULTS_DIR" "$BIGCODEBENCH_MODEL" "$BIGCODEBENCH_SPLIT" "$BIGCODEBENCH_SUBSET" << 'PYTHON_EOF'
import json, sys, glob
from datetime import datetime
from pathlib import Path

results_dir = Path(sys.argv[1])
model = sys.argv[2]
split = sys.argv[3]
subset = sys.argv[4]

# Try to find evaluation results
passed, total = 0, 0
eval_files = list(results_dir.glob("eval_results*.json")) + list(results_dir.glob("*_eval*.json"))

for eval_file in eval_files:
    try:
        with open(eval_file) as f:
            data = json.load(f)
        if isinstance(data, dict):
            # BigCodeBench eval results format
            for task_id, result in data.items():
                total += 1
                if isinstance(result, list):
                    if any(r.get("status") == "pass" or r == "pass" for r in result):
                        passed += 1
                elif isinstance(result, dict):
                    if result.get("status") == "pass" or result.get("passed", False):
                        passed += 1
                elif result == "pass" or result is True:
                    passed += 1
    except:
        pass

# If no eval results found, count from samples
if total == 0:
    samples_files = list(results_dir.glob("*.jsonl"))
    for sf in samples_files:
        try:
            with open(sf) as f:
                for line in f:
                    total += 1
        except:
            pass

accuracy = round(passed / total * 100, 2) if total > 0 else 0.0

summary = {
    "benchmark": "bigcodebench",
    "timestamp": datetime.now().isoformat(),
    "model": model,
    "split": split,
    "subset": subset,
    "results": {
        "total_tasks": total,
        "passed": passed,
        "failed": total - passed,
        "accuracy": accuracy
    }
}

with open(results_dir / "summary.json", "w") as f:
    json.dump(summary, f, indent=2)

print()
print("═" * 70)
print("  BIGCODEBENCH RESULTS")
print("═" * 70)
print(f"  Model:     {model}")
print(f"  Split:     {split} / {subset}")
print(f"  Tasks:     {passed}/{total} passed ({accuracy}%)")
print("═" * 70)
PYTHON_EOF

deactivate

echo ""
[ $EVAL_EXIT -eq 0 ] && echo "✓ BigCodeBench evaluation completed successfully" || echo "⚠ BigCodeBench evaluation completed with warnings"
echo "  Results: $BIGCODEBENCH_RESULTS_DIR"
echo ""

exit ${EVAL_EXIT:-0}
