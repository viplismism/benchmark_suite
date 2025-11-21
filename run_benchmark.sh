#!/bin/bash

# Unified Benchmark Runner for KAT-coder Models
# Usage: ./run_benchmark.sh <benchmark_name> <model_endpoint> <model_name>

set -e

BENCHMARK=$1
MODEL_ENDPOINT=$2
MODEL_NAME=$3
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_DIR="./benchmark_results/${MODEL_NAME}/${TIMESTAMP}"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Validate arguments
if [ -z "$BENCHMARK" ] || [ -z "$MODEL_ENDPOINT" ] || [ -z "$MODEL_NAME" ]; then
    echo -e "${RED}Usage: ./run_benchmark.sh <benchmark_name> <model_endpoint> <model_name>${NC}"
    echo ""
    echo "Available benchmarks:"
    echo "  swe-bench-verified    - Single attempt agentic coding"
    echo "  livecodebench         - Competitive coding with Elo rating"
    echo "  humaneval             - HumanEval coding evaluation"
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

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Running $BENCHMARK for $MODEL_NAME${NC}"
echo -e "${GREEN}========================================${NC}"
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
        echo -e "${RED}Unknown benchmark: $BENCHMARK${NC}"
        exit 1
        ;;
esac

# Generate summary
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Benchmark Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Results saved to: $RESULTS_DIR"
echo "View results: cat $RESULTS_DIR/results.json"
