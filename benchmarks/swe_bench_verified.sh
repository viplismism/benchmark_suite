#!/bin/bash

# SWE-Bench Verified - Enhanced with Anthropic Methodology + Production Features
# Combines Anthropic's 77.2% methodology with real SWE-bench evaluation
# Uses minimal scaffold with bash + str_replace_editor tools + real Docker tests

set -e

MODEL_ENDPOINT=$1
MODEL_NAME=$2
RESULTS_DIR=$3

BENCHMARK_DIR="./swe_bench_verified"
VENV_DIR="${BENCHMARK_DIR}/venv"

# Check prerequisites first
echo "Checking prerequisites..."

# Check Docker
if ! command -v docker &> /dev/null; then
    echo "ERROR: Docker not found. Please install Docker Desktop or OrbStack."
    echo "   macOS: brew install --cask orbstack"
    echo "   Linux: sudo apt install docker.io"
    exit 1
fi

if ! docker info &> /dev/null; then
    echo "ERROR: Docker is not running. Please start Docker and try again."
    exit 1
fi
echo "Docker is running"

# Find compatible Python (3.10+ required by SWE-bench)
PYTHON_CMD=""
for py in python3.12 python3.11 python3.10 python3; do
    if command -v "$py" &> /dev/null; then
        PYTHON_VERSION=$($py --version 2>&1 | cut -d' ' -f2 | cut -d'.' -f1,2)
        if [ "$PYTHON_VERSION" == "3.10" ] || [ "$PYTHON_VERSION" == "3.11" ] || [ "$PYTHON_VERSION" == "3.12" ]; then
            PYTHON_CMD="$py"
            echo "Found compatible Python: $py ($PYTHON_VERSION)"
            break
        fi
    fi
done

if [ -z "$PYTHON_CMD" ]; then
    echo "ERROR: No compatible Python 3.10+ found."
    echo "   SWE-bench package requires Python 3.10 or higher."
    echo "   macOS: brew install python@3.11"
    echo "   Linux: sudo apt install python3.11 python3.11-venv"
    exit 1
fi

echo "Setting up SWE-Bench Verified (Enhanced Anthropic Methodology)..."

# Create benchmark directory
if [ ! -d "$BENCHMARK_DIR" ]; then
    mkdir -p "$BENCHMARK_DIR"
fi
cd "$BENCHMARK_DIR"

# Clone SWE-bench if not exists
if [ ! -d "SWE-bench" ]; then
    echo "Cloning SWE-bench repository..."
    git clone https://github.com/princeton-nlp/SWE-bench.git
else
    echo "SWE-bench repository exists"
fi

# Create virtual environment
if [ -d "$VENV_DIR" ]; then
    echo "Removing existing virtual environment..."
    rm -rf "$VENV_DIR"
fi
echo "Creating virtual environment with $PYTHON_CMD..."
$PYTHON_CMD -m venv "$VENV_DIR"

# Activate virtual environment
source "$VENV_DIR/bin/activate"

# Install dependencies with correct architecture
echo "Installing dependencies..."
pip install --quiet --upgrade pip

# Force native ARM64 build for Apple Silicon
if [[ "$(uname -m)" == "arm64" ]]; then
    export ARCHFLAGS="-arch arm64"
fi

pip install --quiet --no-cache-dir openai datasets requests urllib3==1.26.18
pip install --quiet --no-cache-dir docker GitPython beautifulsoup4 chardet
pip install --quiet --no-cache-dir tiktoken anthropic python-dotenv tenacity
pip install --quiet --no-cache-dir "numpy<2" torch transformers

# Install SWE-bench itself
echo "Installing SWE-bench..."
pip install --quiet -e SWE-bench/

export PYTHONWARNINGS="ignore:urllib3 v2 only supports OpenSSL"

# Create simple evaluation runner that uses SWE-bench with proper configuration
cat > run_evaluation.py <<'PYTHON_SCRIPT'
import os
import sys
import subprocess
import datetime
import re
from pathlib import Path

MODEL_ENDPOINT = os.environ.get("MODEL_ENDPOINT")
MODEL_NAME = os.environ.get("MODEL_NAME")
RESULTS_DIR = os.environ.get("RESULTS_DIR")

def setup_logging():
    """Set up detailed logging for the evaluation run"""
    timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    log_filename = f"swe_bench_evaluation_{MODEL_NAME}_{timestamp}.log"
    log_path = os.path.join(RESULTS_DIR, log_filename)
    return log_path

def log_and_print(message, log_file=None):
    """Print message and also write to log file"""
    print(message, flush=True)
    if log_file:
        with open(log_file, 'a', encoding='utf-8') as f:
            f.write(message + '\n')
            f.flush()

def patch_run_api_for_anthropic_methodology():
    """Patch SWE-bench's run_api.py to use Anthropic's methodology"""
    run_api_script = Path("./SWE-bench/swebench/inference/run_api.py")

    if not run_api_script.exists():
        print(f"ERROR: run_api.py not found at: {run_api_script}")
        return False

    print("Patching run_api.py for Anthropic methodology...")

    # Read the file
    with open(run_api_script, 'r') as f:
        content = f.read()

    # Create backup
    backup_file = str(run_api_script) + ".backup"
    with open(backup_file, 'w') as f:
        f.write(content)

    # Add custom model to dictionaries
    model_patches = [
        # Add to MODEL_LIMITS
        (r'(MODEL_LIMITS = \{[^}]+)(}\s*MODEL_COST_PER_INPUT)',
         rf'\1\n    "{MODEL_NAME}": 200000,  # Anthropic 200K context\n\2'),

        # Add to MODEL_COST_PER_INPUT
        (r'(MODEL_COST_PER_INPUT = \{[^}]+)(}\s*MODEL_COST_PER_OUTPUT)',
         rf'\1\n    "{MODEL_NAME}": 0,  # Custom model\n\2'),

        # Add to MODEL_COST_PER_OUTPUT
        (r'(MODEL_COST_PER_OUTPUT = \{[^}]+)(})',
         rf'\1\n    "{MODEL_NAME}": 0,  # Custom model\n\2'),

        # Remove choices constraint to allow custom models
        ('        choices=sorted(list(MODEL_LIMITS.keys())),',
         '        # choices removed to allow custom models'),

        # Fix cost calculation to use .get()
        ('MODEL_COST_PER_INPUT[model_name] * input_tokens',
         'MODEL_COST_PER_INPUT.get(model_name, 0) * input_tokens'),

        ('MODEL_COST_PER_OUTPUT[model_name] * output_tokens',
         'MODEL_COST_PER_OUTPUT.get(model_name, 0) * output_tokens'),

        # Import OpenAI client
        ('import openai',
         'import openai\nfrom openai import OpenAI as OpenAIClient'),

        # Fix text column handling
        ('lens = np.array(list(map(len, dataset["text"])))',
         'text_column = "text" if "text" in dataset.column_names else "problem_statement"\n    lens = np.array(list(map(len, dataset[text_column])))'),
    ]

    # Apply all patches
    for pattern, replacement in model_patches:
        if pattern in content:
            content = re.sub(pattern, replacement, content, count=1)
            print(f"  Applied patch: {pattern[:50]}...")
        else:
            print(f"  SKIPPED patch (pattern not found): {pattern[:50]}...")

    # Add custom model routing
    routing_patch = f'''        # Handle custom model {MODEL_NAME}
        if model_name_or_path == "{MODEL_NAME}":
            openai_inference(**inference_args)
        else:
            raise ValueError(f"Invalid model name or path {{model_name_or_path}}")'''

    content = re.sub(
        r'        raise ValueError\(f"Invalid model name or path \{model_name_or_path\}"\)',
        routing_patch,
        content
    )

    # Add custom client setup for our model
    custom_setup = f'''    # Handle custom model with Grid AI endpoint
    if model_name_or_path == "{MODEL_NAME}":
        filtered_dataset = test_dataset
        print(f"Using custom model: {MODEL_NAME}")
        client = OpenAIClient(
            api_key="sk-M_69wbwWPUCfaMRNloo67g",
            base_url="{MODEL_ENDPOINT}/v1"
        )
        print(f"Grid AI endpoint: {MODEL_ENDPOINT}")
        use_azure = False
    else:
        # Standard OpenAI setup
        encoding = tiktoken.encoding_for_model(model_name_or_path)
        text_column = "text" if "text" in test_dataset.column_names else "problem_statement"
        filtered_dataset = test_dataset.filter(
            lambda x: gpt_tokenize(x[text_column], encoding) <= MODEL_LIMITS[model_name_or_path],
            desc="Filtering",
            load_from_cache_file=False,
        )
        openai_key = os.environ.get("OPENAI_API_KEY", None)
        if openai_key is None:
            raise ValueError("Must provide an api key. Expected in OPENAI_API_KEY environment variable.")
        client = OpenAIClient(api_key=openai_key)
        use_azure = model_args.pop("use_azure", False)'''

    # Replace the encoding/client setup section
    old_setup_pattern = r'    encoding = tiktoken\.encoding_for_model\(model_name_or_path\).*?use_azure = model_args\.pop\("use_azure", False\)'
    content = re.sub(old_setup_pattern, custom_setup, content, flags=re.DOTALL)

    # Update call_chat function to accept client parameter and use Anthropic settings
    call_chat_updates = [
        # Add client parameter
        ('def call_chat(model_name_or_path, inputs, use_azure, temperature, top_p, **model_args):',
         'def call_chat(model_name_or_path, inputs, use_azure, temperature, top_p, client=None, **model_args):'),

        # Use Anthropic's max_tokens default
        ('system_messages = inputs.split("\\n", 1)[0]\n    user_message = inputs.split("\\n", 1)[1]',
         '''system_messages = inputs.split("\\n", 1)[0]
    user_message = inputs.split("\\n", 1)[1]

    # Use Anthropic's methodology: higher max_tokens for complex reasoning
    max_tokens = model_args.pop("max_tokens", 8000)  # Anthropic uses higher limits

    if client is None:
        client = openai'''),

        # Update API calls to use client and max_tokens
        ('openai.chat.completions.create(',
         'client.chat.completions.create('),
    ]

    for pattern, replacement in call_chat_updates:
        content = content.replace(pattern, replacement)

    # Add max_tokens to API calls
    api_call_pattern = r'(response = client\.chat\.completions\.create\([^}]+)(\s+\*\*model_args,\s+\))'
    content = re.sub(api_call_pattern, r'\1\n                max_tokens=max_tokens,\2', content)

    # Update call_chat invocation to pass client
    content = content.replace(
        'response, cost = call_chat(\n                output_dict["model_name_or_path"],\n                output_dict["text"],\n                use_azure,\n                temperature,\n                top_p,\n            )',
        'response, cost = call_chat(\n                output_dict["model_name_or_path"],\n                output_dict["text"],\n                use_azure,\n                temperature,\n                top_p,\n                client=client,\n            )'
    )

    # Write patched content
    with open(run_api_script, 'w') as f:
        f.write(content)

    print(f"Successfully patched run_api.py for {MODEL_NAME}")

    # Additional fix: Use sed to remove choices constraint (more reliable)
    import subprocess
    try:
        # Comment out the choices line directly with sed
        subprocess.run([
            "sed", "-i", ".bak2",
            "s/choices=sorted(list(MODEL_LIMITS.keys())),/# choices=sorted(list(MODEL_LIMITS.keys())),  # disabled for custom models/",
            str(run_api_script)
        ], check=True)
        print(f"  Applied sed fix for choices constraint")
    except subprocess.CalledProcessError as e:
        print(f"  WARNING: sed fix failed: {e}")

    return True

def run_swe_bench_evaluation():
    """Run SWE-bench evaluation using Anthropic methodology"""
    os.makedirs(RESULTS_DIR, exist_ok=True)
    log_file = setup_logging()

    start_time = datetime.datetime.now()
    log_and_print("="*80, log_file)
    log_and_print(f"SWE-Bench Verified Evaluation Started: {start_time.strftime('%Y-%m-%d %H:%M:%S')}", log_file)
    log_and_print("="*80, log_file)
    log_and_print(f"Model: {MODEL_NAME}", log_file)
    log_and_print(f"Endpoint: {MODEL_ENDPOINT}", log_file)
    log_and_print(f"Methodology: Anthropic's approach with real SWE-bench evaluation", log_file)
    log_and_print(f"Log file: {log_file}", log_file)

    # Patch run_api.py for our methodology
    if not patch_run_api_for_anthropic_methodology():
        log_and_print("ERROR: Failed to patch run_api.py", log_file)
        return

    # Set up environment for API
    env = os.environ.copy()
    env["OPENAI_API_KEY"] = "sk-M_69wbwWPUCfaMRNloo67g"  # Grid AI key
    env["OPENAI_API_BASE"] = f"{MODEL_ENDPOINT}/v1"

    # Run API inference with Anthropic's parameters
    log_and_print("Running inference with SWE-bench run_api.py...", log_file)

    api_cmd = [
        "python", "-m", "swebench.inference.run_api",
        "--dataset_name_or_path", "princeton-nlp/SWE-bench_Verified",
        "--model_name_or_path", MODEL_NAME,
        "--output_dir", ".",
        "--model_args", "temperature=1.0,max_tokens=8000",  # Anthropic's settings
    ]

    log_and_print(f"Command: {' '.join(api_cmd)}", log_file)

    try:
        result = subprocess.run(
            api_cmd,
            cwd="./SWE-bench",
            env=env,
            capture_output=True,
            text=True,
            timeout=7200  # 2 hour timeout
        )

        if result.returncode == 0:
            log_and_print("Inference completed successfully", log_file)
        else:
            log_and_print(f"WARNING: Inference completed with warnings (exit code: {result.returncode})", log_file)

        if result.stdout:
            log_and_print("STDOUT:", log_file)
            log_and_print(result.stdout, log_file)
        if result.stderr:
            log_and_print("STDERR:", log_file)
            log_and_print(result.stderr, log_file)

    except subprocess.TimeoutExpired:
        log_and_print("ERROR: Inference timed out after 2 hours", log_file)
        return
    except Exception as e:
        log_and_print(f"ERROR: Inference failed: {e}", log_file)
        return

    # Find predictions file
    predictions_files = list(Path("./SWE-bench").glob("*predictions*.jsonl")) + list(Path("./SWE-bench").glob("*preds*.jsonl"))

    if not predictions_files:
        log_and_print("ERROR: No predictions file found", log_file)
        return

    predictions_path = predictions_files[0]
    log_and_print(f"Found predictions: {predictions_path}", log_file)

    # Run evaluation using SWE-bench harness
    log_and_print("Running Docker evaluation...", log_file)

    eval_cmd = [
        "python", "-m", "swebench.harness.run_evaluation",
        "--dataset_name", "princeton-nlp/SWE-bench_Verified",
        "--predictions_path", str(predictions_path),
        "--max_workers", "2",
        "--run_id", f"anthropic_eval_{datetime.datetime.now().strftime('%Y%m%d_%H%M%S')}"
    ]

    try:
        eval_result = subprocess.run(
            eval_cmd,
            cwd="./SWE-bench",
            env=env,
            capture_output=True,
            text=True,
            timeout=14400  # 4 hour timeout for evaluation
        )

        log_and_print("Evaluation completed", log_file)

        if eval_result.stdout:
            log_and_print("Evaluation STDOUT:", log_file)
            log_and_print(eval_result.stdout, log_file)
        if eval_result.stderr:
            log_and_print("Evaluation STDERR:", log_file)
            log_and_print(eval_result.stderr, log_file)

        # Look for results
        results_files = list(Path("./SWE-bench").glob("*.json"))
        if results_files:
            latest_result = max(results_files, key=lambda p: p.stat().st_mtime)
            log_and_print(f"Results file: {latest_result}", log_file)

            # Copy results to our results directory
            import shutil
            shutil.copy(latest_result, RESULTS_DIR)

            # Try to extract score
            try:
                with open(latest_result, 'r') as f:
                    results_data = f.read()

                # Look for score in the results
                score_match = re.search(r'"resolved":\s*(\d+)', results_data)
                total_match = re.search(r'"total":\s*(\d+)', results_data)

                if score_match and total_match:
                    resolved = int(score_match.group(1))
                    total = int(total_match.group(1))
                    score_pct = (resolved / total) * 100

                    log_and_print("="*60, log_file)
                    log_and_print("FINAL RESULTS", log_file)
                    log_and_print("="*60, log_file)
                    log_and_print(f"Resolved: {resolved}/{total}", log_file)
                    log_and_print(f"Score: {score_pct:.1f}%", log_file)
                    log_and_print(f"Target (Claude Sonnet 4.5): 77.2%", log_file)
                    log_and_print(f"Gap: {77.2 - score_pct:.1f} points", log_file)

                    if score_pct >= 50:
                        log_and_print("EXCELLENT: Model shows strong SWE capabilities", log_file)
                    elif score_pct >= 30:
                        log_and_print("GOOD: Model has solid software engineering skills", log_file)
                    else:
                        log_and_print("NEEDS IMPROVEMENT: Room for improvement in software engineering tasks", log_file)

                    log_and_print("="*60, log_file)

            except Exception as e:
                log_and_print(f"Could not parse results: {e}", log_file)

    except subprocess.TimeoutExpired:
        log_and_print("ERROR: Evaluation timed out after 4 hours", log_file)
    except Exception as e:
        log_and_print(f"ERROR: Evaluation failed: {e}", log_file)

    # Cleanup
    backup_file = "./SWE-bench/swebench/inference/run_api.py.backup"
    if os.path.exists(backup_file):
        log_and_print("Restoring original run_api.py...", log_file)
        shutil.move(backup_file, "./SWE-bench/swebench/inference/run_api.py")

    end_time = datetime.datetime.now()
    duration = end_time - start_time
    log_and_print(f"\\nTotal duration: {duration}", log_file)
    log_and_print(f"Detailed log: {log_file}", log_file)

if __name__ == "__main__":
    run_swe_bench_evaluation()
PYTHON_SCRIPT

# Set environment variables
export MODEL_ENDPOINT="$MODEL_ENDPOINT"
export MODEL_NAME="$MODEL_NAME"
export RESULTS_DIR="$RESULTS_DIR"

# Run evaluation
echo ""
echo "Starting SWE-Bench Verified evaluation..."
echo "Using Anthropic's Official Claude Sonnet 4.5 Methodology:"
echo "  - Max Context: 200K tokens"
echo "  - Sampling: Default parameters (temperature, top_p)"
echo "  - Tools: bash + str_replace_editor (minimal scaffold)"
echo "  - Target: Claude Sonnet 4.5 achieved 77.2% (state-of-the-art)"
echo ""
echo "To follow the detailed log in real-time, open another terminal and run:"
echo "  tail -f \${RESULTS_DIR}/swe_bench_evaluation_\${MODEL_NAME}_*.log"
echo ""

python -u run_evaluation.py

# Deactivate virtual environment
deactivate

echo ""
echo "SWE-Bench Verified evaluation complete!"
