#!/bin/bash

# Terminal-Bench 2.0 - Agentic Terminal Coding
# Tests ability to solve coding tasks through terminal commands

set -e

MODEL_ENDPOINT=$1
MODEL_NAME=$2
RESULTS_DIR=$3

BENCHMARK_DIR="./terminal_bench"
VENV_DIR="${BENCHMARK_DIR}/venv"

echo "Setting up Terminal-Bench 2.0..."

# Clone/update Terminal-Bench repository
if [ ! -d "$BENCHMARK_DIR" ]; then
    echo "Cloning Terminal-Bench repository..."
    git clone https://github.com/microsoft/terminal-bench.git "$BENCHMARK_DIR"
    cd "$BENCHMARK_DIR"
else
    echo "Using existing Terminal-Bench repository..."
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
pip install --quiet -r requirements.txt

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

def run_terminal_bench():
    """Run Terminal-Bench 2.0 evaluation"""
    print(f"Running Terminal-Bench 2.0 with model: {MODEL_NAME}")
    print(f"Endpoint: {MODEL_ENDPOINT}")
    print("Testing agentic terminal coding capabilities...")
    
    # Import Terminal-Bench evaluation module
    from terminal_bench import evaluate_agent
    
    # Configure agent to use custom model
    agent_config = {
        "model": MODEL_NAME,
        "api_base": f"{MODEL_ENDPOINT}/v1",
        "api_key": "dummy",
        "temperature": 0.0,
        "max_iterations": 10,
        "timeout": 300  # 5 minutes per task
    }
    
    # Run evaluation with Terminus-2 agent protocol
    results = evaluate_agent(
        agent_config=agent_config,
        benchmark_version="2.0",
        output_dir=RESULTS_DIR,
        num_workers=4
    )
    
    # Parse results
    total = results.get("total_tasks", 0)
    completed = results.get("completed_tasks", 0)
    success_rate = (completed / total * 100) if total > 0 else 0
    
    # Additional metrics
    avg_steps = results.get("avg_steps", 0)
    avg_time = results.get("avg_time_seconds", 0)
    tool_usage = results.get("tool_usage_stats", {})
    
    metrics = {
        "benchmark": "terminal-bench-2.0",
        "model": MODEL_NAME,
        "total_tasks": total,
        "completed": completed,
        "success_rate": success_rate,
        "avg_steps": avg_steps,
        "avg_time_seconds": avg_time,
        "tool_usage": tool_usage,
        "target_gemini_3": 54.2,  # From image
        "target_claude": 42.8
    }
    
    # Save results
    results_file = os.path.join(RESULTS_DIR, "results.json")
    with open(results_file, 'w') as f:
        json.dump(results, f, indent=2)
    
    metrics_file = os.path.join(RESULTS_DIR, "metrics.json")
    with open(metrics_file, 'w') as f:
        json.dump(metrics, f, indent=2)
    
    print("\n" + "="*50)
    print("Terminal-Bench 2.0 Results")
    print("="*50)
    print(f"Total tasks: {total}")
    print(f"Completed: {completed}")
    print(f"Success rate: {success_rate:.1f}%")
    print(f"Avg steps per task: {avg_steps:.1f}")
    print(f"Avg time per task: {avg_time:.1f}s")
    print(f"Target (Gemini 3 Pro): 54.2%")
    print(f"Target (Claude Sonnet 4.5): 42.8%")
    print("="*50)
    
    # Show tool usage breakdown
    if tool_usage:
        print("\nTool Usage Breakdown:")
        for tool, count in sorted(tool_usage.items(), key=lambda x: x[1], reverse=True):
            print(f"  {tool}: {count} calls")

if __name__ == "__main__":
    run_terminal_bench()
PYTHON_SCRIPT

# Set environment variables
export MODEL_ENDPOINT="$MODEL_ENDPOINT"
export MODEL_NAME="$MODEL_NAME"
export RESULTS_DIR="$RESULTS_DIR"

# Run evaluation
echo ""
echo "Starting Terminal-Bench 2.0 evaluation..."
python run_evaluation.py

# Deactivate virtual environment
deactivate

echo ""
echo "Terminal-Bench 2.0 evaluation complete!"
