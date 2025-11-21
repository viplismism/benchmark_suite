#!/bin/bash

# HumanEval-Rust - Basic Rust Coding Evaluation
# Tests fundamental Rust programming abilities

set -e

MODEL_ENDPOINT=$1
MODEL_NAME=$2
RESULTS_DIR=$3

BENCHMARK_DIR="./humaneval_rust"
VENV_DIR="${BENCHMARK_DIR}/venv"

echo "Setting up HumanEval-Rust..."

# Create benchmark directory (no cloning needed)
if [ ! -d "$BENCHMARK_DIR" ]; then
    mkdir -p "$BENCHMARK_DIR"
fi
cd "$BENCHMARK_DIR"

# Create virtual environment (force recreate if architecture mismatch)
if [ -d "$VENV_DIR" ]; then
    echo "Removing existing virtual environment to fix architecture issues..."
    rm -rf "$VENV_DIR"
fi
echo "Creating virtual environment..."
python3 -m venv "$VENV_DIR"

# Activate virtual environment
source "$VENV_DIR/bin/activate"

# Install dependencies with correct architecture
echo "Installing dependencies..."
pip install --quiet --upgrade pip
# Force native ARM64 build for Apple Silicon
export ARCHFLAGS="-arch arm64"
pip install --quiet --no-cache-dir --force-reinstall openai requests datasets urllib3==1.26.18
export PYTHONWARNINGS="ignore:urllib3 v2 only supports OpenSSL"

# Ensure Rust is installed
if ! command -v rustc &> /dev/null; then
    echo "Rust not found, installing..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source $HOME/.cargo/env
fi

# Create evaluation script
cat > run_evaluation.py <<'PYTHON_SCRIPT'
import os
import json
import subprocess
import tempfile
from openai import OpenAI

MODEL_ENDPOINT = os.environ.get("MODEL_ENDPOINT")
MODEL_NAME = os.environ.get("MODEL_NAME")
RESULTS_DIR = os.environ.get("RESULTS_DIR")

# Initialize client
client = OpenAI(
    base_url=f"{MODEL_ENDPOINT}/v1",
    api_key="sk-M_69wbwWPUCfaMRNloo67g"
)

def generate_rust_code(prompt: str) -> str:
    """Generate Rust code for a given prompt"""
    try:
        response = client.chat.completions.create(
            model=MODEL_NAME,
            messages=[
                {"role": "user", "content": prompt}
            ],
            temperature=0.2,
            max_tokens=2048
        )
        code = response.choices[0].message.content.strip()

        # Extract and clean the function implementation
        import re

        # Remove markdown blocks
        code = re.sub(r'```rust\n?', '', code)
        code = re.sub(r'```\n?', '', code)

        # Remove explanatory text and unicode characters
        code = re.sub(r'[→`]', '', code)
        code = re.sub(r'\*\*.*?\*\*', '', code)
        code = re.sub(r'Result:.*?$', '', code, flags=re.MULTILINE)
        code = re.sub(r'This function.*?$', '', code, flags=re.MULTILINE)

        # Find the function using a more precise regex that captures balanced braces
        lines = code.split('\n')
        func_lines = []
        inside_function = False
        brace_count = 0

        for line in lines:
            stripped = line.strip()

            # Start capturing when we find fn declaration
            if re.match(r'fn\s+\w+', stripped) and not inside_function:
                inside_function = True
                func_lines.append(line)
                brace_count += line.count('{') - line.count('}')
            elif inside_function:
                func_lines.append(line)
                brace_count += line.count('{') - line.count('}')

                # Stop when braces are balanced
                if brace_count == 0:
                    break

        if func_lines:
            # Join the function lines and clean up
            func_code = '\n'.join(func_lines)

            # Fix return statements and semicolons
            lines = func_code.split('\n')
            for i in range(len(lines) - 1):
                current = lines[i].strip()
                next_line = lines[i + 1].strip()

                # If current line doesn't end with ; { } and next line is }, handle it
                if (current and
                    not current.endswith((';', '{', '}', ',')) and
                    not current.startswith('//') and
                    next_line == '}'):

                    # If it looks like a final return value (not a statement), make it a return
                    if not any(keyword in current for keyword in ['let ', 'if ', 'for ', 'while ', 'match ', 'return ']):
                        # This is likely the final expression, make it a return statement
                        lines[i] = lines[i].replace(current, f"return {current};")
                    else:
                        # Just add semicolon
                        lines[i] = lines[i].rstrip() + ';'

            return '\n'.join(lines).strip()

        # Fallback: try to extract any function-like pattern
        match = re.search(r'fn\s+\w+[^{]*\{[^}]*\}', code, re.DOTALL)
        if match:
            return match.group(0).strip()

        return code.strip()
    except Exception as e:
        print(f"Error generating code: {e}")
        return ""

# Sample Rust problems for testing (simplified version of HumanEval)
RUST_PROBLEMS = [
    {
        "name": "has_close_elements",
        "prompt": "fn has_close_elements(numbers: Vec<f32>, threshold: f32) -> bool {\n    // Check if in given list of numbers, are any two numbers closer to each other than given threshold.\n    // Return true if yes, false otherwise.\n}",
        "tests": """
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_has_close_elements() {
        assert_eq!(has_close_elements(vec![1.0, 2.0, 3.0], 0.5), false);
        assert_eq!(has_close_elements(vec![1.0, 2.8, 3.0, 4.0, 5.0, 2.0], 0.3), true);
        assert_eq!(has_close_elements(vec![1.0, 2.0, 3.9, 4.0, 5.0, 2.2], 0.3), true);
        assert_eq!(has_close_elements(vec![1.0, 2.0, 3.9, 4.0, 5.0, 2.2], 0.05), false);
        assert_eq!(has_close_elements(vec![1.0, 2.0, 5.9, 4.0, 5.0], 0.95), true);
        assert_eq!(has_close_elements(vec![1.0, 2.0, 5.9, 4.0, 5.0], 0.8), false);
    }
}
"""
    },
    {
        "name": "greatest_common_divisor",
        "prompt": "fn greatest_common_divisor(a: i32, b: i32) -> i32 {\n    // Return the greatest common divisor of two integers a and b\n}",
        "tests": """
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_greatest_common_divisor() {
        assert_eq!(greatest_common_divisor(3, 5), 1);
        assert_eq!(greatest_common_divisor(25, 15), 5);
        assert_eq!(greatest_common_divisor(3, 7), 1);
        assert_eq!(greatest_common_divisor(10, 15), 5);
        assert_eq!(greatest_common_divisor(49, 14), 7);
        assert_eq!(greatest_common_divisor(144, 60), 12);
    }
}
"""
    }
]

def run_humaneval():
    """Run HumanEval-Rust evaluation"""
    print(f"Running HumanEval-Rust with model: {MODEL_NAME}")
    print(f"Endpoint: {MODEL_ENDPOINT}")

    # Load HumanEval-Rust dataset from HuggingFace
    from datasets import load_dataset

    print("Loading HumanEval-Rust dataset from HuggingFace...")
    dataset = load_dataset("nuprl/MultiPL-E", "humaneval-rs")

    # Get the test split (contains all problems)
    problems_data = dataset["test"]

    # Use all problems from the dataset
    # problems_data = problems_data.select(range(5))  # Comment out limit for full eval

    print(f"Loaded {len(problems_data)} problems")

    problems = []
    for item in problems_data:
        problems.append({
            "name": item["name"],
            "prompt": item["prompt"],
            "tests": item["tests"]
        })

    # Generate solutions
    results = []
    for i, problem in enumerate(problems):
        print(f"Processing problem {i+1}/{len(problems)}: {problem['name']}")

        prompt = problem["prompt"]
        generated_code = generate_rust_code(prompt)

        # Debug: Print progress info
        print(f"  Generated code ({len(generated_code)} chars)")

        # Test the generated code with Rust
        with tempfile.NamedTemporaryFile(mode='w', suffix='.rs', delete=False) as f:
            # Write the generated code and the tests
            f.write(generated_code + "\n\n")

            # Clean up the test data (remove extra braces and empty lines)
            test_code = problem["tests"]
            # Remove standalone closing braces
            test_lines = []
            for line in test_code.split('\n'):
                stripped = line.strip()
                # Skip standalone closing braces and empty lines at the start
                if stripped == '}' and not test_lines:
                    continue
                test_lines.append(line)

            f.write('\n'.join(test_lines))
            test_file = f.name

        # Note: Debug output removed since extraction is working correctly

        # Compile and run Rust tests
        try:
            # Compile with rustc
            compile_result = subprocess.run(
                ["rustc", "--test", test_file, "-o", test_file.replace('.rs', '')],
                capture_output=True,
                timeout=30
            )

            if compile_result.returncode == 0:
                # Run the tests
                test_result = subprocess.run(
                    [test_file.replace('.rs', '')],
                    capture_output=True,
                    timeout=10
                )
                passed = test_result.returncode == 0
                if not passed:
                    print(f"  Test failed: {test_result.stderr.decode()}")
            else:
                print(f"  Compilation failed: {compile_result.stderr.decode()}")
                passed = False
        except Exception as e:
            print(f"  Test failed: {e}")
            passed = False

        # Cleanup
        try:
            os.unlink(test_file)
            os.unlink(test_file.replace('.rs', ''))
        except:
            pass

        results.append({
            "problem_id": problem["name"],
            "passed": passed,
            "generated_code": generated_code  # Store full code
        })

        print(f"  Result: {'✓ PASS' if passed else '✗ FAIL'}")

    # Calculate metrics
    total = len(results)
    passed = sum(1 for r in results if r["passed"])
    pass_rate = (passed / total * 100) if total > 0 else 0

    metrics = {
        "benchmark": "humaneval-rust",
        "model": MODEL_NAME,
        "total_problems": total,
        "passed": passed,
        "pass_rate": pass_rate,
        "typical_baseline": 25.0  # Typical baseline for HumanEval variants
    }

    # Save results
    os.makedirs(RESULTS_DIR, exist_ok=True)
    results_file = os.path.join(RESULTS_DIR, "results.json")
    with open(results_file, 'w') as f:
        json.dump(results, f, indent=2)

    metrics_file = os.path.join(RESULTS_DIR, "metrics.json")
    with open(metrics_file, 'w') as f:
        json.dump(metrics, f, indent=2)

    print("\n" + "="*50)
    print("HumanEval-Rust Results")
    print("="*50)
    print(f"Total problems: {total}")
    print(f"Passed: {passed}")
    print(f"Pass rate: {pass_rate:.1f}%")
    print(f"Typical baseline: 25.0%")
    print("="*50)

    return metrics

if __name__ == "__main__":
    run_humaneval()
PYTHON_SCRIPT

# Set environment variables
export MODEL_ENDPOINT="$MODEL_ENDPOINT"
export MODEL_NAME="$MODEL_NAME"
export RESULTS_DIR="$RESULTS_DIR"

# Run evaluation
echo ""
echo "Starting HumanEval-Rust evaluation..."
python run_evaluation.py

# Deactivate virtual environment
deactivate

echo ""
echo "HumanEval-Rust evaluation complete!"
