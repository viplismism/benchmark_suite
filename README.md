# Benchmark Suite

Universal evaluation framework for LLM models. Standardized interface for running code generation, agentic, and reasoning benchmarks through a single `make` command.

## Benchmarks

| Benchmark | What it tests | Tasks | Requirements |
|-----------|--------------|-------|-------------|
| **HumanEval-Rust** | Rust code generation | 161 | Rust toolchain |
| **τ-Bench** | Tool-calling agents | 50-115 | — |
| **Terminal-Bench** | Terminal-based tasks | 89 | Docker |
| **SWE-bench Verified** | Real GitHub bug fixing | 500 | Docker, ~120GB disk |
| **BigCodeBench** | Multi-language code gen | 150-1140 | — |
| **GPQA Diamond** | Graduate-level reasoning | 198 | HuggingFace token |
| **CodeSearchNet** | Code retrieval (NDCG@10) | 573 | QMD, Node.js |

## Quick Start

```bash
# 1. Clone and configure
git clone <repo-url> && cd benchmark_suite
cp config.env.example config.env
cp litellm_config.yaml.example litellm_config.yaml
# Edit both files with your API keys and model configurations

# 2. Install and start LiteLLM proxy
python3 -m venv .venv && .venv/bin/pip install 'litellm[proxy]'
make litellm-start

# 3. Run a single benchmark
make humaneval
make gpqa
make swe-bench
make codesearch    # Code retrieval (no LLM needed)

# 4. Or run all benchmarks
make all

# 5. View results
make results
```

## Example Output

### Running a benchmark

```
═══════════════════════════════════════════════════════════════════════
  GPQA Diamond Evaluation
═══════════════════════════════════════════════════════════════════════
  Model:    claude-haiku
  Subset:   diamond (198 questions)
  Results:  ./benchmark_results/gpqa/gpqa_20260304_152831_claude-haiku
═══════════════════════════════════════════════════════════════════════

→ Installing dependencies...
→ Running GPQA evaluation...
Loading GPQA diamond from HuggingFace...
Loaded 198 questions

[1/198] ✓ predicted=B correct=B
[2/198] ✗ predicted=A correct=C
[3/198] ✓ predicted=D correct=D
...

======================================================================
  GPQA RESULTS
======================================================================
  Model:     claude-haiku
  Subset:    diamond
  Accuracy:  72/198 (36.36%)
  Tokens:    284,190
  Random baseline: 25.0%
======================================================================
```

### HumanEval-Rust

```
═══════════════════════════════════════════════════════════════════════
  HumanEval-Rust Evaluation
═══════════════════════════════════════════════════════════════════════
  Model:    claude-haiku
  Tasks:    161 problems
═══════════════════════════════════════════════════════════════════════

→ Running evaluation...
Loading HumanEval-Rust dataset from HuggingFace...
Loaded 161 problems
[1/161] HumanEval_0_has_close_elements ✓
[2/161] HumanEval_1_separate_paren_groups ✓
[3/161] HumanEval_2_truncate_number ✓
...

══════════════════════════════════════════════════════════════════════
  HUMANEVAL-RUST RESULTS
══════════════════════════════════════════════════════════════════════
  Model:     claude-haiku
  Tasks:     118/161 passed (73.3%)
══════════════════════════════════════════════════════════════════════
```

### SWE-bench Verified

```
═══════════════════════════════════════════════════════════════════════
  SWE-bench Verified Evaluation
═══════════════════════════════════════════════════════════════════════
  Model:        claude-haiku
  Dataset:      princeton-nlp/SWE-bench_Verified
  Agent:        simple
  Max Workers:  4
  Instances:    all (500)
═══════════════════════════════════════════════════════════════════════

→ Checking prerequisites...
  ✓ Docker is running (socket: unix:///Users/dev/.orbstack/run/docker.sock)
  ✓ ARM architecture detected — will use --namespace ''

→ Phase 1: Inference (generating patches)...
[1/500] astropy__astropy-12907
  ✓ Patch generated (1284 chars)
[2/500] django__django-11099
  ✓ Patch generated (856 chars)
...

→ Phase 2: Evaluation (running tests in Docker)...
...

══════════════════════════════════════════════════════════════════════
  SWE-BENCH VERIFIED RESULTS
══════════════════════════════════════════════════════════════════════
  Model:       claude-haiku
  Instances:   500
  Resolved:    23/500 (4.6%)
══════════════════════════════════════════════════════════════════════
```

### Viewing results across runs

```
$ make results
═══════════════════════════════════════════════════════════════════════
  Benchmark Results
═══════════════════════════════════════════════════════════════════════

  Benchmark              Model                        Score            Date
  ────────────────────── ──────────────────────────── ──────────────── ───────────────────
  gpqa                   claude-haiku                 72/198 (36.36%) 2026-03-04T15:28:31
  humaneval-rust         claude-haiku                 118/161 (73.3%) 2026-03-04T15:15:02
  swe-bench-verified     claude-haiku                 23/500 (4.6%)   2026-03-04T15:38:52

═══════════════════════════════════════════════════════════════════════
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
make humaneval               # Run HumanEval-Rust evaluation
make tau-bench               # Run τ-Bench evaluation
make terminal-bench          # Run Terminal-Bench evaluation
make terminal-bench-2        # Run Terminal-Bench 2.0 evaluation
make swe-bench               # Run SWE-bench Verified evaluation
make bigcodebench            # Run BigCodeBench evaluation
make gpqa                    # Run GPQA Diamond evaluation
make codesearch              # Run CodeSearchNet retrieval evaluation

# Suite
make all                     # Run all benchmarks sequentially
make results                 # Show results from all runs

# Utilities
make swe-bench-clean         # Remove SWE-bench Docker images
make clean                   # Clean up Docker containers
make docker-clean            # Remove ALL Docker resources
```

## Configuration

### config.env

All benchmarks read from a single `config.env` file. See `config.env.example` for the full template.

```bash
# LiteLLM Proxy
MODEL_ENDPOINT="http://localhost:8001"
LITELLM_PROXY_KEY="your-key"

# Each benchmark has its own MODEL variable
HUMANEVAL_MODEL="your-model"
TAU_BENCH_AGENT_MODEL="your-model"
TERMINAL_BENCH_MODEL="your-model"
SWE_BENCH_MODEL="your-model"
BIGCODEBENCH_MODEL="your-model"
GPQA_MODEL="your-model"
```

### CodeSearchNet (non-LLM benchmark)

Unlike other benchmarks, CodeSearchNet evaluates a **local retrieval tool** (QMD), not an LLM:

```bash
CODESEARCH_QMD_DIR="/path/to/qmd"     # QMD repo root
CODESEARCH_LANGUAGE="all"             # or a specific language
```

### litellm_config.yaml

Routes all benchmark API calls through a single proxy. Configure your models and backends:

```yaml
model_list:
  - model_name: your-model-name
    litellm_params:
      model: openai/your-model       # or anthropic/claude-..., etc.
      api_base: http://your-server/v1
      api_key: your-api-key

general_settings:
  master_key: sk-litellm-proxy-key-123
```

## Results

All results are saved in `benchmark_results/` with timestamped directories:

```
benchmark_results/
├── humaneval/
│   └── humaneval_YYYYMMDD_HHMMSS_MODEL/
│       ├── summary.json
│       ├── results.json
│       └── run.log
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
├── codesearch/
│   └── codesearch_YYYYMMDD_HHMMSS/
│       ├── summary.json
│       ├── detailed_results.json
│       └── run.log
```

Use `make results` to view a summary table across all runs.

## Project Structure

```
benchmark_suite/
├── benchmarks/          # Benchmark scripts only
│   ├── humaneval.sh
│   ├── gpqa.sh
│   ├── bigcodebench.sh
│   ├── swe_bench.sh
│   ├── tau_bench.sh
│   ├── terminal_bench.sh
│   └── terminal_bench_2.sh
├── config.env.example   # Configuration template
├── litellm_config.yaml.example
├── Makefile             # All commands
├── benchmark_results/   # Output (created on run)
└── .cache/              # Venvs & cloned repos (created on run)
```

## Requirements

- Python 3.10+ (HumanEval, τ-Bench, SWE-bench, BigCodeBench, GPQA)
- Python 3.12+ (Terminal-Bench)
- Rust toolchain (HumanEval — auto-installed if missing)
- Docker (Terminal-Bench, SWE-bench)
- LiteLLM (`pip install 'litellm[proxy]'`)
- HuggingFace token (GPQA — gated dataset)
- ~120GB+ free disk space (SWE-bench Docker images)

## License

MIT
