#!/bin/bash

# tau-Bench Production Evaluation Script
# Production-grade implementation for tau-bench evaluation

set -e

CONFIG_FILE="../config.env"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Config file not found at $CONFIG_FILE"
    echo "Required variables: MODEL_NAME, MODEL_ENDPOINT, GRID_API_KEY"
    exit 1
fi

echo "Loading configuration from: $CONFIG_FILE"
source "$CONFIG_FILE"

if [ -z "$MODEL_NAME" ] || [ -z "$MODEL_ENDPOINT" ] || [ -z "$GRID_API_KEY" ]; then
    echo "Error: Missing required configuration variables"
    exit 1
fi

# Configuration
TAU_BENCH_DOMAIN="${TAU_BENCH_DOMAIN:-retail}"
TAU_BENCH_TASKS="${TAU_BENCH_TASKS:-0 1 2 3 4}"
TAU_BENCH_MAX_CONCURRENCY="${TAU_BENCH_MAX_CONCURRENCY:-4}"
TAU_BENCH_AGENT_MODEL="${TAU_BENCH_AGENT_MODEL:-$MODEL_NAME}"
TAU_BENCH_USER_MODEL="${TAU_BENCH_USER_MODEL:-$MODEL_NAME}"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
TAU_BENCH_RESULTS_DIR="${RESULTS_DIR}/tau_bench/tau_bench_${TIMESTAMP}"

mkdir -p "$TAU_BENCH_RESULTS_DIR"
TAU_BENCH_RESULTS_DIR=$(cd "$TAU_BENCH_RESULTS_DIR" && pwd)

BENCHMARK_DIR="./tau_bench"
VENV_DIR="${BENCHMARK_DIR}/venv"

echo "=========================================="
echo "tau-Bench Configuration"
echo "=========================================="
echo "Agent Model: $TAU_BENCH_AGENT_MODEL"
echo "Agent Endpoint: $MODEL_ENDPOINT"
echo "User Simulator: $TAU_BENCH_USER_MODEL"
echo "Domain: $TAU_BENCH_DOMAIN"
echo "Tasks: $TAU_BENCH_TASKS"
echo "Concurrency: $TAU_BENCH_MAX_CONCURRENCY"
echo "Results Dir: $TAU_BENCH_RESULTS_DIR"
echo "=========================================="
echo ""

# Setup repository
if [ ! -d "$BENCHMARK_DIR" ]; then
    echo "Cloning tau-Bench repository..."
    git clone https://github.com/sierra-research/tau-bench.git "$BENCHMARK_DIR"
    cd "$BENCHMARK_DIR"
else
    echo "Using existing tau-Bench repository..."
    cd "$BENCHMARK_DIR"
    git pull origin main || true
fi

# Python version check with better diagnostics
find_python() {
    for cmd in python3.11 python3.10 python3.12 python3; do
        if command -v "$cmd" >/dev/null 2>&1; then
            local version=$($cmd -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null)
            if [ $? -eq 0 ]; then
                local major=$(echo "$version" | cut -d. -f1)
                local minor=$(echo "$version" | cut -d. -f2)
                if [ "$major" -ge 3 ] && [ "$minor" -ge 10 ]; then
                    echo "$cmd"
                    return 0
                fi
            fi
        fi
    done
    return 1
}

if ! PYTHON_CMD=$(find_python); then
    echo "Error: Python 3.10+ required"
    echo "Available Python versions:"
    for cmd in python3 python3.8 python3.9 python3.10 python3.11 python3.12; do
        if command -v "$cmd" >/dev/null 2>&1; then
            echo "  $cmd: $($cmd --version 2>/dev/null || echo "unknown")"
        fi
    done
    exit 1
fi

echo "Using Python: $PYTHON_CMD ($($PYTHON_CMD --version))"

# Virtual environment setup
if [ ! -d "$VENV_DIR" ]; then
    echo "Creating virtual environment..."
    "$PYTHON_CMD" -m venv "$VENV_DIR"
fi

source "$VENV_DIR/bin/activate"

# Install dependencies
echo "Installing dependencies..."
pip install --quiet --upgrade pip
pip install --quiet -e .
pip install --quiet openai python-dotenv tiktoken >/dev/null 2>&1

# Environment setup
export MODEL_ENDPOINT="$MODEL_ENDPOINT"
export MODEL_NAME="$MODEL_NAME"
export TAU_BENCH_RESULTS_DIR="$TAU_BENCH_RESULTS_DIR"
export OPENAI_API_KEY="$GRID_API_KEY"
export OPENAI_API_BASE="$MODEL_ENDPOINT/v1"
export TAU_BENCH_DOMAIN="$TAU_BENCH_DOMAIN"
export TAU_BENCH_TASKS="$TAU_BENCH_TASKS"
export TAU_BENCH_MAX_CONCURRENCY="$TAU_BENCH_MAX_CONCURRENCY"
export TAU_BENCH_AGENT_MODEL="$TAU_BENCH_AGENT_MODEL"
export TAU_BENCH_USER_MODEL="$TAU_BENCH_USER_MODEL"

echo ""
echo "Model configuration:"
echo "  Agent: $TAU_BENCH_AGENT_MODEL (model being tested)"
echo "  User: $TAU_BENCH_USER_MODEL (simulates user behavior)"
echo ""

# Create Python runner
cat > run_tau.py << 'EOF'
#!/usr/bin/env python3
"""Professional tau-Bench evaluation runner."""

import subprocess
import sys
import time
import re
import os
import json
from datetime import datetime
from typing import Dict, Set, Optional, Tuple

class TauBenchRunner:
    """Professional tau-bench evaluation manager."""

    def __init__(self):
        """Initialize runner with environment configuration."""
        self.tasks = os.environ.get("TAU_BENCH_TASKS", "0 1 2 3 4").split()
        self.total_tasks = len(self.tasks)
        self.agent_model = os.environ.get('TAU_BENCH_AGENT_MODEL')
        self.user_model = os.environ.get('TAU_BENCH_USER_MODEL')
        self.results_dir = os.environ.get("TAU_BENCH_RESULTS_DIR", "./results")

        # Task tracking state
        self.active_tasks: Set[str] = set()
        self.completed_tasks: Set[str] = set()
        self.task_start_times: Dict[str, float] = {}
        self.task_results: Dict[str, str] = {}

        # Token estimation using tiktoken - separate user vs agent models
        self.task_tokens: Dict[str, Dict[str, int]] = {}
        self.total_tokens = {
            "agent_input": 0, "agent_output": 0,
            "user_input": 0, "user_output": 0
        }

    def _log(self, message: str, level: str = "INFO") -> None:
        """Thread-safe logging with timestamps."""
        timestamp = datetime.now().strftime("%H:%M:%S")
        print(f"[{timestamp}] {message}", flush=True)
        
    def _build_command(self) -> list:
        """Build tau-bench execution command."""
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

    def _parse_task_start(self, line: str) -> Optional[str]:
        """Extract task ID from task start line."""
        match = re.search(r'Running task (\d+)', line)
        return match.group(1) if match else None

    def _parse_task_completion(self, line: str) -> Optional[Tuple[str, str]]:
        """Extract task ID and result from completion line."""
        match = re.search(r'task_id=(\d+)', line)
        if not match:
            return None

        task_id = match.group(1)
        if "'reward': 1.0" in line or "'reward': 1" in line:
            return (task_id, "passed")
        elif "'reward': 0.0" in line or "'reward': 0" in line:
            return (task_id, "failed")
        return None

    def _format_active_tasks(self) -> str:
        """Format active tasks for display."""
        if not self.active_tasks:
            return ""
        tasks = ', '.join(sorted(self.active_tasks))
        return f" | Active: [{tasks}] ({len(self.active_tasks)})"
        
    def run_evaluation(self) -> int:
        """Execute tau-bench evaluation with real-time progress tracking."""
        self._log(f"Starting evaluation: {', '.join(self.tasks)} ({self.total_tasks} tasks)")
        self._log(f"Agent: {self.agent_model} | User: {self.user_model}")
        self._log(f"Concurrency: {os.environ.get('TAU_BENCH_MAX_CONCURRENCY', '4')}")
        print("-" * 80)

        cmd = self._build_command()
        env = os.environ.copy()
        env['PYTHONUNBUFFERED'] = '1'

        process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            universal_newlines=True,
            bufsize=0,
            env=env
        )

        log_file = os.path.join(self.results_dir, "run.log")

        with open(log_file, 'w') as log:
            for line in iter(process.stdout.readline, ''):
                if not line:
                    continue

                log.write(line)
                log.flush()

                stripped = line.strip()
                if not stripped:
                    continue

                self._process_output_line(stripped)

        process.wait()
        return process.returncode

    def _process_output_line(self, line: str) -> None:
        """Process a single line of tau-bench output."""
        # Track task starts
        task_id = self._parse_task_start(line)
        if task_id and task_id not in self.active_tasks:
            self.active_tasks.add(task_id)
            self.task_start_times[task_id] = time.time()
            progress = f"{len(self.completed_tasks) + len(self.active_tasks)}/{self.total_tasks}"
            self._log(f"Task {task_id} STARTED [{progress}]{self._format_active_tasks()}")

        # Track completions
        completion = self._parse_task_completion(line)
        if completion:
            task_id, status = completion

            if task_id not in self.completed_tasks:
                self.completed_tasks.add(task_id)
                self.active_tasks.discard(task_id)
                self.task_results[task_id] = status

                duration = time.time() - self.task_start_times.get(task_id, time.time())
                progress = f"{len(self.completed_tasks)}/{self.total_tasks}"
                self._log(f"Task {task_id} {status.upper()} [{progress}] ({duration:.1f}s){self._format_active_tasks()}")

                if len(self.completed_tasks) == self.total_tasks:
                    self._log("Evaluation completed")

    def _extract_tokens_from_result_files(self) -> None:
        """Extract token usage from tau-bench result files using actual conversation data."""
        import glob
        import json
        import tiktoken

        # Get tiktoken encoder
        try:
            enc = tiktoken.get_encoding("cl100k_base")
        except:
            return  # Skip if tiktoken not available

        # Look for tau-bench JSON result files
        pattern = os.path.join(self.results_dir, "*.json")
        for filepath in glob.glob(pattern):
            if "evaluation_results" in filepath:
                continue  # Skip our own results file

            try:
                with open(filepath, 'r') as f:
                    data = json.load(f)

                if isinstance(data, list):
                    for task_data in data:
                        if isinstance(task_data, dict) and 'task_id' in task_data:
                            task_id = str(task_data['task_id'])

                            # Extract token counts from conversation trajectory
                            if 'traj' in task_data:
                                # Get task instruction if available
                                task_instruction = None
                                if 'task' in task_data and 'instruction' in task_data['task']:
                                    task_instruction = task_data['task']['instruction']

                                agent_input, agent_output, user_input, user_output = self._count_tokens_from_trajectory(
                                    task_data['traj'], enc, task_instruction
                                )

                                if agent_input > 0 or agent_output > 0 or user_input > 0 or user_output > 0:
                                    if task_id not in self.task_tokens:
                                        self.task_tokens[task_id] = {
                                            "agent_input": 0, "agent_output": 0,
                                            "user_input": 0, "user_output": 0
                                        }

                                    self.task_tokens[task_id]["agent_input"] += agent_input
                                    self.task_tokens[task_id]["agent_output"] += agent_output
                                    self.task_tokens[task_id]["user_input"] += user_input
                                    self.task_tokens[task_id]["user_output"] += user_output

                                    self.total_tokens["agent_input"] += agent_input
                                    self.total_tokens["agent_output"] += agent_output
                                    self.total_tokens["user_input"] += user_input
                                    self.total_tokens["user_output"] += user_output

            except Exception:
                continue  # Skip files that can't be parsed

    def _count_tokens_from_trajectory(self, traj: list, enc, task_instruction: str = None) -> tuple:
        """Count tokens from conversation trajectory, separating agent and user simulator."""
        agent_input_tokens = 0
        agent_output_tokens = 0
        user_input_tokens = 0
        user_output_tokens = 0

        # Count the initial instruction as user model input
        if task_instruction:
            user_input_tokens += len(enc.encode(task_instruction))

        for i, message in enumerate(traj):
            if isinstance(message, dict) and 'content' in message:
                content = str(message['content'])
                role = message.get('role', '')

                if role == 'system':
                    # System messages are input to agent model
                    agent_input_tokens += len(enc.encode(content))
                elif role == 'user':
                    # User messages are output from user simulator
                    user_output_tokens += len(enc.encode(content))
                    # User messages also become input to agent model
                    agent_input_tokens += len(enc.encode(content))

                    # User simulator input: conversation history up to this point
                    for prev_msg in traj[:i]:
                        if isinstance(prev_msg, dict) and 'content' in prev_msg:
                            user_input_tokens += len(enc.encode(str(prev_msg['content'])))
                elif role == 'assistant':
                    # Assistant messages are output from agent model
                    agent_output_tokens += len(enc.encode(content))

                    # Also count tool calls as agent output
                    if 'tool_calls' in message and message['tool_calls']:
                        for tool_call in message['tool_calls']:
                            if isinstance(tool_call, dict):
                                agent_output_tokens += len(enc.encode(str(tool_call)))
                elif role == 'tool':
                    # Tool results are input to agent model
                    agent_input_tokens += len(enc.encode(content))

        return agent_input_tokens, agent_output_tokens, user_input_tokens, user_output_tokens
        
    def save_results(self, exit_code: int) -> None:
        """Save evaluation results to JSON file."""
        # Extract tokens from tau-bench result files
        self._extract_tokens_from_result_files()

        passed = sum(1 for r in self.task_results.values() if r == "passed")
        failed = sum(1 for r in self.task_results.values() if r == "failed")

        agent_input = self.total_tokens["agent_input"]
        agent_output = self.total_tokens["agent_output"]
        user_input = self.total_tokens["user_input"]
        user_output = self.total_tokens["user_output"]

        total_agent = agent_input + agent_output
        total_user = user_input + user_output
        total_tokens = total_agent + total_user

        results = {
            "agent_model": self.agent_model,
            "user_model": self.user_model,
            "domain": os.environ.get("TAU_BENCH_DOMAIN", "retail"),
            "total_tasks": self.total_tasks,
            "exit_code": exit_code,
            "task_results": self.task_results,
            "summary": {
                "passed": passed,
                "failed": failed,
                "pass_rate": (passed / self.total_tasks * 100) if self.total_tasks > 0 else 0
            },
            "token_usage": {
                "agent_model": {
                    "input_tokens": agent_input,
                    "output_tokens": agent_output,
                    "total_tokens": total_agent
                },
                "user_model": {
                    "input_tokens": user_input,
                    "output_tokens": user_output,
                    "total_tokens": total_user
                },
                "combined": {
                    "total_tokens": total_tokens,
                    "average_tokens_per_task": total_tokens / self.total_tasks if self.total_tasks > 0 else 0
                },
                "estimation_method": "tiktoken",
                "by_task": {
                    task_id: {
                        "agent": {
                            "input_tokens": tokens["agent_input"],
                            "output_tokens": tokens["agent_output"],
                            "total_tokens": tokens["agent_input"] + tokens["agent_output"]
                        },
                        "user": {
                            "input_tokens": tokens["user_input"],
                            "output_tokens": tokens["user_output"],
                            "total_tokens": tokens["user_input"] + tokens["user_output"]
                        }
                    }
                    for task_id, tokens in self.task_tokens.items()
                }
            }
        }

        results_file = os.path.join(self.results_dir, "evaluation_results.json")
        with open(results_file, 'w') as f:
            json.dump(results, f, indent=2)

        self._log(f"Results saved: {results_file}")

    def print_summary(self) -> None:
        """Print evaluation summary to console."""
        print("\n" + "=" * 80)
        print("EVALUATION SUMMARY")
        print("=" * 80)

        passed = sum(1 for r in self.task_results.values() if r == "passed")
        failed = sum(1 for r in self.task_results.values() if r == "failed")
        pass_rate = (passed / self.total_tasks * 100) if self.total_tasks > 0 else 0

        print(f"Tasks completed: {len(self.completed_tasks)}/{self.total_tasks}")
        print(f"Passed: {passed}")
        print(f"Failed: {failed}")
        print(f"Pass rate: {pass_rate:.1f}%")
        print()

        if self.task_results:
            print("Task breakdown:")
            for task_id in sorted(self.task_results.keys(), key=int):
                status = self.task_results[task_id].upper()
                print(f"  Task {task_id}: {status}")

        # Token usage summary
        agent_input = self.total_tokens["agent_input"]
        agent_output = self.total_tokens["agent_output"]
        user_input = self.total_tokens["user_input"]
        user_output = self.total_tokens["user_output"]

        total_agent = agent_input + agent_output
        total_user = user_input + user_output
        total_tokens = total_agent + total_user

        if total_tokens > 0:
            print()
            print(f"Token usage (from conversation trajectories):")
            print(f"  Agent model ({self.agent_model}):")
            print(f"    Input:  {agent_input:,}")
            print(f"    Output: {agent_output:,}")
            print(f"    Total:  {total_agent:,}")
            print(f"  User simulator ({self.user_model}):")
            print(f"    Input:  {user_input:,}")
            print(f"    Output: {user_output:,}")
            print(f"    Total:  {total_user:,}")
            print(f"  Combined total: {total_tokens:,}")
            print(f"  Avg per task:   {total_tokens // self.total_tasks:,}")

        print("=" * 80)


def main() -> int:
    """Main entry point for tau-bench evaluation."""
    try:
        runner = TauBenchRunner()
        exit_code = runner.run_evaluation()
        runner.save_results(exit_code)
        runner.print_summary()
        return exit_code

    except KeyboardInterrupt:
        print("\n[INTERRUPTED] Evaluation cancelled by user", file=sys.stderr)
        return 130
    except Exception as e:
        print(f"\n[ERROR] Evaluation failed: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
EOF

# Execute evaluation
echo ""
echo "=========================================="
echo "Starting τ-Bench Evaluation"
echo "=========================================="
echo ""

python run_tau.py
EXIT_CODE=$?

# Cleanup
deactivate
rm -f run_tau.py

# Final report
echo ""
if [ $EXIT_CODE -eq 0 ]; then
    echo "✓ Evaluation completed successfully"
else
    echo "✗ Evaluation failed (exit code: $EXIT_CODE)"
fi

echo ""
echo "Results directory: $TAU_BENCH_RESULTS_DIR"
echo "Review files:"
echo "  - Full logs: run.log"
echo "  - Results: evaluation_results.json"

exit $EXIT_CODE