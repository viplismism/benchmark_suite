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
pip install --quiet openai datasets human-eval

# Create evaluation script
cat > "$BENCHMARK_DIR/run_evaluation.py" <<'PYTHON_SCRIPT'
import os
import json
import sys
from typing import Dict, List
from datasets import load_dataset
from openai import OpenAI
from human_eval.data import write_jsonl, read_problems
from human_eval.evaluation import evaluate_functional_correctness

MODEL_ENDPOINT = os.environ.get("MODEL_ENDPOINT")
MODEL_NAME = os.environ.get("MODEL_NAME")
RESULTS_DIR = os.environ.get("RESULTS_DIR")
TEMPERATURE = float(os.environ.get("TEMPERATURE", "0.2"))
MAX_TOKENS = int(os.environ.get("MAX_TOKENS", "1024"))

# Initialize client
client = OpenAI(
    base_url=f"{MODEL_ENDPOINT}/v1",
    api_key="dummy"
)

def generate_completion(prompt: str) -> str:
    """Generate code completion for a given prompt"""
    try:
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
        return response.choices[0].message.content.strip()
    except Exception as e:
        print(f"Error generating completion: {e}", file=sys.stderr)
        return ""

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
    print(f"\nRunning HumanEval Python with model: {MODEL_NAME}")
    print(f"Endpoint: {MODEL_ENDPOINT}")
    print(f"Temperature: {TEMPERATURE}")
    print(f"Max tokens: {MAX_TOKENS}\n")
    
    # Load HumanEval dataset
    problems = read_problems()
    print(f"Loaded {len(problems)} problems\n")
    
    # Generate completions
    samples = []
    for task_id, problem in problems.items():
        print(f"Processing: {task_id}")
        
        prompt = problem["prompt"]
        generated = generate_completion(prompt)
        code = extract_code(generated)
        
        # HumanEval expects just the completion without the prompt
        # So we need to extract only the new code after the function signature
        samples.append({
            "task_id": task_id,
            "completion": code
        })
        
        print(f"  Generated {len(code)} characters")
    
    # Write samples to file
    samples_file = os.path.join(RESULTS_DIR, "samples.jsonl")
    write_jsonl(samples_file, samples)
    print(f"\nWrote {len(samples)} samples to {samples_file}")
    
    # Evaluate functional correctness
    print("\nEvaluating functional correctness...")
    results = evaluate_functional_correctness(
        sample_file=samples_file,
        k=[1],  # pass@1
        n_workers=4,
        timeout=3.0
    )
    
    # Calculate metrics
    pass_at_1 = results["pass@1"] * 100
    
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