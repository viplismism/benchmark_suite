#!/bin/bash

# Run All Benchmarks - Unified Runner
# Executes all benchmarks in sequence and aggregates results

set -e

MODEL_ENDPOINT=$1
MODEL_NAME=$2

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Validate arguments
if [ -z "$MODEL_ENDPOINT" ] || [ -z "$MODEL_NAME" ]; then
    echo -e "${RED}Usage: ./run_all_benchmarks.sh <model_endpoint> <model_name>${NC}"
    exit 1
fi

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_ROOT="./benchmark_results/${MODEL_NAME}/${TIMESTAMP}"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}KAT-Coder Benchmark Suite${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo "Model: $MODEL_NAME"
echo "Endpoint: $MODEL_ENDPOINT"
echo "Results directory: $RESULTS_ROOT"
echo ""

# List of benchmarks to run
BENCHMARKS=(
    "humaneval-rust"
    "tau-bench"
    "livecodebench"
    "aime-2025"
    "terminal-bench"
    "swe-bench-verified"
)

# Track which benchmarks succeeded/failed
declare -A BENCHMARK_STATUS

# Make benchmark scripts executable
chmod +x ./benchmarks/*.sh
chmod +x ./run_benchmark.sh

# Run each benchmark
for benchmark in "${BENCHMARKS[@]}"; do
    echo ""
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}Running: $benchmark${NC}"
    echo -e "${YELLOW}========================================${NC}"
    echo ""
    
    START_TIME=$(date +%s)
    
    if ./run_benchmark.sh "$benchmark" "$MODEL_ENDPOINT" "$MODEL_NAME"; then
        END_TIME=$(date +%s)
        DURATION=$((END_TIME - START_TIME))
        BENCHMARK_STATUS[$benchmark]="✓ SUCCESS (${DURATION}s)"
        echo -e "${GREEN}$benchmark completed successfully!${NC}"
    else
        END_TIME=$(date +%s)
        DURATION=$((END_TIME - START_TIME))
        BENCHMARK_STATUS[$benchmark]="✗ FAILED (${DURATION}s)"
        echo -e "${RED}$benchmark failed!${NC}"
    fi
    
    echo ""
    echo "Waiting 10 seconds before next benchmark..."
    sleep 10
done

# Aggregate results
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Aggregating Results${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

AGGREGATE_FILE="${RESULTS_ROOT}/aggregate_results.json"
mkdir -p "$(dirname "$AGGREGATE_FILE")"

# Create Python script to aggregate results
cat > /tmp/aggregate_results.py <<'PYTHON'
import json
import os
import glob
from datetime import datetime

model_name = os.environ.get("MODEL_NAME")
results_root = os.environ.get("RESULTS_ROOT")

# Find all metrics.json files
metrics_files = glob.glob(f"{results_root}/**/metrics.json", recursive=True)

aggregate = {
    "model": model_name,
    "timestamp": datetime.utcnow().isoformat(),
    "benchmarks": {}
}

for metrics_file in metrics_files:
    with open(metrics_file, 'r') as f:
        metrics = json.load(f)
        benchmark = metrics.get("benchmark")
        if benchmark:
            aggregate["benchmarks"][benchmark] = metrics

# Calculate summary statistics
total_benchmarks = len(aggregate["benchmarks"])
aggregate["summary"] = {
    "total_benchmarks_run": total_benchmarks,
    "benchmarks_list": list(aggregate["benchmarks"].keys())
}

# Add comparison to targets
comparisons = []
for benchmark, data in aggregate["benchmarks"].items():
    if "target_claude_rate" in data:
        target = data["target_claude_rate"]
        actual = data.get("resolve_rate", data.get("accuracy", data.get("pass_rate", 0)))
        gap = target - actual
        comparisons.append({
            "benchmark": benchmark,
            "target": target,
            "actual": actual,
            "gap": gap
        })

if comparisons:
    aggregate["summary"]["performance_gaps"] = comparisons

# Save aggregate results
output_file = os.path.join(results_root, "aggregate_results.json")
with open(output_file, 'w') as f:
    json.dump(aggregate, f, indent=2)

print(f"Aggregate results saved to: {output_file}")

# Print summary table
print("\n" + "="*80)
print("BENCHMARK RESULTS SUMMARY")
print("="*80)
print(f"{'Benchmark':<25} {'Score':<15} {'Target':<15} {'Gap':<15}")
print("-"*80)

for benchmark, data in sorted(aggregate["benchmarks"].items()):
    score_key = None
    for key in ['resolve_rate', 'accuracy', 'pass_rate', 'success_rate']:
        if key in data:
            score_key = key
            break
    
    if score_key:
        score = data[score_key]
        target = data.get("target_gemini_3", data.get("target_claude_rate", data.get("target_claude", "N/A")))
        
        if isinstance(target, (int, float)):
            gap = target - score
            print(f"{benchmark:<25} {score:<15.1f} {target:<15.1f} {gap:<15.1f}")
        else:
            print(f"{benchmark:<25} {score:<15.1f} {target:<15} {'N/A':<15}")

print("="*80)
PYTHON

export MODEL_NAME="$MODEL_NAME"
export RESULTS_ROOT="$RESULTS_ROOT"

python3 /tmp/aggregate_results.py

# Print final summary
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Final Summary${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

for benchmark in "${BENCHMARKS[@]}"; do
    status="${BENCHMARK_STATUS[$benchmark]}"
    if [[ $status == *"SUCCESS"* ]]; then
        echo -e "${GREEN}${benchmark}: ${status}${NC}"
    else
        echo -e "${RED}${benchmark}: ${status}${NC}"
    fi
done

echo ""
echo -e "${GREEN}All benchmarks complete!${NC}"
echo "Results directory: $RESULTS_ROOT"
echo "Aggregate results: ${RESULTS_ROOT}/aggregate_results.json"
