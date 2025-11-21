# KAT-Coder Benchmark Suite

Unified evaluation framework for KAT-coder models with standardized interface for running multiple code generation benchmarks.

## Overview

This benchmark suite evaluates your Rust-focused code generation models across multiple dimensions:

- **SWE-Bench Verified** - Single-attempt agentic coding on real GitHub issues (Target: 77.2%)
- **LiveCodeBench** - Competitive programming with Elo rating (Target: 2,439 Elo)
- **HumanEval-Rust** - Basic Rust coding abilities (Baseline: ~25%)
- **τ-Bench (Tau-Bench)** - Tool calling and agentic capabilities (Target: 85.4%)
- **AIME 2025** - Mathematical reasoning with code execution (Target: 95.0%)
- **Terminal-Bench 2.0** - Agentic terminal-based coding (Target: 54.2%)

## Quick Start

### Run Single Benchmark

```bash
chmod +x run_benchmark.sh
./run_benchmark.sh <benchmark_name> <model_endpoint> <model_name>
```

Example:
```bash
./run_benchmark.sh humaneval https://grid.ai.juspay.net claude-sonnet-4-5
```

### Using Makefile (Recommended)

The easiest way to run benchmarks:

```bash
# Test with Claude Sonnet (default)
make humaneval

# Test with specific model
make humaneval MODEL_NAME=qwen3-coder-480b

# Run all benchmarks
make run-all

# Quick benchmarks (HumanEval + τ-Bench)
make run-quick
```

### Run All Benchmarks

```bash
chmod +x run_all_benchmarks.sh
./run_all_benchmarks.sh <model_endpoint> <model_name>
```

Example:
```bash
./run_all_benchmarks.sh https://grid.ai.juspay.net claude-sonnet-4-5
```

## Available Benchmarks

### 1. SWE-Bench Verified
**Priority: HIGH** - Your main evaluation target

Tests ability to solve real GitHub issues in a single attempt.

```bash
./run_benchmark.sh swe-bench-verified https://grid.ai.juspay.net claude-sonnet-4-5
# or using make:
make swe-bench
```

**Expected Runtime:** 4-8 hours (full evaluation)  
**Target Score:** 77.2% (Claude Sonnet 4.5)  
**Current Status:** Starting point for iterative improvement

### 2. LiveCodeBench
**Priority: MEDIUM** - Measures raw coding ability

Competitive programming problems with Elo rating system.

```bash
./run_benchmark.sh livecodebench https://grid.ai.juspay.net claude-sonnet-4-5
# or using make:
make livecodebench
```

**Expected Runtime:** 2-4 hours  
**Target Score:** 2,439 Elo (Gemini 3 Pro)  

### 3. HumanEval-Rust
**Priority: HIGH** - Quick sanity check

Basic Rust programming abilities test.

```bash
./run_benchmark.sh humaneval https://grid.ai.juspay.net claude-sonnet-4-5
# or using make:
make humaneval
```

**Expected Runtime:** 30-60 minutes  
**Baseline Score:** ~25% (typical for code models)  

### 4. τ-Bench (Tool Calling)
**Priority: CRITICAL** - Your identified bottleneck

Tests tool calling and agentic capabilities.

```bash
./run_benchmark.sh tau-bench https://grid.ai.juspay.net claude-sonnet-4-5
# or using make:
make tau-bench
```

**Expected Runtime:** 1-2 hours  
**Target Score:** 85.4% (Gemini 3 Pro)  
**Why Critical:** This is where you identified the main performance gap

### 5. AIME 2025
**Priority: MEDIUM** - Tests reasoning ability

Mathematical reasoning with code execution.

```bash
./run_benchmark.sh aime-2025 https://grid.ai.juspay.net claude-sonnet-4-5
# or using make:
make aime
```

**Expected Runtime:** 1-2 hours  
**Target Score:** 95.0% (Gemini 3 Pro), 87.0% (Claude)  

### 6. Terminal-Bench 2.0
**Priority: MEDIUM** - Agentic coding

Terminal-based agentic coding tasks.

```bash
./run_benchmark.sh terminal-bench https://grid.ai.juspay.net claude-sonnet-4-5
# or using make:
make terminal-bench
```

**Expected Runtime:** 2-3 hours  
**Target Score:** 54.2% (Gemini 3 Pro), 42.8% (Claude)  

## Results Structure

Results are saved in: `./benchmark_results/<model_name>/<timestamp>/`

```
benchmark_results/
├── kat-72b/
│   └── 20250119_143022/
│       ├── swe-bench-verified/
│       │   ├── results.json
│       │   └── metrics.json
│       ├── tau-bench/
│       │   ├── results.json
│       │   └── metrics.json
│       └── aggregate_results.json
```

### Metrics File Format

Each benchmark produces a `metrics.json`:

```json
{
  "benchmark": "swe-bench-verified",
  "model": "kat-72b",
  "total_instances": 500,
  "resolved": 381,
  "resolve_rate": 76.2,
  "target_claude_rate": 77.2
}
```

### Aggregate Results

`aggregate_results.json` combines all benchmark results:

```json
{
  "model": "kat-72b",
  "timestamp": "2025-01-19T14:30:22Z",
  "benchmarks": {
    "swe-bench-verified": { ... },
    "tau-bench": { ... }
  },
  "summary": {
    "total_benchmarks_run": 6,
    "performance_gaps": [ ... ]
  }
}
```

## Model Endpoint Configuration

### Current Setup: Juspay Grid AI

The benchmark suite is configured for Juspay's Grid AI deployment:

```python
from openai import OpenAI

client = OpenAI(
    base_url="https://grid.ai.juspay.net/v1",
    api_key="sk-M_69wbwWPUCfaMRNloo67g"  # Juspay Grid AI key
)
```

### Available Models on Grid AI:
- **claude-sonnet-4-5** (Default) - Latest Claude Sonnet
- **claude-sonnet-4** - Previous Claude version
- **qwen3-coder-480b** - Large Qwen coding model
- **qwen3-30b** - Smaller Qwen model
- **kat-dev-hs-72b** - Your 72B parameter model
- **kat-dev-base-72b** - Base 72B model
- **kat-dev-hs-32b** - Your 32B parameter model
- **kat-dev-base-32b** - Base 32B model

### Test Connection:
```bash
make test  # Tests connection with default model
```

Or manually:
```bash
curl -X POST https://grid.ai.juspay.net/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer sk-M_69wbwWPUCfaMRNloo67g" \
  -d '{"model": "claude-sonnet-4-5", "messages": [{"role": "user", "content": "test"}], "max_tokens": 10}'
```

## Development Workflow

### 1. Quick Iteration (HumanEval-Rust)
For fast feedback during development:
```bash
make humaneval MODEL_NAME=kat-dev-hs-32b
```

### 2. Tool Calling Focus (τ-Bench)
When improving tool calling (your bottleneck):
```bash
make tau-bench MODEL_NAME=kat-dev-hs-72b
```

### 3. Full Evaluation
Before major releases:
```bash
make run-all MODEL_NAME=kat-dev-hs-72b
```

### 4. Compare Your Models Against Claude
```bash
# Test your model
make humaneval MODEL_NAME=kat-dev-hs-72b

# Test against Claude baseline
make humaneval MODEL_NAME=claude-sonnet-4-5

# Compare results
make compare BASELINE=./benchmark_results/claude-sonnet-4-5/latest CURRENT=./benchmark_results/kat-dev-hs-72b/latest
```

## Recommended Evaluation Schedule

### Daily (during active development)
- HumanEval-Rust: Quick sanity check (~30 min)
- τ-Bench: Monitor tool calling improvements (~1-2 hours)

### Weekly
- LiveCodeBench: Track general coding ability (~2-4 hours)
- AIME 2025: Check reasoning capabilities (~1-2 hours)

### Before Release
- Full suite including SWE-Bench Verified (~8-12 hours total)

## Troubleshooting

### Connection Issues
If you get connection errors to Grid AI:
```bash
# Test endpoint
curl -X POST https://your-grid-endpoint.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "kat-72b", "messages": [{"role": "user", "content": "test"}]}'
```

### Memory Issues
For H200 GPUs with 143GB VRAM, you should be fine. If you hit OOM:
- Reduce batch size in evaluation scripts
- Use gradient checkpointing
- Consider model quantization

### Slow Evaluation
To speed up benchmarks:
- Increase `--max_workers` parameter
- Use parallel execution for independent test cases
- Consider sampling strategy for initial testing

## Integration with Training Pipeline

After each training run:

1. **Deploy to Grid AI**
   ```bash
   make deploy MODEL=kat-72b CHECKPOINT=latest
   ```

2. **Run targeted benchmarks**
   ```bash
   ./run_benchmark.sh tau-bench https://grid.hyperswitch.io kat-72b
   ```

3. **Compare results**
   ```bash
   python compare_results.py \
     --baseline benchmark_results/kat-72b/baseline/ \
     --current benchmark_results/kat-72b/latest/
   ```

## Performance Targets

Based on Claude Sonnet 4.5 and Gemini 3 Pro benchmarks:

| Benchmark | Current | Target | Gap |
|-----------|---------|--------|-----|
| SWE-Bench Verified | 60% | 77.2% | 17.2% |
| τ-Bench | TBD | 85.4% | TBD |
| LiveCodeBench | TBD | 2,439 | TBD |
| AIME 2025 | TBD | 95% | TBD |

**Focus Area:** Tool calling (τ-Bench) - identified as primary bottleneck

## Contributing

To add a new benchmark:

1. Create script in `benchmarks/<benchmark_name>.sh`
2. Follow the standard interface (MODEL_ENDPOINT, MODEL_NAME, RESULTS_DIR)
3. Output `results.json` and `metrics.json`
4. Add to `run_benchmark.sh` case statement
5. Update this README

## License

MIT

## Contact

- Team Lead: Vipul Maheshwari
- Manager: Paul Alex
- Team: Avinash Mynampati, Aditya Narayan
