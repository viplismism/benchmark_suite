#!/bin/bash

# Unified Benchmark Runner for KAT-coder Models
# Usage: ./run_benchmark.sh <benchmark_name> <model_endpoint> <model_name>

set -e

BENCHMARK=$1
MODEL_ENDPOINT=$2
MODEL_NAME=$3
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_DIR="./benchmark_results/${MODEL_NAME}/${TIMESTAMP}"

# Validate arguments
if [ -z "$BENCHMARK" ] || [ -z "$MODEL_ENDPOINT" ] || [ -z "$MODEL_NAME" ]; then
    echo "Usage: ./run_benchmark.sh <benchmark_name> <model_endpoint> <model_name>"
    echo ""
    echo "Available benchmarks:"
    echo "  swe-bench-verified    - Single attempt agentic coding"
    echo "  livecodebench         - Competitive coding with Elo rating"
    echo "  humaneval             - HumanEval-Rust coding evaluation"
    echo "  humaneval-python      - HumanEval-Python coding evaluation"
    echo "  tau-bench             - Tool calling and agentic capabilities"
    echo "  aime                  - Mathematical reasoning with code"
    echo "  terminal-bench        - Terminal-based agentic coding"
    exit 1
fi

# Create results directory
mkdir -p "$RESULTS_DIR"

# Log configuration
CONFIG_FILE="${RESULTS_DIR}/config.json"
cat > "$CONFIG_FILE" <<EOF
{
  "benchmark": "$BENCHMARK",
  "model_endpoint": "$MODEL_ENDPOINT",
  "model_name": "$MODEL_NAME",
  "timestamp": "$TIMESTAMP",
  "run_date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo "========================================"
echo "Running $BENCHMARK for $MODEL_NAME"
echo "========================================"
echo ""
echo "Model Endpoint: $MODEL_ENDPOINT"
echo "Results Dir: $RESULTS_DIR"
echo ""

# Dispatch to specific benchmark script
case $BENCHMARK in
    swe-bench-verified)
        ./benchmarks/swe_bench_verified.sh "$MODEL_ENDPOINT" "$MODEL_NAME" "$RESULTS_DIR"
        ;;
    livecodebench)
        ./benchmarks/livecodebench.sh "$MODEL_ENDPOINT" "$MODEL_NAME" "$RESULTS_DIR"
        ;;
    humaneval)
        ./benchmarks/humaneval.sh "$MODEL_ENDPOINT" "$MODEL_NAME" "$RESULTS_DIR"
        ;;
    humaneval-python)
        ./benchmarks/humaneval_python.sh "$MODEL_ENDPOINT" "$MODEL_NAME" "$RESULTS_DIR"
        ;;
    tau-bench)
        ./benchmarks/tau_bench.sh "$MODEL_ENDPOINT" "$MODEL_NAME" "$RESULTS_DIR"
        ;;
    aime)
        ./benchmarks/aime.sh "$MODEL_ENDPOINT" "$MODEL_NAME" "$RESULTS_DIR"
        ;;
    terminal-bench)
        ./benchmarks/terminal_bench.sh "$MODEL_ENDPOINT" "$MODEL_NAME" "$RESULTS_DIR"
        ;;
    *)
        echo "Unknown benchmark: $BENCHMARK"
        exit 1
        ;;
esac

# Generate summary
echo ""
echo "========================================"
echo "Benchmark Complete!"
echo "========================================"
echo ""
echo "Results saved to: $RESULTS_DIR"
echo "View results: cat $RESULTS_DIR/results.json"
