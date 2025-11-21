# Quick Start Guide

## 🚀 Get Started in 5 Minutes

### 1. Setup (One-time)

```bash
# Clone or copy this benchmark suite
cd benchmark-suite

# Make scripts executable and setup directories
make setup
```

### 2. Test Your Model Connection

```bash
# Verify your Grid AI endpoint is working
make test MODEL_NAME=kat-72b MODEL_ENDPOINT=https://grid.hyperswitch.io
```

### 3. Run Your First Benchmark

Start with the fastest benchmark (30 minutes):

```bash
make humaneval MODEL_NAME=kat-72b
```

### 4. Run Quick Evaluation Suite

For rapid iteration (2-3 hours):

```bash
make run-quick MODEL_NAME=kat-72b
```

This runs:
- HumanEval-Rust (basic coding sanity check)
- τ-Bench (your tool calling bottleneck)

### 5. Full Evaluation

When ready for comprehensive testing (8-12 hours):

```bash
make run-all MODEL_NAME=kat-72b
```

## 📊 Viewing Results

### Latest Results
```bash
make show-latest MODEL_NAME=kat-72b
```

### Compare Two Runs
```bash
# Find available results
make list-results MODEL_NAME=kat-72b

# Compare baseline vs latest
make compare \
  BASELINE=benchmark_results/kat-72b/20250119_100000 \
  CURRENT=benchmark_results/kat-72b/20250119_150000
```

### Generate Report
```bash
make report MODEL_NAME=kat-72b
```

## 🎯 Recommended Workflow

### Daily Development Cycle

**Morning** (30 min):
```bash
make humaneval MODEL_NAME=kat-72b
```
→ Quick sanity check that nothing broke

**Afternoon** (2 hours):
```bash
make tau-bench MODEL_NAME=kat-72b
```
→ Focus on your bottleneck: tool calling

### Weekly Checkpoint

**Monday** (4 hours):
```bash
make run-quick MODEL_NAME=kat-72b
```
→ Track progress on core capabilities

### Before Release

**Full evaluation** (8-12 hours):
```bash
make run-all MODEL_NAME=kat-72b
```
→ Comprehensive benchmark across all dimensions

## 🔧 Troubleshooting

### Connection Errors

```bash
# Test endpoint
curl -X POST https://grid.hyperswitch.io/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "kat-72b", "messages": [{"role": "user", "content": "test"}]}'
```

### Benchmark Hangs

If a benchmark seems stuck:
1. Check Grid AI logs for errors
2. Verify model is responding (test endpoint above)
3. Kill and restart: `Ctrl+C` then rerun

### Out of Memory

For H200 GPUs, you should be fine, but if needed:
```bash
# Edit benchmark script and reduce batch size
vim benchmarks/swe_bench_verified.sh
# Find and reduce: MAX_WORKERS=4 → MAX_WORKERS=2
```

## 📈 Performance Tracking

### Your Current Status
Based on your 60% SWE-Bench performance vs Claude's 77.2%:

**Priority Order:**
1. **τ-Bench** - Fix tool calling (your identified bottleneck)
2. **HumanEval-Rust** - Maintain basic coding quality
3. **SWE-Bench** - Track overall agentic performance
4. **Others** - Track after fixing core issues

### Target Progression

**Week 1-2:** Focus on tool calling
- Run `make tau-bench` daily
- Target: Move from baseline to 60%+

**Week 3-4:** Integrate improvements
- Run `make run-quick` 2x per week
- Target: 70%+ on tool calling, stable HumanEval

**Week 5-6:** Full validation
- Run `make run-all` weekly
- Target: Close gap to 70-75% on SWE-Bench

## 🔄 Integration with Training

After each training run:

```bash
# 1. Deploy new model to Grid AI
make test MODEL_NAME=kat-72b-v2

# 2. Run focused benchmark
make tau-bench MODEL_NAME=kat-72b-v2

# 3. Compare with previous
make compare \
  BASELINE=benchmark_results/kat-72b-v1/latest \
  CURRENT=benchmark_results/kat-72b-v2/latest

# 4. If better, run full suite
if improvement_detected; then
  make run-all MODEL_NAME=kat-72b-v2
fi
```

## 💡 Pro Tips

1. **Start Small**: Always test with HumanEval before longer benchmarks
2. **Focus on Gaps**: Run τ-Bench frequently since it's your bottleneck
3. **Track Progress**: Use `make compare` to see improvements
4. **Batch Evaluation**: Run overnight for full suite
5. **Save Prompts**: Keep track of what works in prompt engineering

## 🎓 Understanding Scores

### Good Performance
- HumanEval-Rust: 30%+ (baseline is ~25%)
- τ-Bench: 60%+ (target 85%)
- SWE-Bench: 60%+ (target 77%)

### Great Performance
- HumanEval-Rust: 40%+
- τ-Bench: 75%+
- SWE-Bench: 70%+

### Claude-Level Performance
- All benchmarks: Within 5% of targets shown in image

## 📞 Need Help?

**Team:**
- Lead: Vipul Maheshwari
- Manager: Paul Alex (saheb)
- Team: Avinash Mynampati, Aditya Narayan

**Common Issues:**
1. Grid AI endpoint errors → Check deployment
2. Slow benchmarks → Reduce max_workers
3. Memory issues → Use gradient checkpointing
4. Unexpected scores → Compare prompts with baseline

**Next Steps:**
1. Read full README.md for details
2. Review individual benchmark docs
3. Check out training data recommendations
4. Join team sync for strategy discussion
