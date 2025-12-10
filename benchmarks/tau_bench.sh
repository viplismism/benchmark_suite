#!/bin/bash
# =============================================================================
# τ-Bench Evaluation Script
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config.env"

# Load configuration
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Config file not found at $CONFIG_FILE"
    exit 1
fi
source "$CONFIG_FILE"

# Configuration with defaults
TAU_BENCH_DOMAIN="${TAU_BENCH_DOMAIN:-retail}"
TAU_BENCH_TASKS="${TAU_BENCH_TASKS:-0 1 2 3 4}"
TAU_BENCH_MAX_CONCURRENCY="${TAU_BENCH_MAX_CONCURRENCY:-4}"
TAU_BENCH_AGENT_MODEL="${TAU_BENCH_AGENT_MODEL:-$MODEL_NAME}"
TAU_BENCH_USER_MODEL="${TAU_BENCH_USER_MODEL:-gpt-4o}"

# Expand "all" tasks
if [ "$TAU_BENCH_TASKS" = "all" ]; then
    if [ "$TAU_BENCH_DOMAIN" = "retail" ]; then
        TAU_BENCH_TASKS=$(seq 0 114 | tr '\n' ' ')
    elif [ "$TAU_BENCH_DOMAIN" = "airline" ]; then
        TAU_BENCH_TASKS=$(seq 0 49 | tr '\n' ' ')
    fi
fi

# Setup results directory
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
TAU_BENCH_RESULTS_DIR="${SCRIPT_DIR}/../benchmark_results/tau_bench/tau_bench_${TIMESTAMP}"
mkdir -p "$TAU_BENCH_RESULTS_DIR"
TAU_BENCH_RESULTS_DIR=$(cd "$TAU_BENCH_RESULTS_DIR" && pwd)

BENCHMARK_DIR="${SCRIPT_DIR}/tau_bench"
VENV_DIR="${BENCHMARK_DIR}/venv"

# Print configuration
echo "═══════════════════════════════════════════════════════════════════════"
echo "  τ-Bench Evaluation"
echo "═══════════════════════════════════════════════════════════════════════"
echo "  Agent Model:  $TAU_BENCH_AGENT_MODEL"
echo "  User Model:   $TAU_BENCH_USER_MODEL"
echo "  Domain:       $TAU_BENCH_DOMAIN"
echo "  Tasks:        $(echo $TAU_BENCH_TASKS | wc -w | tr -d ' ')"
echo "  Concurrency:  $TAU_BENCH_MAX_CONCURRENCY"
echo "  Results:      $TAU_BENCH_RESULTS_DIR"
echo "═══════════════════════════════════════════════════════════════════════"
echo ""

# Setup repository
if [ ! -d "$BENCHMARK_DIR" ]; then
    echo "→ Cloning tau-bench repository..."
    git clone --quiet https://github.com/sierra-research/tau-bench.git "$BENCHMARK_DIR"
fi
cd "$BENCHMARK_DIR"

# Find Python 3.10+
find_python() {
    for cmd in python3.11 python3.10 python3.12 python3; do
        if command -v "$cmd" >/dev/null 2>&1; then
            local version=$($cmd -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null)
            local major=$(echo "$version" | cut -d. -f1)
            local minor=$(echo "$version" | cut -d. -f2)
            if [ "$major" -ge 3 ] && [ "$minor" -ge 10 ]; then
                echo "$cmd"
                return 0
            fi
        fi
    done
    return 1
}

PYTHON_CMD=$(find_python) || { echo "Error: Python 3.10+ required"; exit 1; }

# Setup virtual environment
if [ ! -d "$VENV_DIR" ]; then
    echo "→ Creating virtual environment..."
    "$PYTHON_CMD" -m venv "$VENV_DIR"
fi
source "$VENV_DIR/bin/activate"

# Install dependencies quietly
echo "→ Installing dependencies..."
pip install --quiet --upgrade pip
pip install --quiet -e . 2>/dev/null
pip install --quiet openai python-dotenv tiktoken 2>/dev/null

# Setup environment
export OPENAI_API_KEY="${LITELLM_PROXY_KEY:-sk-litellm-proxy-key-123}"
export OPENAI_BASE_URL="${MODEL_ENDPOINT}/v1"
export TAU_BENCH_RESULTS_DIR TAU_BENCH_DOMAIN TAU_BENCH_TASKS
export TAU_BENCH_MAX_CONCURRENCY TAU_BENCH_AGENT_MODEL TAU_BENCH_USER_MODEL

# Create runner script
cat > run_tau.py << 'PYTHON_EOF'
#!/usr/bin/env python3
"""τ-Bench evaluation runner."""

import subprocess
import sys
import time
import re
import os
import json
import glob
from datetime import datetime
from typing import Dict, Set, Optional, Tuple

class TauBenchRunner:
    def __init__(self):
        self.tasks = os.environ.get("TAU_BENCH_TASKS", "0 1 2 3 4").split()
        self.total_tasks = len(self.tasks)
        self.agent_model = os.environ.get('TAU_BENCH_AGENT_MODEL')
        self.user_model = os.environ.get('TAU_BENCH_USER_MODEL')
        self.results_dir = os.environ.get("TAU_BENCH_RESULTS_DIR", "./results")
        self.active_tasks: Set[str] = set()
        self.completed_tasks: Set[str] = set()
        self.task_start_times: Dict[str, float] = {}
        self.task_results: Dict[str, str] = {}
        self.task_tokens: Dict[str, Dict[str, int]] = {}
        self.total_tokens = {"agent_input": 0, "agent_output": 0, "user_input": 0, "user_output": 0}

    def _log(self, message: str) -> None:
        print(f"[{datetime.now().strftime('%H:%M:%S')}] {message}", flush=True)

    def _build_command(self) -> list:
        return [
            "python", "run.py",
            "--agent-strategy", "tool-calling",
            "--env", os.environ.get("TAU_BENCH_DOMAIN", "retail"),
            "--model", self.agent_model,
            "--model-provider", "openai",
            "--user-model", self.user_model,
            "--user-model-provider", "openai",
            "--user-strategy", "llm",
            "--task-ids", *self.tasks,
            "--max-concurrency", os.environ.get("TAU_BENCH_MAX_CONCURRENCY", "4"),
            "--log-dir", self.results_dir
        ]

    def run_evaluation(self) -> int:
        self._log(f"Starting evaluation: {self.total_tasks} tasks")
        print("-" * 70)
        
        cmd = self._build_command()
        env = os.environ.copy()
        env['PYTHONUNBUFFERED'] = '1'
        
        process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   universal_newlines=True, bufsize=0, env=env)
        
        log_file = os.path.join(self.results_dir, "run.log")
        with open(log_file, 'w') as log:
            for line in iter(process.stdout.readline, ''):
                if not line:
                    continue
                log.write(line)
                log.flush()
                self._process_line(line.strip())
        
        process.wait()
        return process.returncode

    def _process_line(self, line: str) -> None:
        # Track task starts
        match = re.search(r'Running task (\d+)', line)
        if match:
            task_id = match.group(1)
            if task_id not in self.active_tasks:
                self.active_tasks.add(task_id)
                self.task_start_times[task_id] = time.time()
                progress = f"{len(self.completed_tasks) + len(self.active_tasks)}/{self.total_tasks}"
                self._log(f"Task {task_id} STARTED [{progress}]")
        
        # Track completions
        match = re.search(r'task_id=(\d+)', line)
        if match:
            task_id = match.group(1)
            if task_id not in self.completed_tasks:
                status = "passed" if "'reward': 1" in line else "failed"
                self.completed_tasks.add(task_id)
                self.active_tasks.discard(task_id)
                self.task_results[task_id] = status
                duration = time.time() - self.task_start_times.get(task_id, time.time())
                progress = f"{len(self.completed_tasks)}/{self.total_tasks}"
                self._log(f"Task {task_id} {status.upper()} [{progress}] ({duration:.1f}s)")

    def _extract_tokens(self) -> None:
        try:
            import tiktoken
            enc = tiktoken.get_encoding("cl100k_base")
        except:
            return
        
        for filepath in glob.glob(os.path.join(self.results_dir, "*.json")):
            if "evaluation_results" in filepath:
                continue
            try:
                with open(filepath) as f:
                    data = json.load(f)
                if isinstance(data, list):
                    for task_data in data:
                        if 'task_id' in task_data and 'traj' in task_data:
                            task_id = str(task_data['task_id'])
                            tokens = self._count_tokens(task_data['traj'], enc)
                            if any(tokens):
                                self.task_tokens[task_id] = dict(zip(
                                    ["agent_input", "agent_output", "user_input", "user_output"], tokens))
                                for k, v in self.task_tokens[task_id].items():
                                    self.total_tokens[k] += v
            except:
                continue

    def _count_tokens(self, traj: list, enc) -> tuple:
        ai, ao, ui, uo = 0, 0, 0, 0
        for msg in traj:
            if not isinstance(msg, dict) or 'content' not in msg:
                continue
            tokens = len(enc.encode(str(msg['content'])))
            role = msg.get('role', '')
            if role == 'system':
                ai += tokens
            elif role == 'user':
                uo += tokens
                ai += tokens
            elif role == 'assistant':
                ao += tokens
            elif role == 'tool':
                ai += tokens
        return ai, ao, ui, uo

    def save_results(self, exit_code: int) -> None:
        self._extract_tokens()
        passed = sum(1 for r in self.task_results.values() if r == "passed")
        failed = sum(1 for r in self.task_results.values() if r == "failed")
        
        results = {
            "benchmark": "tau-bench",
            "timestamp": datetime.now().isoformat(),
            "agent_model": self.agent_model,
            "user_model": self.user_model,
            "domain": os.environ.get("TAU_BENCH_DOMAIN", "retail"),
            "results": {
                "total_tasks": self.total_tasks,
                "passed": passed,
                "failed": failed,
                "pass_rate": round(passed / self.total_tasks * 100, 2) if self.total_tasks > 0 else 0
            },
            "token_usage": {
                "agent": {"input": self.total_tokens["agent_input"], "output": self.total_tokens["agent_output"]},
                "user": {"input": self.total_tokens["user_input"], "output": self.total_tokens["user_output"]},
                "total": sum(self.total_tokens.values())
            },
            "task_results": self.task_results
        }
        
        with open(os.path.join(self.results_dir, "evaluation_results.json"), 'w') as f:
            json.dump(results, f, indent=2)

    def print_summary(self) -> None:
        passed = sum(1 for r in self.task_results.values() if r == "passed")
        failed = sum(1 for r in self.task_results.values() if r == "failed")
        pass_rate = passed / self.total_tasks * 100 if self.total_tasks > 0 else 0
        total_tokens = sum(self.total_tokens.values())
        
        print("\n" + "═" * 70)
        print("  τ-BENCH RESULTS")
        print("═" * 70)
        print(f"  Model:     {self.agent_model}")
        print(f"  Tasks:     {passed}/{self.total_tasks} passed ({pass_rate:.1f}%)")
        print(f"  Tokens:    {total_tokens:,}")
        print("═" * 70)

def main() -> int:
    try:
        runner = TauBenchRunner()
        exit_code = runner.run_evaluation()
        runner.save_results(exit_code)
        runner.print_summary()
        return exit_code
    except KeyboardInterrupt:
        print("\n[INTERRUPTED] Evaluation cancelled")
        return 130
    except Exception as e:
        print(f"\n[ERROR] {e}")
        return 1

if __name__ == "__main__":
    sys.exit(main())
PYTHON_EOF

# Run evaluation
echo ""
echo "→ Starting evaluation..."
echo ""

python run_tau.py
EXIT_CODE=$?

# Cleanup
deactivate
rm -f run_tau.py

echo ""
if [ $EXIT_CODE -eq 0 ]; then
    echo "✓ Evaluation completed successfully"
else
    echo "✗ Evaluation failed (exit code: $EXIT_CODE)"
fi
echo "  Results: $TAU_BENCH_RESULTS_DIR"
echo ""

exit $EXIT_CODE