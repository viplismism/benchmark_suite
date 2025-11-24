#!/bin/bash

# SWE-Bench Verified - Simple Direct Approach (NO PATCHING)
# Just runs inference via Grid AI + uses standard SWE-bench evaluation

set -e

MODEL_ENDPOINT=$1
MODEL_NAME=$2
RESULTS_DIR=$3

if [ -z "$MODEL_ENDPOINT" ] || [ -z "$MODEL_NAME" ] || [ -z "$RESULTS_DIR" ]; then
    echo "Usage: $0 <MODEL_ENDPOINT> <MODEL_NAME> <RESULTS_DIR>"
    echo "Example: $0 https://grid.ai.juspay.net claude-sonnet-4-5 ./results"
    exit 1
fi

BENCHMARK_DIR="./swe_bench_verified"
VENV_DIR="${BENCHMARK_DIR}/venv"

# Check prerequisites
echo "Checking prerequisites..."

if ! command -v docker &> /dev/null; then
    echo "ERROR: Docker not found."
    exit 1
fi

if ! docker info &> /dev/null 2>&1; then
    echo "ERROR: Docker is not running."
    exit 1
fi
echo "✅ Docker is running"

# Find Python 3.10+
PYTHON_CMD=""
for py in python3.12 python3.11 python3.10 python3; do
    if command -v "$py" &> /dev/null; then
        PYTHON_VERSION=$($py --version 2>&1 | cut -d' ' -f2 | cut -d'.' -f1,2)
        if [ "$PYTHON_VERSION" == "3.10" ] || [ "$PYTHON_VERSION" == "3.11" ] || [ "$PYTHON_VERSION" == "3.12" ]; then
            PYTHON_CMD="$py"
            echo "✅ Found Python: $py ($PYTHON_VERSION)"
            break
        fi
    fi
done

if [ -z "$PYTHON_CMD" ]; then
    echo "ERROR: No compatible Python 3.10+ found."
    exit 1
fi

echo ""
echo "======================================"
echo "SWE-Bench Verified Evaluation"
echo "======================================"
echo "Model: $MODEL_NAME"
echo "Endpoint: $MODEL_ENDPOINT"
echo "Results: $RESULTS_DIR"
echo ""

mkdir -p "$BENCHMARK_DIR"
cd "$BENCHMARK_DIR"

# Clone SWE-bench if needed
if [ ! -d "SWE-bench" ]; then
    echo "Cloning SWE-bench repository..."
    git clone https://github.com/princeton-nlp/SWE-bench.git
else
    echo "✅ SWE-bench repository exists"
fi

# Create fresh virtual environment
if [ -d "$VENV_DIR" ]; then
    rm -rf "$VENV_DIR"
fi
echo "Creating virtual environment..."
$PYTHON_CMD -m venv "$VENV_DIR"

source "$VENV_DIR/bin/activate"

echo "Installing dependencies..."
pip install --quiet --upgrade pip

if [[ "$(uname -m)" == "arm64" ]]; then
    export ARCHFLAGS="-arch arm64"
fi

pip install --quiet --no-cache-dir openai datasets requests urllib3==1.26.18
pip install --quiet --no-cache-dir docker GitPython beautifulsoup4 chardet
pip install --quiet --no-cache-dir "numpy<2"

echo "Installing SWE-bench..."
pip install --quiet -e SWE-bench/

export PYTHONWARNINGS="ignore:urllib3 v2 only supports OpenSSL"

# Create our own simple inference script
cat > run_inference.py <<'PYTHON_SCRIPT'
import os
import json
import sys
import datetime
from pathlib import Path
from datasets import load_dataset
from openai import OpenAI

MODEL_ENDPOINT = os.environ.get("MODEL_ENDPOINT")
MODEL_NAME = os.environ.get("MODEL_NAME")
RESULTS_DIR = os.environ.get("RESULTS_DIR")

def log(msg):
    timestamp = datetime.datetime.now().strftime('%H:%M:%S')
    print(f"[{timestamp}] {msg}", flush=True)

def run_inference():
    """Run inference on SWE-bench Verified dataset"""
    
    os.makedirs(RESULTS_DIR, exist_ok=True)
    
    log("="*80)
    log("SWE-Bench Verified Inference")
    log("="*80)
    log(f"Model: {MODEL_NAME}")
    log(f"Endpoint: {MODEL_ENDPOINT}")
    log(f"Temperature: 1.0, Max Tokens: 8000 (Anthropic methodology)")
    log("")
    
    # Initialize OpenAI client pointing to Grid AI
    client = OpenAI(
        api_key="sk-M_69wbwWPUCfaMRNloo67g",
        base_url=f"{MODEL_ENDPOINT}/v1"
    )
    
    # Load dataset
    log("Loading SWE-bench Verified dataset...")
    dataset = load_dataset("princeton-nlp/SWE-bench_Verified", split="test")
    log(f"✅ Loaded {len(dataset)} instances")
    log("")
    
    # Output file
    predictions_file = Path(".") / f"{MODEL_NAME}__SWE-bench_Verified__test.jsonl"
    
    # Check if we have existing predictions to resume from
    completed_ids = set()
    if predictions_file.exists():
        log(f"Found existing predictions file: {predictions_file}")
        with open(predictions_file, 'r') as f:
            for line in f:
                if line.strip():
                    try:
                        data = json.loads(line)
                        completed_ids.add(data['instance_id'])
                    except:
                        pass
        log(f"✅ Resuming: {len(completed_ids)} already completed")
        log("")
    
    # Process each instance
    output_file = open(predictions_file, 'a')
    
    completed_count = 0
    error_count = 0
    
    for idx, instance in enumerate(dataset):
        instance_id = instance['instance_id']
        
        if instance_id in completed_ids:
            continue
        
        log(f"[{idx+1}/{len(dataset)}] Processing {instance_id}...")
        
        # Build prompt (using SWE-bench standard format)
        problem_statement = instance['problem_statement']
        
        prompt = f"""You are an expert software engineer. Please analyze and fix the following issue:

{problem_statement}

Please provide a patch in unified diff format that resolves this issue."""
        
        try:
            # Call the model with Anthropic methodology parameters
            response = client.chat.completions.create(
                model=MODEL_NAME,
                messages=[
                    {"role": "system", "content": "You are an expert software engineer skilled at debugging and fixing code issues."},
                    {"role": "user", "content": prompt}
                ],
                temperature=1.0,
                max_tokens=8000
            )
            
            model_patch = response.choices[0].message.content
            
            # Save prediction in SWE-bench format
            prediction = {
                "instance_id": instance_id,
                "model_patch": model_patch,
                "model_name_or_path": MODEL_NAME
            }
            
            output_file.write(json.dumps(prediction) + '\n')
            output_file.flush()
            
            completed_count += 1
            log(f"  ✅ Completed")
            
        except Exception as e:
            log(f"  ❌ Error: {e}")
            error_count += 1
            # Save empty prediction to track failure
            prediction = {
                "instance_id": instance_id,
                "model_patch": "",
                "model_name_or_path": MODEL_NAME
            }
            output_file.write(json.dumps(prediction) + '\n')
            output_file.flush()
    
    output_file.close()
    
    log("")
    log("="*80)
    log("INFERENCE COMPLETE")
    log("="*80)
    log(f"Total processed: {completed_count + error_count}")
    log(f"Successful: {completed_count}")
    log(f"Errors: {error_count}")
    log(f"Predictions file: {predictions_file}")
    log("="*80)
    log("")
    
    return str(predictions_file)

if __name__ == "__main__":
    try:
        predictions_file = run_inference()
        # Print in a way that can be captured
        print(f"PREDICTIONS_FILE={predictions_file}")
        sys.exit(0)
    except Exception as e:
        log(f"FATAL ERROR: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)
PYTHON_SCRIPT

# Create evaluation script
cat > run_evaluation.py <<'PYTHON_SCRIPT'
import os
import sys
import subprocess
import datetime
import json
import re
import shutil
from pathlib import Path

PREDICTIONS_FILE = os.environ.get("PREDICTIONS_FILE")
RESULTS_DIR = os.environ.get("RESULTS_DIR")
MODEL_NAME = os.environ.get("MODEL_NAME")

def log(msg):
    timestamp = datetime.datetime.now().strftime('%H:%M:%S')
    print(f"[{timestamp}] {msg}", flush=True)

def run_evaluation():
    """Run SWE-bench evaluation harness"""
    
    log("="*80)
    log("SWE-Bench Verified Evaluation")
    log("="*80)
    log(f"Predictions: {PREDICTIONS_FILE}")
    log(f"Results: {RESULTS_DIR}")
    log("")
    
    if not os.path.exists(PREDICTIONS_FILE):
        log(f"❌ ERROR: Predictions file not found: {PREDICTIONS_FILE}")
        return
    
    # Run evaluation
    eval_cmd = [
        "python", "-m", "swebench.harness.run_evaluation",
        "--dataset_name", "princeton-nlp/SWE-bench_Verified",
        "--predictions_path", str(PREDICTIONS_FILE),
        "--max_workers", "2",
        "--run_id", f"eval_{datetime.datetime.now().strftime('%Y%m%d_%H%M%S')}"
    ]
    
    log(f"Running: {' '.join(eval_cmd)}")
    log("This will take a while (running tests in Docker containers)...")
    log("")
    
    try:
        result = subprocess.run(
            eval_cmd,
            cwd="./SWE-bench",
            capture_output=True,
            text=True,
            timeout=14400  # 4 hours
        )
        
        log("Evaluation completed!")
        log("")
        
        if result.stdout:
            print(result.stdout)
        if result.stderr:
            print("STDERR:", result.stderr)
        
        # Find and copy results
        results_files = list(Path("./SWE-bench").glob("*results*.json"))
        if results_files:
            latest_result = max(results_files, key=lambda p: p.stat().st_mtime)
            log(f"Results file: {latest_result}")
            
            # Copy to results dir
            dest = Path(RESULTS_DIR) / "swe_bench_results.json"
            shutil.copy(latest_result, dest)
            log(f"Copied results to: {dest}")
            log("")
            
            # Parse and display results
            with open(latest_result, 'r') as f:
                results_data = json.load(f)
            
            # Count resolved instances
            if isinstance(results_data, dict):
                resolved = len([k for k, v in results_data.items() if v.get('resolved', False)])
                total = len(results_data)
            else:
                # Try to extract from summary
                resolved = 0
                total = 0
                for item in results_data:
                    if isinstance(item, dict):
                        total += 1
                        if item.get('resolved', False):
                            resolved += 1
            
            score_pct = (resolved / total * 100) if total > 0 else 0
            
            log("="*80)
            log("FINAL RESULTS")
            log("="*80)
            log(f"Model: {MODEL_NAME}")
            log(f"Resolved: {resolved}/{total}")
            log(f"Score: {score_pct:.1f}%")
            log(f"")
            log(f"Target (Claude Sonnet 4.5): 77.2%")
            log(f"Gap: {77.2 - score_pct:.1f} percentage points")
            log("="*80)
            
        else:
            log("⚠️  WARNING: No results file found")
            
    except subprocess.TimeoutExpired:
        log("❌ ERROR: Evaluation timed out after 4 hours")
    except Exception as e:
        log(f"❌ ERROR: {e}")
        import traceback
        traceback.print_exc()

if __name__ == "__main__":
    run_evaluation()
PYTHON_SCRIPT

# Set environment variables
export MODEL_ENDPOINT="$MODEL_ENDPOINT"
export MODEL_NAME="$MODEL_NAME"
export RESULTS_DIR="$RESULTS_DIR"

echo ""
echo "STEP 1: Running inference on all SWE-bench instances..."
echo "----------------------------------------"

# Run inference and capture the predictions file path
INFERENCE_OUTPUT=$(python -u run_inference.py 2>&1 | tee /dev/tty)
PREDICTIONS_FILE_LINE=$(echo "$INFERENCE_OUTPUT" | grep "^PREDICTIONS_FILE=")

if [ -z "$PREDICTIONS_FILE_LINE" ]; then
    echo "❌ ERROR: Could not get predictions file path"
    exit 1
fi

export PREDICTIONS_FILE=$(echo "$PREDICTIONS_FILE_LINE" | cut -d'=' -f2)

if [ ! -f "$PREDICTIONS_FILE" ]; then
    echo "❌ ERROR: Predictions file not found: $PREDICTIONS_FILE"
    exit 1
fi

echo ""
echo "STEP 2: Running evaluation (testing patches in Docker)..."
echo "----------------------------------------"
python -u run_evaluation.py

deactivate

echo ""
echo "✅ SWE-Bench Verified evaluation complete!"
echo "Results directory: $RESULTS_DIR"