#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config.env"
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

# ─── Config (with defaults) ──────────────────────────────────────────────────

# Path to the QMD repo root (must contain src/cli/qmd.ts)
QMD_DIR="${CODESEARCH_QMD_DIR:-}"
# Node binary (arm64 for Apple Silicon)
NODE_BIN="${CODESEARCH_NODE_BIN:-$(command -v node 2>/dev/null || echo "")}"
# Language filter: "all" or a specific language (Go, Java, JavaScript, PHP, Python, Ruby)
CODESEARCH_LANGUAGE="${CODESEARCH_LANGUAGE:-all}"
# Number of results per query
CODESEARCH_TOP_K="${CODESEARCH_TOP_K:-10}"
# Skip download of CSN files (reuse existing)
CODESEARCH_SKIP_DOWNLOAD="${CODESEARCH_SKIP_DOWNLOAD:-false}"
# Skip indexing (reuse existing QMD collections)
CODESEARCH_SKIP_INDEX="${CODESEARCH_SKIP_INDEX:-false}"

# ─── Validate ────────────────────────────────────────────────────────────────

if [ -z "$QMD_DIR" ]; then
    echo "Error: CODESEARCH_QMD_DIR not set."
    echo "  Set it in config.env or export it:"
    echo "    export CODESEARCH_QMD_DIR=/path/to/qmd"
    exit 1
fi

if [ ! -f "$QMD_DIR/src/cli/qmd.ts" ]; then
    echo "Error: QMD entry point not found at $QMD_DIR/src/cli/qmd.ts"
    echo "  Make sure CODESEARCH_QMD_DIR points to the qmd repo root."
    exit 1
fi

if [ -z "$NODE_BIN" ]; then
    echo "Error: Node.js not found. Set CODESEARCH_NODE_BIN in config.env"
    exit 1
fi

# ─── Setup ───────────────────────────────────────────────────────────────────

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_DIR="${SCRIPT_DIR}/../benchmark_results/codesearch/codesearch_${TIMESTAMP}"
mkdir -p "$RESULTS_DIR"
RESULTS_DIR=$(cd "$RESULTS_DIR" && pwd)

BENCHMARK_DIR="${SCRIPT_DIR}/../.cache/codesearch"
mkdir -p "$BENCHMARK_DIR"

# Query count by language
if [ "$CODESEARCH_LANGUAGE" = "all" ]; then
    QUERY_COUNT="573 (6 languages)"
else
    QUERY_COUNT="~99 ($CODESEARCH_LANGUAGE only)"
fi

echo "═══════════════════════════════════════════════════════════════════════"
echo "  CodeSearchNet Evaluation — Code Retrieval Benchmark"
echo "═══════════════════════════════════════════════════════════════════════"
echo "  Tool:       QMD ($(basename "$QMD_DIR"))"
echo "  Queries:    $QUERY_COUNT"
echo "  Top-k:      $CODESEARCH_TOP_K"
echo "  Target:     RANGER NDCG@10 = 0.786"
echo "  Results:    $RESULTS_DIR"
echo "═══════════════════════════════════════════════════════════════════════"
echo ""

# ─── Python & Venv ───────────────────────────────────────────────────────────

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

# Copy eval scripts to cache dir
cp "${SCRIPT_DIR}/codesearch/metrics.py" "${BENCHMARK_DIR}/metrics.py"
cp "${SCRIPT_DIR}/codesearch/run_csn_eval.py" "${BENCHMARK_DIR}/run_csn_eval.py"

# ─── Run Evaluation ──────────────────────────────────────────────────────────

echo "→ Running CodeSearchNet evaluation..."
echo ""

EVAL_ARGS="--top-k $CODESEARCH_TOP_K --verbose"
[ "$CODESEARCH_LANGUAGE" != "all" ] && EVAL_ARGS="$EVAL_ARGS --language $CODESEARCH_LANGUAGE"
[ "$CODESEARCH_SKIP_DOWNLOAD" = "true" ] && EVAL_ARGS="$EVAL_ARGS --skip-download"
[ "$CODESEARCH_SKIP_INDEX" = "true" ] && EVAL_ARGS="$EVAL_ARGS --skip-index"

# Pass QMD config via environment
export CODESEARCH_QMD_DIR="$QMD_DIR"
export CODESEARCH_NODE_BIN="$NODE_BIN"
export CODESEARCH_RESULTS_DIR="$RESULTS_DIR"
export CODESEARCH_CACHE_DIR="$BENCHMARK_DIR"

"$PYTHON_CMD" -u "${BENCHMARK_DIR}/run_csn_eval.py" $EVAL_ARGS 2>&1 | tee "${RESULTS_DIR}/run.log"
EXIT_CODE=${PIPESTATUS[0]}

echo ""
[ $EXIT_CODE -eq 0 ] && echo "✓ CodeSearchNet evaluation completed successfully" || echo "✗ CodeSearchNet evaluation failed (exit code: $EXIT_CODE)"
echo "  Results: $RESULTS_DIR"
echo ""

exit $EXIT_CODE
