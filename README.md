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

```python
benchmark_results/
├── tau_bench/
│   └── tau_bench_20241210_193000/
│       ├── evaluation_results.json
│       └── run.log
└── terminal_bench/
    └── terminal_bench_20241210_193000/
        ├── summary.json
        └── session_*/
```

## Requirements

- Python 3.10+ (for τ-Bench)
- Python 3.12+ (for Terminal-Bench)
- Docker (for Terminal-Bench)
- LiteLLM (`pip install litellm`)

## License

MIT
