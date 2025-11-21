#!/bin/bash

# LiveCodeBench - Competitive Programming Evaluation
# Tests coding ability with Elo rating system

set -e

MODEL_ENDPOINT=$1
MODEL_NAME=$2
RESULTS_DIR=$3

BENCHMARK_DIR="./livecodebench"
VENV_DIR="${BENCHMARK_DIR}/venv"

echo "Setting up LiveCodeBench..."

# Clone/update LiveCodeBench repository
if [ ! -d "$BENCHMARK_DIR" ]; then
    echo "Cloning LiveCodeBench repository..."
    git clone https://github.com/LiveCodeBench/LiveCodeBench.git "$BENCHMARK_DIR"
    cd "$BENCHMARK_DIR"
else
    echo "Using existing LiveCodeBench repository..."
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

# Initialize client with custom endpoint
client = OpenAI(
    base_url=f"{MODEL_ENDPOINT}/v1",
    api_key="dummy"
)

def run_livecodebench():
    """Run LiveCodeBench evaluation"""
    import subprocess
    
    print(f"Running LiveCodeBench with model: {MODEL_NAME}")
    print(f"Endpoint: {MODEL_ENDPOINT}")
    
    # Run LiveCodeBench evaluation
    cmd = [
        "python", "-m", "lcb_runner.runner.main",
        "--model", MODEL_NAME,
        "--scenario", "codegeneration",
        "--evaluate",
        "--output_dir", RESULTS_DIR,
        "--custom_model_endpoint", MODEL_ENDPOINT
    ]
    
    subprocess.run(cmd, check=True)
    
    # Load and parse results
    results_file = os.path.join(RESULTS_DIR, "results.jsonl")
    
    if os.path.exists(results_file):
        with open(results_file, 'r') as f:
            results = [json.loads(line) for line in f]
        
        # Calculate metrics
        total = len(results)
        passed = sum(1 for r in results if r.get("pass", False))
        pass_rate = (passed / total * 100) if total > 0 else 0
        
        # Get Elo rating if available
        elo_rating = None
        for r in results:
            if "elo" in r:
                elo_rating = r["elo"]
                break
        
        metrics = {
            "benchmark": "livecodebench",
            "model": MODEL_NAME,
            "total_problems": total,
            "passed": passed,
            "pass_rate": pass_rate,
            "elo_rating": elo_rating,
            "target_score": 2439  # Target from image
        }
        
        metrics_file = os.path.join(RESULTS_DIR, "metrics.json")
        with open(metrics_file, 'w') as f:
            json.dump(metrics, f, indent=2)
        
        print("\n" + "="*50)
        print("LiveCodeBench Results")
        print("="*50)
        print(f"Total problems: {total}")
        print(f"Passed: {passed}")
        print(f"Pass rate: {pass_rate:.1f}%")
        if elo_rating:
            print(f"Elo rating: {elo_rating}")
            print(f"Target (Gemini 3 Pro): 2439")
            print(f"Gap: {2439 - elo_rating}")
        print("="*50)

if __name__ == "__main__":
    run_livecodebench()
PYTHON_SCRIPT

# Set environment variables
export MODEL_ENDPOINT="$MODEL_ENDPOINT"
export MODEL_NAME="$MODEL_NAME"
export RESULTS_DIR="$RESULTS_DIR"

# Run evaluation
echo ""
echo "Starting LiveCodeBench evaluation..."
python run_evaluation.py

# Deactivate virtual environment
deactivate

echo ""
echo "LiveCodeBench evaluation complete!"
