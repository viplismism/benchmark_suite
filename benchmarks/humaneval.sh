#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config.env"
[ ! -f "$CONFIG_FILE" ] && echo "Error: Config file not found at $CONFIG_FILE" && exit 1
source "$CONFIG_FILE"

# Config defaults
HUMANEVAL_MODEL="${HUMANEVAL_MODEL:-${TERMINAL_BENCH_MODEL:-}}"
HUMANEVAL_LIMIT="${HUMANEVAL_LIMIT:-}"         # empty = all 161, or a number
PROXY_ENDPOINT="${MODEL_ENDPOINT:-http://localhost:8001}"
API_KEY="${LITELLM_PROXY_KEY:-sk-litellm-proxy-key-123}"

[ -z "$HUMANEVAL_MODEL" ] && echo "Error: HUMANEVAL_MODEL not set in config.env" && exit 1

# Timestamped results directory
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
HUMANEVAL_RESULTS_DIR="${SCRIPT_DIR}/../benchmark_results/humaneval/humaneval_${TIMESTAMP}_${HUMANEVAL_MODEL}"
mkdir -p "$HUMANEVAL_RESULTS_DIR"
HUMANEVAL_RESULTS_DIR=$(cd "$HUMANEVAL_RESULTS_DIR" && pwd)
BENCHMARK_DIR="${SCRIPT_DIR}/humaneval_rust"
VENV_DIR="${BENCHMARK_DIR}/venv"

echo "═══════════════════════════════════════════════════════════════════════"
echo "  HumanEval-Rust Evaluation"
echo "═══════════════════════════════════════════════════════════════════════"
echo "  Model:    $HUMANEVAL_MODEL"
if [ -n "$HUMANEVAL_LIMIT" ]; then
    echo "  Tasks:    $HUMANEVAL_LIMIT problems (limited)"
else
    echo "  Tasks:    161 problems"
fi
echo "  Results:  $HUMANEVAL_RESULTS_DIR"
echo "═══════════════════════════════════════════════════════════════════════"
echo ""

# ─── Python & Venv ────────────────────────────────────────────────────────────

find_python() {
    for cmd in python3.11 python3.10 python3.12 python3; do
        if command -v "$cmd" >/dev/null 2>&1; then
            local version=$($cmd -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null)
            local major=$(echo "$version" | cut -d. -f1)
            local minor=$(echo "$version" | cut -d. -f2)
            [ "$major" -ge 3 ] && [ "$minor" -ge 10 ] && echo "$cmd" && return 0
        fi
    done
    return 1
}

PYTHON_CMD=$(find_python) || { echo "Error: Python 3.10+ required"; exit 1; }

[ ! -d "$BENCHMARK_DIR" ] && mkdir -p "$BENCHMARK_DIR"

if [ ! -d "$VENV_DIR" ]; then
    echo "→ Creating virtual environment..."
    "$PYTHON_CMD" -m venv "$VENV_DIR"
fi
source "$VENV_DIR/bin/activate"

echo "→ Installing dependencies..."
pip install --quiet --upgrade pip

# Set ARCHFLAGS only on macOS ARM
if [[ "$OSTYPE" == "darwin"* ]] && [[ "$(uname -m)" == "arm64" ]]; then
    export ARCHFLAGS="-arch arm64"
fi

pip install --quiet openai requests datasets 2>/dev/null

# ─── Rust Check ───────────────────────────────────────────────────────────────

if ! command -v rustc &>/dev/null; then
    echo "→ Rust not found, installing..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"
fi
echo "  ✓ Rust $(rustc --version | awk '{print $2}')"

# ─── Run Evaluation ──────────────────────────────────────────────────────────

echo ""
echo "→ Running evaluation..."
echo ""

cat > "${HUMANEVAL_RESULTS_DIR}/run_evaluation.py" << 'PYTHON_SCRIPT'
import os, json, subprocess, tempfile, re
from openai import OpenAI
from datasets import load_dataset

MODEL_ENDPOINT = os.environ["PROXY_ENDPOINT"]
MODEL_NAME = os.environ["HUMANEVAL_MODEL"]
RESULTS_DIR = os.environ["HUMANEVAL_RESULTS_DIR"]
API_KEY = os.environ["API_KEY"]

client = OpenAI(base_url=f"{MODEL_ENDPOINT}/v1", api_key=API_KEY)

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
    print(f"Loading HumanEval-Rust dataset from HuggingFace...")
    dataset = load_dataset("nuprl/MultiPL-E", "humaneval-rs")
    problems_data = dataset["test"]
    print(f"Loaded {len(problems_data)} problems")

    problems = [{"name": item["name"], "prompt": item["prompt"], "tests": item["tests"]} for item in problems_data]

    limit = os.environ.get("HUMANEVAL_LIMIT", "")
    if limit:
        problems = problems[:int(limit)]
        print(f"Limited to {len(problems)} problems")
    results = []
    total_input_tokens = 0
    total_output_tokens = 0

    for i, problem in enumerate(problems):
        print(f"[{i+1}/{len(problems)}] {problem['name']}", end="")

        generated_code = generate_rust_code(problem["prompt"])

        with tempfile.NamedTemporaryFile(mode='w', suffix='.rs', delete=False) as f:
            f.write(generated_code + "\n\n")
            test_lines = [l for l in problem["tests"].split('\n')]
            f.write('\n'.join(test_lines))
            test_file = f.name

        passed = False
        try:
            compile_result = subprocess.run(
                ["rustc", "--test", test_file, "-o", test_file.replace('.rs', '')],
                capture_output=True, timeout=30)
            if compile_result.returncode == 0:
                test_result = subprocess.run([test_file.replace('.rs', '')], capture_output=True, timeout=10)
                passed = test_result.returncode == 0
        except Exception:
            pass

        try:
            os.unlink(test_file)
            os.unlink(test_file.replace('.rs', ''))
        except:
            pass

        results.append({"problem_id": problem["name"], "passed": passed, "generated_code": generated_code})
        print(f" {'✓' if passed else '✗'}")

    total = len(results)
    passed_count = sum(1 for r in results if r["passed"])
    pass_rate = (passed_count / total * 100) if total > 0 else 0

    summary = {
        "benchmark": "humaneval-rust",
        "timestamp": __import__("datetime").datetime.now().isoformat(),
        "model": MODEL_NAME,
        "results": {
            "total_problems": total,
            "passed": passed_count,
            "failed": total - passed_count,
            "accuracy": round(pass_rate, 2)
        }
    }

    with open(os.path.join(RESULTS_DIR, "results.json"), 'w') as f:
        json.dump(results, f, indent=2)
    with open(os.path.join(RESULTS_DIR, "summary.json"), 'w') as f:
        json.dump(summary, f, indent=2)

    print()
    print("═" * 70)
    print("  HUMANEVAL-RUST RESULTS")
    print("═" * 70)
    print(f"  Model:     {MODEL_NAME}")
    print(f"  Tasks:     {passed_count}/{total} passed ({pass_rate:.1f}%)")
    print(f"  Baseline:  25.0%")
    print("═" * 70)

if __name__ == "__main__":
    run_humaneval()
PYTHON_SCRIPT

export PROXY_ENDPOINT HUMANEVAL_MODEL HUMANEVAL_RESULTS_DIR API_KEY HUMANEVAL_LIMIT

python "${HUMANEVAL_RESULTS_DIR}/run_evaluation.py" 2>&1 | tee "${HUMANEVAL_RESULTS_DIR}/run.log"
EXIT_CODE=${PIPESTATUS[0]}

# Cleanup temp script
rm -f "${HUMANEVAL_RESULTS_DIR}/run_evaluation.py"

deactivate

echo ""
[ $EXIT_CODE -eq 0 ] && echo "✓ HumanEval-Rust evaluation completed successfully" || echo "✗ HumanEval-Rust evaluation failed (exit code: $EXIT_CODE)"
echo "  Results: $HUMANEVAL_RESULTS_DIR"
echo ""

exit $EXIT_CODE
