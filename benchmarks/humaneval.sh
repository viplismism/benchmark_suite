#!/bin/bash
set -e

MODEL_ENDPOINT=$1
MODEL_NAME=$2
RESULTS_DIR=$3

BENCHMARK_DIR="./humaneval_rust"
VENV_DIR="${BENCHMARK_DIR}/venv"

echo "Setting up HumanEval-Rust..."

[ ! -d "$BENCHMARK_DIR" ] && mkdir -p "$BENCHMARK_DIR"
cd "$BENCHMARK_DIR"

[ -d "$VENV_DIR" ] && rm -rf "$VENV_DIR"
python3 -m venv "$VENV_DIR"
source "$VENV_DIR/bin/activate"

echo "Installing dependencies..."
pip install --quiet --upgrade pip
export ARCHFLAGS="-arch arm64"
pip install --quiet --no-cache-dir --force-reinstall openai requests datasets urllib3==1.26.18
export PYTHONWARNINGS="ignore:urllib3 v2 only supports OpenSSL"

if ! command -v rustc &> /dev/null; then
    echo "Rust not found, installing..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source $HOME/.cargo/env
fi

cat > run_evaluation.py <<'PYTHON_SCRIPT'
import os, json, subprocess, tempfile, re
from openai import OpenAI
from datasets import load_dataset

MODEL_ENDPOINT = os.environ.get("MODEL_ENDPOINT")
MODEL_NAME = os.environ.get("MODEL_NAME")
RESULTS_DIR = os.environ.get("RESULTS_DIR")

client = OpenAI(base_url=f"{MODEL_ENDPOINT}/v1", api_key="sk-M_69wbwWPUCfaMRNloo67g")

def generate_rust_code(prompt: str) -> str:
    try:
        response = client.chat.completions.create(
            model=MODEL_NAME, messages=[{"role": "user", "content": prompt}],
            temperature=0.2, max_tokens=2048)
        code = response.choices[0].message.content.strip()
        code = re.sub(r'```rust\n?', '', code)
        code = re.sub(r'```\n?', '', code)
        code = re.sub(r'[→`]', '', code)
        code = re.sub(r'\*\*.*?\*\*', '', code)
        code = re.sub(r'Result:.*?$', '', code, flags=re.MULTILINE)
        code = re.sub(r'This function.*?$', '', code, flags=re.MULTILINE)

        lines = code.split('\n')
        func_lines, inside_function, brace_count = [], False, 0
        for line in lines:
            stripped = line.strip()
            if re.match(r'fn\s+\w+', stripped) and not inside_function:
                inside_function = True
                func_lines.append(line)
                brace_count += line.count('{') - line.count('}')
            elif inside_function:
                func_lines.append(line)
                brace_count += line.count('{') - line.count('}')
                if brace_count == 0: break

        if func_lines:
            func_code = '\n'.join(func_lines)
            lines = func_code.split('\n')
            for i in range(len(lines) - 1):
                current = lines[i].strip()
                next_line = lines[i + 1].strip()
                if (current and not current.endswith((';', '{', '}', ',')) and
                    not current.startswith('//') and next_line == '}'):
                    if not any(kw in current for kw in ['let ', 'if ', 'for ', 'while ', 'match ', 'return ']):
                        lines[i] = lines[i].replace(current, f"return {current};")
                    else:
                        lines[i] = lines[i].rstrip() + ';'
            return '\n'.join(lines).strip()

        match = re.search(r'fn\s+\w+[^{]*\{[^}]*\}', code, re.DOTALL)
        return match.group(0).strip() if match else code.strip()
    except Exception as e:
        print(f"Error generating code: {e}")
        return ""

def run_humaneval():
    print(f"Running HumanEval-Rust with model: {MODEL_NAME}")
    print(f"Endpoint: {MODEL_ENDPOINT}")
    print("Loading HumanEval-Rust dataset from HuggingFace...")
    
    dataset = load_dataset("nuprl/MultiPL-E", "humaneval-rs")
    problems_data = dataset["test"]
    print(f"Loaded {len(problems_data)} problems")

    problems = [{"name": item["name"], "prompt": item["prompt"], "tests": item["tests"]} for item in problems_data]
    results = []

    for i, problem in enumerate(problems):
        print(f"Processing problem {i+1}/{len(problems)}: {problem['name']}")
        generated_code = generate_rust_code(problem["prompt"])
        print(f"  Generated code ({len(generated_code)} chars)")

        with tempfile.NamedTemporaryFile(mode='w', suffix='.rs', delete=False) as f:
            f.write(generated_code + "\n\n")
            test_lines = [l for l in problem["tests"].split('\n') if not (l.strip() == '}' and not test_lines)]
            f.write('\n'.join(test_lines))
            test_file = f.name

        try:
            compile_result = subprocess.run(
                ["rustc", "--test", test_file, "-o", test_file.replace('.rs', '')],
                capture_output=True, timeout=30)
            if compile_result.returncode == 0:
                test_result = subprocess.run([test_file.replace('.rs', '')], capture_output=True, timeout=10)
                passed = test_result.returncode == 0
                if not passed: print(f"  Test failed: {test_result.stderr.decode()}")
            else:
                print(f"  Compilation failed: {compile_result.stderr.decode()}")
                passed = False
        except Exception as e:
            print(f"  Test failed: {e}")
            passed = False

        try:
            os.unlink(test_file)
            os.unlink(test_file.replace('.rs', ''))
        except: pass

        results.append({"problem_id": problem["name"], "passed": passed, "generated_code": generated_code})
        print(f"  Result: {'✓ PASS' if passed else '✗ FAIL'}")

    total = len(results)
    passed = sum(1 for r in results if r["passed"])
    pass_rate = (passed / total * 100) if total > 0 else 0

    metrics = {"benchmark": "humaneval-rust", "model": MODEL_NAME, "total_problems": total,
               "passed": passed, "pass_rate": pass_rate, "typical_baseline": 25.0}

    os.makedirs(RESULTS_DIR, exist_ok=True)
    with open(os.path.join(RESULTS_DIR, "results.json"), 'w') as f: json.dump(results, f, indent=2)
    with open(os.path.join(RESULTS_DIR, "metrics.json"), 'w') as f: json.dump(metrics, f, indent=2)

    print("\n" + "═"*50)
    print("  HUMANEVAL-RUST RESULTS")
    print("═"*50)
    print(f"  Model:     {MODEL_NAME}")
    print(f"  Tasks:     {passed}/{total} passed ({pass_rate:.1f}%)")
    print(f"  Baseline:  25.0%")
    print("═"*50)
    return metrics

if __name__ == "__main__":
    run_humaneval()
PYTHON_SCRIPT

export MODEL_ENDPOINT="$MODEL_ENDPOINT"
export MODEL_NAME="$MODEL_NAME"
export RESULTS_DIR="$RESULTS_DIR"

echo ""
echo "Starting HumanEval-Rust evaluation..."
python run_evaluation.py

deactivate
echo ""
echo "HumanEval-Rust evaluation complete!"
