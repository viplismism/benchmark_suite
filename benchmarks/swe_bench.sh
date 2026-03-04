#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config.env"
[ ! -f "$CONFIG_FILE" ] && echo "Error: Config file not found at $CONFIG_FILE" && exit 1
source "$CONFIG_FILE"

# Config defaults
SWE_BENCH_MODEL="${SWE_BENCH_MODEL:-${TERMINAL_BENCH_MODEL:-}}"
SWE_BENCH_DATASET="${SWE_BENCH_DATASET:-princeton-nlp/SWE-bench_Verified}"
SWE_BENCH_MAX_WORKERS="${SWE_BENCH_MAX_WORKERS:-4}"
SWE_BENCH_INSTANCE_LIMIT="${SWE_BENCH_INSTANCE_LIMIT:-}"
SWE_BENCH_INSTANCE_IDS="${SWE_BENCH_INSTANCE_IDS:-}"
SWE_BENCH_TIMEOUT="${SWE_BENCH_TIMEOUT:-1800}"
SWE_BENCH_AGENT="${SWE_BENCH_AGENT:-simple}"
PROXY_ENDPOINT="${MODEL_ENDPOINT:-http://localhost:8001}"
API_KEY="${LITELLM_PROXY_KEY:-sk-litellm-proxy-key-123}"

[ -z "$SWE_BENCH_MODEL" ] && echo "Error: SWE_BENCH_MODEL not set in config.env" && exit 1

# Timestamped results directory
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
SWE_BENCH_RESULTS_DIR="${SCRIPT_DIR}/../benchmark_results/swe_bench/swe_bench_${TIMESTAMP}_${SWE_BENCH_MODEL}"
mkdir -p "$SWE_BENCH_RESULTS_DIR"
SWE_BENCH_RESULTS_DIR=$(cd "$SWE_BENCH_RESULTS_DIR" && pwd)
RUN_ID="swe_bench_${TIMESTAMP}"
BENCHMARK_DIR="${SCRIPT_DIR}/../.cache/swe_bench"
VENV_DIR="${BENCHMARK_DIR}/venv"

echo "═══════════════════════════════════════════════════════════════════════"
echo "  SWE-bench Verified Evaluation"
echo "═══════════════════════════════════════════════════════════════════════"
echo "  Model:        $SWE_BENCH_MODEL"
echo "  Dataset:      $SWE_BENCH_DATASET"
echo "  Agent:        $SWE_BENCH_AGENT"
echo "  Max Workers:  $SWE_BENCH_MAX_WORKERS"
echo "  Timeout:      ${SWE_BENCH_TIMEOUT}s per instance"
if [ -n "$SWE_BENCH_INSTANCE_IDS" ]; then
    echo "  Instances:    $SWE_BENCH_INSTANCE_IDS"
elif [ -n "$SWE_BENCH_INSTANCE_LIMIT" ]; then
    echo "  Limit:        $SWE_BENCH_INSTANCE_LIMIT instances"
else
    echo "  Instances:    all (500)"
fi
echo "  Results:      $SWE_BENCH_RESULTS_DIR"
echo "═══════════════════════════════════════════════════════════════════════"
echo ""

# ─── Prerequisites ────────────────────────────────────────────────────────────

echo "→ Checking prerequisites..."

# Docker check
docker info &>/dev/null || { echo "Error: Docker is not running. SWE-bench requires Docker for evaluation."; exit 1; }

# Detect Docker socket for Python docker SDK (OrbStack, Colima, etc.)
if [ -z "$DOCKER_HOST" ]; then
    DOCKER_SOCK=$(docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null || true)
    if [ -n "$DOCKER_SOCK" ]; then
        export DOCKER_HOST="$DOCKER_SOCK"
        echo "  ✓ Docker is running (socket: $DOCKER_HOST)"
    else
        echo "  ✓ Docker is running"
    fi
else
    echo "  ✓ Docker is running (DOCKER_HOST: $DOCKER_HOST)"
fi

# Disk space warning
if [[ "$OSTYPE" == "darwin"* ]]; then
    FREE_GB=$(df -g / | awk 'NR==2 {print $4}')
else
    FREE_GB=$(df -BG / | awk 'NR==2 {print $4}' | tr -d 'G')
fi
if [ "$FREE_GB" -lt 120 ] 2>/dev/null; then
    echo "  ⚠ Warning: Only ${FREE_GB}GB free disk space. SWE-bench may need 120GB+ for Docker images."
fi

# ARM/macOS detection for --namespace flag
NAMESPACE_FLAG=""
ARCH=$(uname -m)
if [[ "$ARCH" == "arm64" || "$ARCH" == "aarch64" ]]; then
    NAMESPACE_FLAG="--namespace ''"
    echo "  ✓ ARM architecture detected — will use --namespace ''"
fi

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

if [ ! -d "$BENCHMARK_DIR" ]; then
    mkdir -p "$BENCHMARK_DIR"
fi

if [ ! -d "$VENV_DIR" ]; then
    echo "→ Creating virtual environment..."
    "$PYTHON_CMD" -m venv "$VENV_DIR"
fi
source "$VENV_DIR/bin/activate"

echo "→ Installing dependencies..."
pip install --quiet --upgrade pip
pip install --quiet swebench openai datasets 2>/dev/null

# ─── Signal handling ──────────────────────────────────────────────────────────

cleanup() {
    echo ""
    echo "→ Cleaning up..."
    [ -n "$INFERENCE_PID" ] && kill -0 "$INFERENCE_PID" 2>/dev/null && kill -TERM "$INFERENCE_PID" 2>/dev/null
    echo "✓ Cleanup complete"
}

handle_interrupt() {
    echo ""
    echo "⚠ Interrupted! Stopping SWE-bench..."
    cleanup
    exit 130
}

trap handle_interrupt INT TERM
trap cleanup EXIT

INFERENCE_PID=""

# ─── Phase 1: Inference ──────────────────────────────────────────────────────

echo ""
echo "→ Phase 1: Inference (generating patches)..."
echo ""

PREDICTIONS_FILE="${SWE_BENCH_RESULTS_DIR}/predictions.jsonl"

cat > "${SWE_BENCH_RESULTS_DIR}/run_inference.py" << 'PYTHON_EOF'
#!/usr/bin/env python3
import os, sys, json, time, re
from datetime import datetime
from pathlib import Path

def main():
    model = os.environ["SWE_BENCH_MODEL"]
    dataset_name = os.environ["SWE_BENCH_DATASET"]
    predictions_path = Path(os.environ["PREDICTIONS_FILE"])
    api_base = os.environ["PROXY_ENDPOINT"] + "/v1"
    api_key = os.environ["API_KEY"]
    timeout = int(os.environ.get("SWE_BENCH_TIMEOUT", "1800"))
    instance_limit = os.environ.get("SWE_BENCH_INSTANCE_LIMIT", "")
    instance_ids_str = os.environ.get("SWE_BENCH_INSTANCE_IDS", "")

    from openai import OpenAI
    from datasets import load_dataset

    client = OpenAI(base_url=api_base, api_key=api_key)

    print(f"Loading dataset: {dataset_name}")
    ds = load_dataset(dataset_name, split="test")
    print(f"Total instances in dataset: {len(ds)}")

    # Filter to specific instance IDs if provided
    if instance_ids_str:
        target_ids = set(id.strip() for id in instance_ids_str.split(","))
        ds = ds.filter(lambda x: x["instance_id"] in target_ids)
        print(f"Filtered to {len(ds)} specified instances")
    elif instance_limit:
        limit = int(instance_limit)
        ds = ds.select(range(min(limit, len(ds))))
        print(f"Limited to {len(ds)} instances")

    # Load already-completed predictions for resumption
    completed = set()
    if predictions_path.exists():
        with open(predictions_path) as f:
            for line in f:
                try:
                    pred = json.loads(line.strip())
                    completed.add(pred["instance_id"])
                except:
                    pass
        print(f"Resuming: {len(completed)} instances already completed")

    total = len(ds)
    done = len(completed)

    for i, instance in enumerate(ds):
        instance_id = instance["instance_id"]
        if instance_id in completed:
            continue

        done += 1
        print(f"[{done}/{total}] {instance_id}")

        # Build prompt
        problem_statement = instance.get("problem_statement", "")
        repo = instance.get("repo", "")
        base_commit = instance.get("base_commit", "")

        prompt = f"""You are a software engineer tasked with fixing a bug in a GitHub repository.

Repository: {repo}
Base commit: {base_commit}

Problem Statement:
{problem_statement}

Please analyze the problem and provide a patch that fixes the issue.
Respond with ONLY the patch in unified diff format (the output of `git diff`).
The patch should be directly applicable to the repository at the base commit.
Do not include any explanation before or after the patch.

Start your response with ```diff and end with ```."""

        try:
            response = client.chat.completions.create(
                model=model,
                messages=[{"role": "user", "content": prompt}],
                temperature=0.0,
                max_tokens=4096,
                timeout=timeout
            )
            content = response.choices[0].message.content or ""

            # Extract patch from response
            patch = ""
            # Try to extract from ```diff ... ``` blocks
            diff_match = re.search(r'```(?:diff)?\s*\n(.*?)```', content, re.DOTALL)
            if diff_match:
                patch = diff_match.group(1).strip()
            else:
                # Try to find raw diff content
                lines = content.split("\n")
                diff_lines = []
                in_diff = False
                for line in lines:
                    if line.startswith(("diff --git", "---", "+++", "@@", "+", "-", " ")) and not line.startswith("- "):
                        in_diff = True
                        diff_lines.append(line)
                    elif in_diff and line.strip() == "":
                        diff_lines.append(line)
                    elif in_diff:
                        break
                if diff_lines:
                    patch = "\n".join(diff_lines).strip()
                else:
                    patch = content.strip()

            prediction = {
                "instance_id": instance_id,
                "model_name_or_path": model,
                "model_patch": patch
            }

            with open(predictions_path, "a") as f:
                f.write(json.dumps(prediction) + "\n")

            patch_preview = patch[:80].replace("\n", " ") + "..." if len(patch) > 80 else patch.replace("\n", " ")
            print(f"  ✓ Patch generated ({len(patch)} chars)")

        except Exception as e:
            print(f"  ✗ Error: {e}")
            # Write empty patch so we don't retry on resume
            prediction = {
                "instance_id": instance_id,
                "model_name_or_path": model,
                "model_patch": ""
            }
            with open(predictions_path, "a") as f:
                f.write(json.dumps(prediction) + "\n")

    print(f"\nInference complete. Predictions saved to {predictions_path}")

if __name__ == "__main__":
    main()
PYTHON_EOF

export SWE_BENCH_MODEL SWE_BENCH_DATASET PREDICTIONS_FILE PROXY_ENDPOINT API_KEY
export SWE_BENCH_TIMEOUT SWE_BENCH_INSTANCE_LIMIT SWE_BENCH_INSTANCE_IDS

python "${SWE_BENCH_RESULTS_DIR}/run_inference.py" 2>&1 | tee "${SWE_BENCH_RESULTS_DIR}/run.log" &
INFERENCE_PID=$!
wait $INFERENCE_PID
INFERENCE_EXIT=$?
INFERENCE_PID=""

if [ $INFERENCE_EXIT -ne 0 ]; then
    echo "✗ Inference phase failed (exit code: $INFERENCE_EXIT)"
    exit $INFERENCE_EXIT
fi

# Verify predictions file exists and is non-empty
if [ ! -s "$PREDICTIONS_FILE" ]; then
    echo "✗ No predictions generated"
    exit 1
fi

PRED_COUNT=$(wc -l < "$PREDICTIONS_FILE" | tr -d ' ')
echo ""
echo "✓ Inference complete: $PRED_COUNT predictions"
echo ""

# ─── Phase 2: Evaluation ─────────────────────────────────────────────────────

echo "→ Phase 2: Evaluation (running tests in Docker)..."
echo "  This may take a long time depending on the number of instances."
echo ""

# Run evaluation from the results directory so all output (logs/, JSONs) lands there
pushd "$SWE_BENCH_RESULTS_DIR" > /dev/null

EVAL_CMD="python -m swebench.harness.run_evaluation \
    --predictions_path $PREDICTIONS_FILE \
    --dataset_name $SWE_BENCH_DATASET \
    --max_workers $SWE_BENCH_MAX_WORKERS \
    --run_id $RUN_ID"

if [ -n "$NAMESPACE_FLAG" ]; then
    EVAL_CMD="$EVAL_CMD --namespace ''"
fi

eval $EVAL_CMD 2>&1 | tee -a "${SWE_BENCH_RESULTS_DIR}/run.log"
EVAL_EXIT=${PIPESTATUS[0]}

popd > /dev/null

if [ $EVAL_EXIT -ne 0 ]; then
    echo ""
    echo "⚠ Evaluation exited with code $EVAL_EXIT (some instances may have failed)"
fi

# Move any stray evaluation artifacts from the script directory into results
for log_dir in logs/build_images logs/run_evaluation; do
    if [ -d "${SCRIPT_DIR}/${log_dir}" ]; then
        mkdir -p "${SWE_BENCH_RESULTS_DIR}/${log_dir}"
        cp -r "${SCRIPT_DIR}/${log_dir}"/* "${SWE_BENCH_RESULTS_DIR}/${log_dir}/" 2>/dev/null || true
        rm -rf "${SCRIPT_DIR}/${log_dir}" 2>/dev/null || true
    fi
done

# Move any stray JSON result files from the script directory
for f in "${SCRIPT_DIR}"/*.swe_bench_*.json "${SCRIPT_DIR}"/${SWE_BENCH_MODEL}.*.json; do
    [ -f "$f" ] && mv "$f" "${SWE_BENCH_RESULTS_DIR}/" 2>/dev/null || true
done

# Clean empty logs directory if left behind
rmdir "${SCRIPT_DIR}/logs" 2>/dev/null || true

# ─── Phase 3: Results Aggregation ────────────────────────────────────────────

echo ""
echo "→ Aggregating results..."

cat > "${SWE_BENCH_RESULTS_DIR}/aggregate_results.py" << 'PYTHON_EOF'
#!/usr/bin/env python3
import os, sys, json, glob
from datetime import datetime
from pathlib import Path

def main():
    results_dir = Path(os.environ["SWE_BENCH_RESULTS_DIR"])
    model = os.environ["SWE_BENCH_MODEL"]
    dataset = os.environ["SWE_BENCH_DATASET"]
    run_id = os.environ["RUN_ID"]

    predictions_path = results_dir / "predictions.jsonl"

    # Count predictions
    total_predictions = 0
    predictions = {}
    with open(predictions_path) as f:
        for line in f:
            try:
                pred = json.loads(line.strip())
                predictions[pred["instance_id"]] = pred
                total_predictions += 1
            except:
                pass

    empty_patches = sum(1 for p in predictions.values() if not p.get("model_patch", "").strip())

    # Parse evaluation report if available
    resolved = []
    unresolved = []

    # Look for swebench evaluation report
    report_glob = str(results_dir / "logs" / "run_evaluation" / run_id / "**" / "report.json")
    report_files = glob.glob(report_glob, recursive=True)

    # Also check current directory patterns
    if not report_files:
        report_glob = str(Path("logs") / "run_evaluation" / run_id / "**" / "report.json")
        report_files = glob.glob(report_glob, recursive=True)

    # Try the standard swebench output location
    if not report_files:
        report_glob = str(results_dir / f"{run_id}.*.json")
        report_files = glob.glob(report_glob)

    for report_file in report_files:
        try:
            with open(report_file) as f:
                report = json.load(f)
            if isinstance(report, dict):
                resolved.extend(report.get("resolved", []))
                unresolved.extend(report.get("unresolved", report.get("error", [])))
        except:
            pass

    # If no report found, try parsing individual log files
    if not resolved and not unresolved:
        eval_logs_dir = results_dir / "logs" / "run_evaluation" / run_id
        if not eval_logs_dir.exists():
            eval_logs_dir = Path("logs") / "run_evaluation" / run_id

        if eval_logs_dir.exists():
            for log_dir in eval_logs_dir.iterdir():
                if log_dir.is_dir():
                    test_output = log_dir / "test_output.txt"
                    if test_output.exists():
                        content = test_output.read_text()
                        instance_id = log_dir.name
                        if "PASSED" in content or "passed" in content.lower():
                            resolved.append(instance_id)
                        else:
                            unresolved.append(instance_id)

    resolved_count = len(set(resolved))
    total_evaluated = resolved_count + len(set(unresolved))
    if total_evaluated == 0:
        total_evaluated = total_predictions

    accuracy = round(resolved_count / total_evaluated * 100, 2) if total_evaluated > 0 else 0.0

    summary = {
        "benchmark": "swe-bench-verified",
        "timestamp": datetime.now().isoformat(),
        "model": model,
        "dataset": dataset,
        "results": {
            "total_instances": total_predictions,
            "total_evaluated": total_evaluated,
            "resolved": resolved_count,
            "unresolved": total_evaluated - resolved_count,
            "empty_patches": empty_patches,
            "accuracy": accuracy
        },
        "resolved_instances": sorted(set(resolved)),
        "config": {
            "max_workers": int(os.environ.get("SWE_BENCH_MAX_WORKERS", "4")),
            "timeout": int(os.environ.get("SWE_BENCH_TIMEOUT", "1800")),
            "agent": os.environ.get("SWE_BENCH_AGENT", "simple")
        }
    }

    summary_path = results_dir / "summary.json"
    with open(summary_path, "w") as f:
        json.dump(summary, f, indent=2)

    print()
    print("═" * 70)
    print("  SWE-BENCH VERIFIED RESULTS")
    print("═" * 70)
    print(f"  Model:       {model}")
    print(f"  Instances:   {total_predictions}")
    print(f"  Resolved:    {resolved_count}/{total_evaluated} ({accuracy}%)")
    if empty_patches > 0:
        print(f"  Empty:       {empty_patches} (no patch generated)")
    print(f"  Results:     {summary_path}")
    print("═" * 70)

if __name__ == "__main__":
    main()
PYTHON_EOF

export SWE_BENCH_RESULTS_DIR SWE_BENCH_MODEL SWE_BENCH_DATASET RUN_ID
export SWE_BENCH_MAX_WORKERS SWE_BENCH_TIMEOUT SWE_BENCH_AGENT

python "${SWE_BENCH_RESULTS_DIR}/aggregate_results.py"

# Cleanup temp scripts
rm -f "${SWE_BENCH_RESULTS_DIR}/run_inference.py" "${SWE_BENCH_RESULTS_DIR}/aggregate_results.py"

deactivate

echo ""
[ $EVAL_EXIT -eq 0 ] && echo "✓ SWE-bench evaluation completed successfully" || echo "⚠ SWE-bench evaluation completed with warnings"
echo "  Results: $SWE_BENCH_RESULTS_DIR"
echo ""

exit $EVAL_EXIT
