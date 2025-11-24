#!/bin/bash
set -e

# HumanEval Python Evaluation Script
# Based on the Rust evaluation structure
# Targets: KAT-Coder (96.3%), Claude Sonnet 4.5 (~96-98%)

# Check arguments
if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <model_endpoint> <model_name> [results_dir]"
    echo "Example: $0 http://localhost:8000 kat-dev-32B ./results/humaneval-python"
    exit 1
fi

MODEL_ENDPOINT="$1"
MODEL_NAME="$2"
RESULTS_DIR="${3:-./results/humaneval-python}"

# Setup directories
BENCHMARK_DIR="./benchmarks/humaneval"
VENV_DIR="$BENCHMARK_DIR/venv"

mkdir -p "$RESULTS_DIR"
mkdir -p "$BENCHMARK_DIR"

echo "=========================================="
echo "HumanEval Python Evaluation"
echo "=========================================="
echo "Model: $MODEL_NAME"
echo "Endpoint: $MODEL_ENDPOINT"
echo "Results: $RESULTS_DIR"
echo "=========================================="

# Create virtual environment
if [ ! -d "$VENV_DIR" ]; then
    echo "Creating virtual environment..."
    python3 -m venv "$VENV_DIR"
fi

# Activate virtual environment
source "$VENV_DIR/bin/activate"

# Install dependencies
echo "Installing dependencies..."
pip install --quiet --upgrade pip
pip install --quiet openai datasets human-eval "urllib3==1.26.18"

# Suppress urllib3 warnings
export PYTHONWARNINGS="ignore:urllib3 v2 only supports OpenSSL"

# Create evaluation script
cat > "$BENCHMARK_DIR/run_evaluation.py" <<'PYTHON_SCRIPT'
import warnings
warnings.filterwarnings("ignore", message=".*urllib3 v2 only supports OpenSSL.*")

import os
import json
import sys
import datetime
import time
from typing import Dict, List
from datasets import load_dataset
from openai import OpenAI
from human_eval.data import write_jsonl, read_problems
from human_eval.evaluation import evaluate_functional_correctness

# Global log file paths
LOG_FILE_DETAILED = None  # .log file with all details
LOG_FILE_SUMMARY = None   # .txt file with human-readable summary

def setup_logging():
    """Set up detailed and summary logging"""
    timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")

    # Detailed log (.log format)
    log_detailed = f"humaneval_python_detailed_{MODEL_NAME}_{timestamp}.log"
    log_detailed_path = os.path.join(RESULTS_DIR, log_detailed)

    # Summary log (.txt format - human readable)
    log_summary = f"humaneval_python_summary_{MODEL_NAME}_{timestamp}.txt"
    log_summary_path = os.path.join(RESULTS_DIR, log_summary)

    return log_detailed_path, log_summary_path

def log_detailed(message, indent=0):
    """Write to detailed log only"""
    if LOG_FILE_DETAILED:
        timestamp = datetime.datetime.now().strftime("%H:%M:%S")
        indent_str = "  " * indent
        with open(LOG_FILE_DETAILED, 'a', encoding='utf-8') as f:
            f.write(f"[{timestamp}] {indent_str}{message}\n")
            f.flush()

def log_summary(message, also_print=True):
    """Write to summary log and optionally print to console"""
    if also_print:
        print(message, flush=True)
    if LOG_FILE_SUMMARY:
        with open(LOG_FILE_SUMMARY, 'a', encoding='utf-8') as f:
            f.write(message + '\n')
            f.flush()

def log_both(message, indent=0):
    """Write to both logs and print to console"""
    print(message, flush=True)
    log_detailed(message, indent)
    if LOG_FILE_SUMMARY:
        with open(LOG_FILE_SUMMARY, 'a', encoding='utf-8') as f:
            f.write(message + '\n')
            f.flush()

MODEL_ENDPOINT = os.environ.get("MODEL_ENDPOINT")
MODEL_NAME = os.environ.get("MODEL_NAME")
RESULTS_DIR = os.environ.get("RESULTS_DIR")
TEMPERATURE = float(os.environ.get("TEMPERATURE", "0.2"))
MAX_TOKENS = int(os.environ.get("MAX_TOKENS", "1024"))

# Initialize client
client = OpenAI(
    base_url=f"{MODEL_ENDPOINT}/v1",
    api_key="sk-M_69wbwWPUCfaMRNloo67g"
)

def generate_completion(prompt: str, problem_id: str) -> tuple:
    """Generate code completion for a given prompt"""
    start_time = time.time()
    try:
        log_detailed(f"Starting generation for {problem_id}", indent=1)
        response = client.chat.completions.create(
            model=MODEL_NAME,
            messages=[
                {
                    "role": "system",
                    "content": "You are an expert Python programmer. Complete the function below. Only output the function body, no explanations or markdown."
                },
                {
                    "role": "user",
                    "content": f"Complete this Python function:\n\n{prompt}\n\nProvide only the complete function implementation, starting with the def statement."
                }
            ],
            temperature=TEMPERATURE,
            max_tokens=MAX_TOKENS
        )
        elapsed = time.time() - start_time
        content = response.choices[0].message.content.strip()
        tokens_used = response.usage.total_tokens if hasattr(response, 'usage') else 0

        log_detailed(f"Generated completion for {problem_id}: {len(content)} chars, {tokens_used} tokens, {elapsed:.2f}s", indent=1)
        return content, tokens_used, elapsed
    except Exception as e:
        elapsed = time.time() - start_time
        log_detailed(f"Error generating completion for {problem_id}: {e} (after {elapsed:.2f}s)", indent=1)
        log_summary(f"  Error generating completion for {problem_id}: {str(e)[:100]}")
        return "", 0, elapsed

def extract_code(generated: str) -> str:
    """Extract code from generated response, handling markdown blocks"""
    # Remove markdown code blocks if present
    if "```python" in generated:
        parts = generated.split("```python")
        if len(parts) > 1:
            code = parts[1].split("```")[0]
            return code.strip()
    elif "```" in generated:
        parts = generated.split("```")
        if len(parts) > 1:
            code = parts[1].split("```")[0]
            return code.strip()
    return generated.strip()

def run_humaneval_python():
    """Run HumanEval Python evaluation"""
    global LOG_FILE_DETAILED, LOG_FILE_SUMMARY

    # Set up logging
    os.makedirs(RESULTS_DIR, exist_ok=True)
    LOG_FILE_DETAILED, LOG_FILE_SUMMARY = setup_logging()

    # Log initial configuration
    start_time = datetime.datetime.now()

    header = f"""
{'='*80}
HUMANEVAL PYTHON EVALUATION
{'='*80}
Started: {start_time.strftime('%Y-%m-%d %H:%M:%S')}

Configuration:
  Model: {MODEL_NAME}
  Endpoint: {MODEL_ENDPOINT}
  Temperature: {TEMPERATURE}
  Max tokens: {MAX_TOKENS}

Log Files:
  Detailed: {LOG_FILE_DETAILED}
  Summary:  {LOG_FILE_SUMMARY}

{'='*80}
"""
    log_both(header)

    # Load HumanEval dataset
    log_both("Loading HumanEval dataset...")
    problems = read_problems()
    log_both(f"✓ Loaded {len(problems)} problems from HumanEval dataset\n")

    # Generate completions
    log_both("Starting code generation...")
    samples = []
    total_tokens = 0
    total_time = 0

    for i, (task_id, problem) in enumerate(problems.items(), 1):
        log_summary(f"Processing {i}/{len(problems)}: {task_id}")
        log_detailed(f"Problem {i}/{len(problems)}: {task_id}")
        log_detailed(f"Prompt: {problem['prompt'][:200]}...", indent=1)

        prompt = problem["prompt"]
        generated, tokens_used, elapsed = generate_completion(prompt, task_id)
        code = extract_code(generated)
        total_tokens += tokens_used
        total_time += elapsed

        # HumanEval expects just the completion without the prompt
        samples.append({
            "task_id": task_id,
            "completion": code
        })

        log_summary(f"  Generated {len(code)} characters in {elapsed:.2f}s")
        log_detailed(f"Generated code length: {len(code)}, tokens: {tokens_used}", indent=1)
    
    # Write samples to file
    samples_file = os.path.join(RESULTS_DIR, "samples.jsonl")
    write_jsonl(samples_file, samples)
    log_both(f"\nWrote {len(samples)} samples to {samples_file}")

    # Evaluate functional correctness
    log_both("Evaluating functional correctness...")
    log_detailed("Running test suites for all generated completions")
    results = evaluate_functional_correctness(
        sample_file=samples_file,
        k=[1],  # pass@1
        n_workers=4,
        timeout=3.0
    )

    # Calculate metrics
    pass_at_1 = results["pass@1"] * 100
    avg_time_per_problem = total_time / len(problems)
    avg_tokens_per_problem = total_tokens / len(problems)
    
    metrics = {
        "benchmark": "humaneval-python",
        "model": MODEL_NAME,
        "temperature": TEMPERATURE,
        "max_tokens": MAX_TOKENS,
        "total_problems": len(problems),
        "pass@1": pass_at_1,
        "baselines": {
            "kat_coder_official": 96.3,
            "claude_4_sonnet": 98.2,
            "qwen3_coder_480b": 95.1,
            "claude_3_5_sonnet": 92.0
        },
        "target": {
            "competitive_threshold": 90.0,
            "kat_coder_parity": 96.3,
            "claude_sonnet_parity": 96.0
        }
    }
    
    # Save detailed results
    results_file = os.path.join(RESULTS_DIR, "results.json")
    with open(results_file, 'w') as f:
        json.dump(results, f, indent=2)
    
    metrics_file = os.path.join(RESULTS_DIR, "metrics.json")
    with open(metrics_file, 'w') as f:
        json.dump(metrics, f, indent=2)
    
    # Print summary
    print("\n" + "="*60)
    print("HumanEval Python Results")
    print("="*60)
    print(f"Model: {MODEL_NAME}")
    print(f"Total problems: {len(problems)}")
    print(f"Pass@1: {pass_at_1:.1f}%")
    print("\nBaselines:")
    print(f"  KAT-Coder (official):      96.3%")
    print(f"  Claude 4 Sonnet:           98.2%")
    print(f"  Qwen3-Coder-480B:          95.1%")
    print(f"  Claude 3.5 Sonnet:         92.0%")
    print("\nTargets:")
    print(f"  Competitive threshold:     90.0%")
    print(f"  KAT-Coder parity:          96.3%")
    print("="*60)
    
    # Performance assessment
    if pass_at_1 >= 96.0:
        print("🎯 EXCELLENT: Competitive with KAT-Coder and Claude Sonnet!")
    elif pass_at_1 >= 90.0:
        print("✓ GOOD: Competitive with SOTA models")
    elif pass_at_1 >= 80.0:
        print("⚠ FAIR: Above average but needs improvement")
    else:
        print("❌ NEEDS WORK: Below competitive threshold")
    
    print("="*60 + "\n")
    
    return metrics

if __name__ == "__main__":
    try:
        metrics = run_humaneval_python()
        sys.exit(0)
    except Exception as e:
        print(f"\nError during evaluation: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc()
        sys.exit(1)
PYTHON_SCRIPT

# Set environment variables
export MODEL_ENDPOINT="$MODEL_ENDPOINT"
export MODEL_NAME="$MODEL_NAME"
export RESULTS_DIR="$RESULTS_DIR"
export TEMPERATURE="${TEMPERATURE:-0.2}"
export MAX_TOKENS="${MAX_TOKENS:-1024}"

# Run evaluation
echo ""
echo "Starting HumanEval Python evaluation..."
python "$BENCHMARK_DIR/run_evaluation.py"

# Deactivate virtual environment
deactivate

echo ""
echo "HumanEval Python evaluation complete!"
echo "Results saved to: $RESULTS_DIR"