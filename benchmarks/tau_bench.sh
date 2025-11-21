#!/bin/bash

# τ-Bench (Tau-Bench) - Tool Use Evaluation
# Tests agentic tool calling capabilities

set -e

MODEL_ENDPOINT=$1
MODEL_NAME=$2
RESULTS_DIR=$3

BENCHMARK_DIR="./tau_bench"
VENV_DIR="${BENCHMARK_DIR}/venv"

echo "Setting up τ-Bench..."

# Clone/update τ-Bench repository
if [ ! -d "$BENCHMARK_DIR" ]; then
    echo "Cloning τ-Bench repository..."
    git clone https://github.com/sierra-research/tau-bench.git "$BENCHMARK_DIR"
    cd "$BENCHMARK_DIR"
else
    echo "Using existing τ-Bench repository..."
    cd "$BENCHMARK_DIR"
    git pull origin main || true
fi

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
pip install --quiet -e .

# Create evaluation script
cat > run_evaluation.py <<'PYTHON_SCRIPT'
import os
import json
from openai import OpenAI

MODEL_ENDPOINT = os.environ.get("MODEL_ENDPOINT")
MODEL_NAME = os.environ.get("MODEL_NAME")
RESULTS_DIR = os.environ.get("RESULTS_DIR")

# Initialize client
client = OpenAI(
    base_url=f"{MODEL_ENDPOINT}/v1",
    api_key="dummy"
)

def run_tau_bench():
    """Run τ-Bench evaluation"""
    from tau_bench import evaluate
    
    print(f"Running τ-Bench with model: {MODEL_NAME}")
    print(f"Endpoint: {MODEL_ENDPOINT}")
    print("Testing tool calling and agentic capabilities...")
    
    # Configure τ-Bench to use custom model
    config = {
        "model_name": MODEL_NAME,
        "api_base": f"{MODEL_ENDPOINT}/v1",
        "api_key": "dummy",
        "temperature": 0.0,
        "max_tokens": 2048
    }
    
    # Run evaluation
    results = evaluate(
        model_config=config,
        dataset="retail",  # Start with retail domain
        output_dir=RESULTS_DIR
    )
    
    # Calculate metrics
    total = results.get("total", 0)
    correct = results.get("correct", 0)
    tool_accuracy = (correct / total * 100) if total > 0 else 0
    
    # Check tool calling success rate
    tool_calls = results.get("tool_calls", [])
    valid_calls = sum(1 for tc in tool_calls if tc.get("valid", False))
    tool_call_success = (valid_calls / len(tool_calls) * 100) if tool_calls else 0
    
    metrics = {
        "benchmark": "tau-bench",
        "model": MODEL_NAME,
        "total_tasks": total,
        "correct": correct,
        "accuracy": tool_accuracy,
        "tool_call_success_rate": tool_call_success,
        "target_gemini_3": 85.4  # From image
    }
    
    # Save results
    results_file = os.path.join(RESULTS_DIR, "results.json")
    with open(results_file, 'w') as f:
        json.dump(results, f, indent=2)
    
    metrics_file = os.path.join(RESULTS_DIR, "metrics.json")
    with open(metrics_file, 'w') as f:
        json.dump(metrics, f, indent=2)
    
    print("\n" + "="*50)
    print("τ-Bench Results")
    print("="*50)
    print(f"Total tasks: {total}")
    print(f"Correct: {correct}")
    print(f"Accuracy: {tool_accuracy:.1f}%")
    print(f"Tool call success: {tool_call_success:.1f}%")
    print(f"Target (Gemini 3 Pro): 85.4%")
    print(f"Gap: {85.4 - tool_accuracy:.1f}%")
    print("="*50)
    print("\n⚠️  This is your identified bottleneck!")
    print("Focus on improving tool calling examples in training data")

if __name__ == "__main__":
    run_tau_bench()
PYTHON_SCRIPT

# Set environment variables
export MODEL_ENDPOINT="$MODEL_ENDPOINT"
export MODEL_NAME="$MODEL_NAME"
export RESULTS_DIR="$RESULTS_DIR"

# Run evaluation
echo ""
echo "Starting τ-Bench evaluation..."
echo "This tests tool calling - your identified bottleneck"
python run_evaluation.py

# Deactivate virtual environment
deactivate

echo ""
echo "τ-Bench evaluation complete!"
