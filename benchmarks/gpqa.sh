#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config.env"
[ ! -f "$CONFIG_FILE" ] && echo "Error: Config file not found at $CONFIG_FILE" && exit 1
source "$CONFIG_FILE"

# Config defaults
GPQA_MODEL="${GPQA_MODEL:-${TERMINAL_BENCH_MODEL:-}}"
GPQA_SUBSET="${GPQA_SUBSET:-diamond}"
GPQA_LIMIT="${GPQA_LIMIT:-}"               # empty = all, or a number
HF_TOKEN="${HF_TOKEN:-}"
PROXY_ENDPOINT="${MODEL_ENDPOINT:-http://localhost:8001}"
API_KEY="${LITELLM_PROXY_KEY:-sk-litellm-proxy-key-123}"

[ -z "$GPQA_MODEL" ] && echo "Error: GPQA_MODEL not set in config.env" && exit 1
[ -z "$HF_TOKEN" ] && echo "Error: HF_TOKEN not set in config.env (GPQA is a gated dataset)" && exit 1

# Map subset to task count
TASK_COUNT="198"
[ "$GPQA_SUBSET" = "main" ] && TASK_COUNT="448"
[ "$GPQA_SUBSET" = "extended" ] && TASK_COUNT="546"

# Timestamped results directory
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
GPQA_RESULTS_DIR="${SCRIPT_DIR}/../benchmark_results/gpqa/gpqa_${TIMESTAMP}_${GPQA_MODEL}"
mkdir -p "$GPQA_RESULTS_DIR"
GPQA_RESULTS_DIR=$(cd "$GPQA_RESULTS_DIR" && pwd)
BENCHMARK_DIR="${SCRIPT_DIR}/gpqa_repo"
VENV_DIR="${BENCHMARK_DIR}/venv"

echo "═══════════════════════════════════════════════════════════════════════"
echo "  GPQA Diamond Evaluation"
echo "═══════════════════════════════════════════════════════════════════════"
echo "  Model:    $GPQA_MODEL"
if [ -n "$GPQA_LIMIT" ]; then
    echo "  Subset:   $GPQA_SUBSET ($GPQA_LIMIT of $TASK_COUNT questions)"
else
    echo "  Subset:   $GPQA_SUBSET ($TASK_COUNT questions)"
fi
echo "  Results:  $GPQA_RESULTS_DIR"
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
pip install --quiet datasets openai 2>/dev/null

# ─── Run Evaluation ──────────────────────────────────────────────────────────

echo ""
echo "→ Running GPQA evaluation..."
echo ""

cat > "${GPQA_RESULTS_DIR}/run_gpqa.py" << 'PYTHON_EOF'
#!/usr/bin/env python3
import os, sys, json, re, random
from datetime import datetime

def main():
    model = os.environ["GPQA_MODEL"]
    subset = os.environ["GPQA_SUBSET"]
    results_dir = os.environ["GPQA_RESULTS_DIR"]
    api_base = os.environ["PROXY_ENDPOINT"] + "/v1"
    api_key = os.environ["API_KEY"]
    hf_token = os.environ["HF_TOKEN"]

    from openai import OpenAI
    from datasets import load_dataset

    client = OpenAI(base_url=api_base, api_key=api_key)

    # GPQA dataset names
    subset_map = {
        "diamond": "gpqa_diamond",
        "main": "gpqa_main",
        "extended": "gpqa_extended"
    }
    dataset_subset = subset_map.get(subset, "gpqa_diamond")

    print(f"Loading GPQA {subset} from HuggingFace...")
    ds = load_dataset("Idavidrein/gpqa", dataset_subset, token=hf_token, split="train")
    print(f"Loaded {len(ds)} questions")

    limit = os.environ.get("GPQA_LIMIT", "")
    if limit:
        ds = ds.select(range(min(int(limit), len(ds))))
        print(f"Limited to {len(ds)} questions")

    results = []
    correct = 0
    total = 0
    total_input_tokens = 0
    total_output_tokens = 0

    for i, item in enumerate(ds):
        total += 1
        question = item.get("Question", "")
        correct_answer = item.get("Correct Answer", "")

        # Build shuffled choices
        choices = [
            item.get("Correct Answer", ""),
            item.get("Incorrect Answer 1", ""),
            item.get("Incorrect Answer 2", ""),
            item.get("Incorrect Answer 3", ""),
        ]
        # Filter out empty choices
        choices = [c for c in choices if c.strip()]

        # Shuffle and track correct index
        indexed_choices = list(enumerate(choices))
        random.seed(i)  # deterministic shuffle per question
        random.shuffle(indexed_choices)

        labels = ["A", "B", "C", "D"]
        correct_label = None
        choice_text = ""
        for j, (orig_idx, choice) in enumerate(indexed_choices):
            label = labels[j]
            choice_text += f"({label}) {choice}\n"
            if orig_idx == 0:  # original index 0 is the correct answer
                correct_label = label

        prompt = f"""Answer the following multiple-choice question. Think step by step, then provide your final answer as a single letter (A, B, C, or D) on the last line in the format "Answer: X".

Question: {question}

{choice_text}
"""

        try:
            response = client.chat.completions.create(
                model=model,
                messages=[{"role": "user", "content": prompt}],
                temperature=0.0,
                max_tokens=2048
            )
            content = response.choices[0].message.content or ""

            # Track token usage
            if response.usage:
                total_input_tokens += response.usage.prompt_tokens or 0
                total_output_tokens += response.usage.completion_tokens or 0

            # Extract answer letter
            predicted_label = None

            # Try "Answer: X" pattern
            answer_match = re.search(r'Answer:\s*([A-D])', content, re.IGNORECASE)
            if answer_match:
                predicted_label = answer_match.group(1).upper()
            else:
                # Try standalone letter at end
                last_line = content.strip().split("\n")[-1].strip()
                letter_match = re.search(r'\b([A-D])\b', last_line)
                if letter_match:
                    predicted_label = letter_match.group(1).upper()

            is_correct = predicted_label == correct_label
            if is_correct:
                correct += 1

            status = "✓" if is_correct else "✗"
            print(f"[{total}/{len(ds)}] {status} predicted={predicted_label} correct={correct_label}")

            results.append({
                "question_index": i,
                "predicted": predicted_label,
                "correct": correct_label,
                "is_correct": is_correct,
                "response": content[:500]  # truncate for storage
            })

        except Exception as e:
            print(f"[{total}/{len(ds)}] ✗ Error: {e}")
            results.append({
                "question_index": i,
                "predicted": None,
                "correct": correct_label,
                "is_correct": False,
                "error": str(e)
            })

    accuracy = round(correct / total * 100, 2) if total > 0 else 0.0

    summary = {
        "benchmark": "gpqa",
        "timestamp": datetime.now().isoformat(),
        "model": model,
        "subset": subset,
        "results": {
            "total_questions": total,
            "correct": correct,
            "incorrect": total - correct,
            "accuracy": accuracy
        },
        "token_usage": {
            "input": total_input_tokens,
            "output": total_output_tokens,
            "total": total_input_tokens + total_output_tokens
        },
        "question_results": results
    }

    summary_path = os.path.join(results_dir, "summary.json")
    with open(summary_path, "w") as f:
        json.dump(summary, f, indent=2)

    print()
    print("=" * 70)
    print("  GPQA RESULTS")
    print("=" * 70)
    print(f"  Model:     {model}")
    print(f"  Subset:    {subset}")
    print(f"  Accuracy:  {correct}/{total} ({accuracy}%)")
    print(f"  Tokens:    {total_input_tokens + total_output_tokens:,}")
    print(f"  Random baseline: 25.0%")
    print("=" * 70)

if __name__ == "__main__":
    main()
PYTHON_EOF

export GPQA_MODEL GPQA_SUBSET GPQA_LIMIT GPQA_RESULTS_DIR PROXY_ENDPOINT API_KEY HF_TOKEN

python "${GPQA_RESULTS_DIR}/run_gpqa.py" 2>&1 | tee "${GPQA_RESULTS_DIR}/run.log"
EXIT_CODE=${PIPESTATUS[0]}

# Cleanup temp script
rm -f "${GPQA_RESULTS_DIR}/run_gpqa.py"

deactivate

echo ""
[ $EXIT_CODE -eq 0 ] && echo "✓ GPQA evaluation completed successfully" || echo "✗ GPQA evaluation failed (exit code: $EXIT_CODE)"
echo "  Results: $GPQA_RESULTS_DIR"
echo ""

exit $EXIT_CODE
