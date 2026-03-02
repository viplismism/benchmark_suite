# Benchmark Suite

Universal evaluation framework for LLM models with standardized interface for running code generation and agentic benchmarks.

## Quick Start

```bash
# 1. Setup
cp config.env.example config.env
cp litellm_config.yaml.example litellm_config.yaml
# Edit both files with your API keys and model configurations

# 2. Start LiteLLM proxy
make litellm

# 3. Run benchmarks (in another terminal)
make tau-bench
make terminal-bench
make swe-bench
make bigcodebench
make gpqa
```

## Available Commands

```bash
make help                    # Show all commands

# LiteLLM Proxy
make litellm                 # Start proxy (foreground)
make litellm-start           # Start proxy (background)
make litellm-stop            # Stop proxy
make litellm-status          # Check status

# Benchmarks
make tau-bench               # Run τ-Bench evaluation
make terminal-bench          # Run Terminal-Bench evaluation
make terminal-bench-resume CHECKPOINT=<path>
make terminal-bench-list     # List checkpoints
make swe-bench               # Run SWE-bench Verified evaluation
make swe-bench-clean         # Remove SWE-bench Docker images
make bigcodebench            # Run BigCodeBench evaluation
make gpqa                    # Run GPQA Diamond evaluation
```

## Configuration

### config.env

```bash
# LiteLLM Proxy
MODEL_ENDPOINT="http://localhost:8001"
LITELLM_PROXY_KEY="your-key"

# τ-Bench
TAU_BENCH_DOMAIN="retail"           # retail or airline
TAU_BENCH_TASKS="all"               # "all" or "0 1 2 3 4"
TAU_BENCH_AGENT_MODEL="your-model"  # Model to evaluate
TAU_BENCH_USER_MODEL="gpt-4o"       # User simulator model

# Terminal-Bench
TERMINAL_BENCH_MODEL="your-model"
TERMINAL_BENCH_TASKS="all"
TERMINAL_BENCH_CONCURRENT="8"

# SWE-bench Verified
SWE_BENCH_MODEL="your-model"
SWE_BENCH_MAX_WORKERS="4"
SWE_BENCH_INSTANCE_LIMIT=""         # empty = all 500

# BigCodeBench
BIGCODEBENCH_MODEL="your-model"
BIGCODEBENCH_SPLIT="instruct"       # "complete" or "instruct"
BIGCODEBENCH_SUBSET="hard"          # "full" (1140) or "hard" (150)

# GPQA
GPQA_MODEL="your-model"
GPQA_SUBSET="diamond"               # "diamond", "main", or "extended"
HF_TOKEN="your-hf-token"            # required for GPQA (gated dataset)
```

### litellm_config.yaml

Configure your models and backends:

```yaml
model_list:
  - model_name: your-model-name
    litellm_params:
      model: openai/your-model
      api_base: http://your-server:8001/v1
      api_key: your-api-key

general_settings:
  master_key: sk-litellm-proxy-key-123
```

Results are saved in `benchmark_results/`:

```
benchmark_results/
├── tau_bench/
│   └── tau_bench_YYYYMMDD_HHMMSS_MODEL/
│       ├── evaluation_results.json
│       └── run.log
├── terminal_bench/
│   └── terminal_bench_YYYYMMDD_HHMMSS_MODEL/
│       ├── summary.json
│       └── session_*/
├── swe_bench/
│   └── swe_bench_YYYYMMDD_HHMMSS_MODEL/
│       ├── predictions.jsonl
│       ├── summary.json
│       └── run.log
├── bigcodebench/
│   └── bigcodebench_YYYYMMDD_HHMMSS_MODEL/
│       └── summary.json
└── gpqa/
    └── gpqa_YYYYMMDD_HHMMSS_MODEL/
        └── summary.json
```

## Requirements

- Python 3.10+ (for τ-Bench, SWE-bench, BigCodeBench, GPQA)
- Python 3.12+ (for Terminal-Bench)
- Docker (for Terminal-Bench, SWE-bench)
- LiteLLM (`pip install litellm`)
- HuggingFace token (for GPQA — gated dataset)
- ~120GB+ free disk space (for SWE-bench Docker images)

## License

MIT
