.PHONY: help setup run-all run-quick clean compare test

# Default configuration for testing with Claude Sonnet
MODEL_NAME ?= claude-sonnet-4-5
MODEL_ENDPOINT ?= https://grid.ai.juspay.net
BASELINE_DIR ?= 
CURRENT_DIR ?=

help:
	@echo "KAT-Coder Benchmark Suite"
	@echo "========================="
	@echo ""
	@echo "Usage:"
	@echo "  make setup                               - Install dependencies and setup environment"
	@echo "  make run-all [MODEL_NAME=<model>]        - Run all benchmarks (default: claude-sonnet-4-5)"
	@echo "  make run-quick [MODEL_NAME=<model>]      - Run quick benchmarks (HumanEval, τ-Bench)"
	@echo "  make swe-bench [MODEL_NAME=<model>]      - Run SWE-Bench Verified only (fast version)"
	@echo "  make swe-bench-full                      - Run full SWE-Bench setup + evaluation (comprehensive)"
	@echo "  make tau-bench [MODEL_NAME=<model>]      - Run τ-Bench only"
	@echo "  make humaneval [MODEL_NAME=<model>]      - Run HumanEval-Rust only"
	@echo "  make compare BASELINE=<dir> CURRENT=<dir> - Compare two result sets"
	@echo "  make clean                          - Clean up results and temporary files"
	@echo "  make test                           - Test model endpoint connection"
	@echo ""
	@echo "Configuration:"
	@echo "  MODEL_NAME: Name of model to evaluate (default: claude-sonnet-4-5)"
	@echo "  MODEL_ENDPOINT: Grid AI endpoint URL (default: https://grid.ai.juspay.net)"
	@echo ""
	@echo "Available Models:"
	@echo "  claude-sonnet-4-5, claude-sonnet-4, qwen3-coder-480b, qwen3-30b"
	@echo "  kat-dev-hs-72b, kat-dev-base-72b, kat-dev-hs-32b, kat-dev-base-32b"
	@echo ""
	@echo "Examples:"
	@echo "  make run-quick                                      # Test with Claude Sonnet"
	@echo "  make run-all MODEL_NAME=qwen3-coder-480b           # Test with Qwen3 Coder"
	@echo "  make humaneval MODEL_NAME=kat-dev-hs-72b           # Test with KAT model"
	@echo "  make compare BASELINE=results/baseline CURRENT=results/latest"

setup:
	@echo "Setting up benchmark environment..."
	@chmod +x run_benchmark.sh
	@chmod +x run_all_benchmarks.sh
	@chmod +x benchmarks/*.sh
	@chmod +x compare_results.py
	@echo "Creating directories..."
	@mkdir -p benchmark_results
	@mkdir -p benchmarks
	@echo "Setup complete!"

run-all: setup
	@echo "Running all benchmarks for $(MODEL_NAME)..."
	./run_all_benchmarks.sh $(MODEL_ENDPOINT) $(MODEL_NAME)

run-quick: setup
	@echo "Running quick benchmarks for $(MODEL_NAME)..."
	./run_benchmark.sh humaneval-rust $(MODEL_ENDPOINT) $(MODEL_NAME)
	./run_benchmark.sh tau-bench $(MODEL_ENDPOINT) $(MODEL_NAME)

swe-bench: setup
	@echo "Running SWE-Bench Verified for $(MODEL_NAME)..."
	./run_benchmark.sh swe-bench-verified $(MODEL_ENDPOINT) $(MODEL_NAME)

swe-bench-full: setup
	@echo "Running SWE-Bench with full setup and evaluation..."
	@chmod +x setup_swebench.py
	@echo "This will run the comprehensive SWE-Bench setup script"
	@echo "It includes Docker image building and full evaluation"
	python3 setup_swebench.py

tau-bench: setup
	@echo "Running τ-Bench for $(MODEL_NAME)..."
	./run_benchmark.sh tau-bench $(MODEL_ENDPOINT) $(MODEL_NAME)

humaneval: setup
	@echo "Running HumanEval for $(MODEL_NAME)..."
	./run_benchmark.sh humaneval $(MODEL_ENDPOINT) $(MODEL_NAME)

livecodebench: setup
	@echo "Running LiveCodeBench for $(MODEL_NAME)..."
	./run_benchmark.sh livecodebench $(MODEL_ENDPOINT) $(MODEL_NAME)

aime: setup
	@echo "Running AIME 2025 for $(MODEL_NAME)..."
	./run_benchmark.sh aime $(MODEL_ENDPOINT) $(MODEL_NAME)

terminal-bench: setup
	@echo "Running Terminal-Bench 2.0 for $(MODEL_NAME)..."
	./run_benchmark.sh terminal-bench $(MODEL_ENDPOINT) $(MODEL_NAME)

compare:
	@if [ -z "$(BASELINE)" ] || [ -z "$(CURRENT)" ]; then \
		echo "Error: Must specify BASELINE and CURRENT directories"; \
		echo "Usage: make compare BASELINE=<dir> CURRENT=<dir>"; \
		exit 1; \
	fi
	@echo "Comparing results..."
	./compare_results.py $(BASELINE) $(CURRENT)

test:
	@echo "Testing connection to $(MODEL_ENDPOINT) with model $(MODEL_NAME)..."
	@curl -X POST $(MODEL_ENDPOINT)/v1/chat/completions \
		-H "Content-Type: application/json" \
		-H "Authorization: Bearer sk-M_69wbwWPUCfaMRNloo67g" \
		-d '{"model": "$(MODEL_NAME)", "messages": [{"role": "user", "content": "test"}], "max_tokens": 10}' \
		|| echo "Connection test failed!"

clean:
	@echo "Cleaning up..."
	@rm -rf swe_bench_verified/
	@rm -rf livecodebench/
	@rm -rf humaneval_rust/
	@rm -rf tau_bench/
	@rm -rf aime_2025/
	@rm -rf terminal_bench/
	@echo "Cleaned benchmark repositories (results preserved)"

clean-all: clean
	@echo "Removing all results..."
	@rm -rf benchmark_results/
	@echo "All clean!"

# Development targets
dev-test: setup
	@echo "Running development tests..."
	@echo "1. Testing HumanEval-Rust (quick sanity check)..."
	./run_benchmark.sh humaneval-rust $(MODEL_ENDPOINT) $(MODEL_NAME)

# Find latest results directory
latest:
	@find benchmark_results/$(MODEL_NAME) -type d -maxdepth 1 | sort -r | head -1

# Show latest results
show-latest:
	@echo "Latest results for $(MODEL_NAME):"
	@LATEST=$$(make latest); \
	if [ -f "$$LATEST/aggregate_results.json" ]; then \
		cat "$$LATEST/aggregate_results.json" | python -m json.tool; \
	else \
		echo "No results found"; \
	fi

# List all result directories
list-results:
	@echo "Available results for $(MODEL_NAME):"
	@find benchmark_results/$(MODEL_NAME) -type d -maxdepth 1 -mindepth 1 | sort -r

# Create a report
report:
	@LATEST=$$(make latest); \
	echo "Generating report from $$LATEST..."; \
	python3 -c "import json; data = json.load(open('$$LATEST/aggregate_results.json')); print('\n=== BENCHMARK REPORT ==='); print(f\"Model: {data['model']}\"); print(f\"Timestamp: {data['timestamp']}\"); print('\nResults:'); [print(f\"  {k}: {v.get('resolve_rate', v.get('accuracy', v.get('pass_rate', 'N/A')))}%\") for k,v in data['benchmarks'].items()]"
