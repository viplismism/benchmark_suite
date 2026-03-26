#!/usr/bin/env python3
"""
CodeSearchNet evaluation for QMD hybrid search.

Compares against RANGER's reported NDCG@10 = 0.786.

Pipeline:
  1. Download annotationStore.csv (573 queries, graded 0-3 relevance, 6 languages)
  2. Extract unique GitHub file URLs -> download source files (per-language dirs)
  3. Index files into per-language QMD collections (csn-go, csn-java, etc.)
  4. Run each query through its language's QMD collection
  5. Score with graded NDCG@10 (same formula as RANGER / CSN leaderboard)

Environment variables (set by codesearch.sh):
  CODESEARCH_QMD_DIR     - Path to QMD repo root
  CODESEARCH_NODE_BIN    - Path to Node.js binary
  CODESEARCH_RESULTS_DIR - Where to write summary.json + detailed results
  CODESEARCH_CACHE_DIR   - Where to cache annotations and downloaded files
"""

import sys, os, json, time, csv, re, subprocess, urllib.request, urllib.error
from pathlib import Path
from datetime import datetime
from typing import List, Dict, Tuple, Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from metrics import graded_ndcg_at_k, mrr_at_k, aggregate_graded_metrics


# ============================================================================
# Configuration (from environment)
# ============================================================================

CACHE_DIR     = Path(os.environ.get("CODESEARCH_CACHE_DIR", Path(__file__).parent))
RESULTS_DIR   = Path(os.environ.get("CODESEARCH_RESULTS_DIR", "."))
CSN_FILES_DIR = CACHE_DIR / "csn_files"
CSN_CACHE_CSV = CACHE_DIR / "annotationStore.csv"

QMD_DIR   = Path(os.environ.get("CODESEARCH_QMD_DIR", ""))
NODE      = os.environ.get("CODESEARCH_NODE_BIN", "node")
QMD_ENTRY = QMD_DIR / "src" / "cli" / "qmd.ts"

ANNOTATION_STORE_URL = (
    "https://raw.githubusercontent.com/github/CodeSearchNet/"
    "master/resources/annotationStore.csv"
)

RANGER_NDCG = 0.786

def _collection_name(lang: str) -> str:
    return f"csn-{lang.lower()}"

LANG_EXTENSIONS = {
    "Go":         "**/*.go",
    "Java":       "**/*.java",
    "JavaScript": "**/*.js",
    "PHP":        "**/*.php",
    "Python":     "**/*.py",
    "Ruby":       "**/*.rb",
}

TOP_K = 10


# ============================================================================
# Step 1: Download annotationStore.csv
# ============================================================================

def download_annotations(force: bool = False) -> str:
    if CSN_CACHE_CSV.exists() and not force:
        print(f"  [cache] Using existing {CSN_CACHE_CSV}")
        return str(CSN_CACHE_CSV)

    print(f"  Downloading annotationStore.csv from GitHub...")
    try:
        urllib.request.urlretrieve(ANNOTATION_STORE_URL, CSN_CACHE_CSV)
        print(f"  Saved to {CSN_CACHE_CSV}")
    except urllib.error.URLError as e:
        print(f"  ERROR: Could not download annotations: {e}")
        sys.exit(1)
    return str(CSN_CACHE_CSV)


# ============================================================================
# Step 2: Parse annotations
# ============================================================================

def parse_annotations(csv_path: str, language_filter: Optional[str] = None) -> Dict:
    grouped: Dict[Tuple[str, str], List[Dict]] = {}

    with open(csv_path, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            lang    = row["Language"].strip()
            query   = row["Query"].strip()
            url     = row["GitHubUrl"].strip()
            rel_str = row["Relevance"].strip()

            if language_filter and lang.lower() != language_filter.lower():
                continue

            try:
                relevance = int(rel_str)
            except ValueError:
                continue

            file_url = re.sub(r"#L\d+(-L\d+)?$", "", url)
            file_id  = _github_url_to_file_id(file_url)

            key = (lang, query)
            if key not in grouped:
                grouped[key] = []
            grouped[key].append({
                "file_id":    file_id,
                "github_url": file_url,
                "relevance":  relevance,
            })

    queries   = []
    all_files = {}
    files_by_lang: Dict[str, Dict[str, str]] = {}

    for (lang, query), annotations in grouped.items():
        seen: Dict[str, int] = {}
        for ann in annotations:
            fid = ann["file_id"]
            if fid not in seen or ann["relevance"] > seen[fid]:
                seen[fid] = ann["relevance"]
            all_files[fid] = ann["github_url"]
            files_by_lang.setdefault(lang, {})[fid] = ann["github_url"]

        deduped = [{"file_id": fid, "github_url": all_files[fid], "relevance": rel}
                   for fid, rel in seen.items()]

        queries.append({
            "language":    lang,
            "query":       query,
            "annotations": deduped,
        })

    return {"queries": queries, "all_files": all_files, "files_by_lang": files_by_lang}


def _github_url_to_file_id(github_url: str) -> str:
    m = re.match(
        r"https?://github\.com/([^/]+)/([^/]+)/blob/([^/]+)/(.+)",
        github_url
    )
    if m:
        owner, repo, sha, path = m.groups()
        return f"{owner}__{repo}__{sha}/{path}"

    return re.sub(r"[^a-zA-Z0-9/_.-]", "_", github_url.replace("https://", ""))


def _qmd_path_to_file_id(qmd_path: str) -> str:
    parts = qmd_path.split("/", 1)
    if len(parts) < 2:
        return qmd_path
    dir_part, rest = parts

    sha_match = re.search(r'-([0-9a-f]{40})$', dir_part)
    if sha_match:
        sha = sha_match.group(1)
        real_dir = _SHA_TO_DIR.get(sha)
        if real_dir:
            return f"{real_dir}/{rest}"

    return qmd_path


_SHA_TO_DIR: dict = {}

def _build_sha_map():
    if not CSN_FILES_DIR.exists():
        return
    for lang_dir in CSN_FILES_DIR.iterdir():
        if not lang_dir.is_dir():
            continue
        for d in lang_dir.iterdir():
            if d.is_dir():
                parts = d.name.split("__")
                if len(parts) >= 3:
                    sha = parts[-1]
                    _SHA_TO_DIR[sha] = d.name

_build_sha_map()


def _file_id_to_raw_url(file_id: str, github_url: str) -> str:
    return github_url.replace(
        "https://github.com/", "https://raw.githubusercontent.com/"
    ).replace("/blob/", "/")


# ============================================================================
# Step 3: Download source files
# ============================================================================

def download_files(files_by_lang: Dict[str, Dict[str, str]], force: bool = False) -> int:
    CSN_FILES_DIR.mkdir(parents=True, exist_ok=True)
    total_downloaded = 0

    for lang, lang_files in sorted(files_by_lang.items()):
        lang_dir = CSN_FILES_DIR / lang.lower()
        lang_dir.mkdir(parents=True, exist_ok=True)

        downloaded = 0
        skipped    = 0
        errors     = 0
        total      = len(lang_files)

        print(f"  [{lang}] Downloading {total} files to {lang_dir.name}/")

        for i, (file_id, github_url) in enumerate(lang_files.items()):
            dest = lang_dir / file_id
            dest.parent.mkdir(parents=True, exist_ok=True)

            if dest.exists() and not force:
                skipped += 1
                continue

            raw_url = _file_id_to_raw_url(file_id, github_url)
            try:
                urllib.request.urlretrieve(raw_url, dest)
                downloaded += 1
            except urllib.error.HTTPError:
                errors += 1
            except Exception:
                errors += 1

            if (i + 1) % 50 == 0:
                print(f"    {i+1}/{total}  downloaded={downloaded}  skipped={skipped}  errors={errors}")

        print(f"    Done: {downloaded} new, {skipped} cached, {errors} failed")
        total_downloaded += downloaded

    return total_downloaded


# ============================================================================
# Step 4: Index into QMD
# ============================================================================

def _qmd_cmd():
    """Build the base QMD command."""
    import platform
    cmd = [NODE, "--import", "tsx", str(QMD_ENTRY)]
    if platform.machine() == "arm64" and platform.system() == "Darwin":
        cmd = ["arch", "-arm64"] + cmd
    return cmd

def index_into_qmd(languages: List[str]) -> bool:
    if not CSN_FILES_DIR.exists():
        print("  ERROR: csn_files/ not found - run download step first")
        return False

    qmd_cmd = _qmd_cmd()
    ok = True

    for lang in languages:
        lang_dir   = CSN_FILES_DIR / lang.lower()
        collection = _collection_name(lang)
        mask       = LANG_EXTENSIONS.get(lang, "**/*")

        if not lang_dir.exists():
            print(f"  [{lang}] SKIP - {lang_dir} not found")
            continue

        n_files = sum(1 for _ in lang_dir.rglob("*") if _.is_file())
        print(f"  [{lang}] Indexing {n_files} files -> collection '{collection}' (mask={mask})")

        subprocess.run(
            qmd_cmd + ["collection", "remove", collection],
            capture_output=True, text=True, cwd=str(QMD_DIR),
        )

        try:
            result = subprocess.run(
                qmd_cmd + [
                    "collection", "add", str(lang_dir),
                    "--name", collection,
                    "--mask", mask,
                ],
                capture_output=True, text=True, timeout=1800,
                cwd=str(QMD_DIR),
            )
            if result.returncode != 0:
                print(f"  [{lang}] ERROR indexing: {result.stderr[-500:]}")
                ok = False
            else:
                print(f"  [{lang}] Done.")
        except subprocess.TimeoutExpired:
            print(f"  [{lang}] ERROR: indexing timed out (>30 min)")
            ok = False

    return ok


# ============================================================================
# Step 5: Run queries through QMD
# ============================================================================

def qmd_query(query: str, collection: str, top_k: int = TOP_K) -> List[str]:
    try:
        result = subprocess.run(
            _qmd_cmd() + [
                "query", query,
                "-c", collection,
                "--json",
                "-n", str(top_k),
            ],
            capture_output=True, text=True, timeout=180,
            cwd=str(QMD_DIR),
        )
        if result.returncode != 0 or not result.stdout.strip():
            return []
        items = json.loads(result.stdout.strip())
        files = []
        prefix = f"qmd://{collection}/"
        for item in items:
            fpath = item.get("file", "")
            if fpath.startswith(prefix):
                qmd_rel = fpath[len(prefix):]
            else:
                qmd_rel = fpath
            file_id = _qmd_path_to_file_id(qmd_rel)
            if file_id and file_id not in files:
                files.append(file_id)
        return files[:top_k]
    except (subprocess.TimeoutExpired, json.JSONDecodeError, Exception):
        return []


# ============================================================================
# Step 6: Score
# ============================================================================

def evaluate_query(q: dict, top_k: int = TOP_K) -> dict:
    query       = q["query"]
    language    = q["language"]
    annotations = q["annotations"]
    collection  = _collection_name(language)

    # Lowercase keys - QMD normalizes filenames to lowercase during indexing
    grade_map = {ann["file_id"].lower(): ann["relevance"] for ann in annotations}

    predictions = qmd_query(query, collection, top_k)
    # Lowercase predictions to match grade_map keys
    predictions = [p.lower() for p in predictions]

    g_ndcg = graded_ndcg_at_k(predictions, grade_map, top_k)

    relevant_ids = [fid for fid, rel in grade_map.items() if rel >= 1]
    mrr = mrr_at_k(predictions, relevant_ids, top_k)

    return {
        "language":    q["language"],
        "query":       query,
        "predictions": predictions,
        "grade_map":   grade_map,
        "graded_ndcg": g_ndcg,
        "mrr":         mrr,
    }


def run_evaluation(queries: List[dict], top_k: int = TOP_K, verbose: bool = False) -> dict:
    print(f"\n{'='*70}")
    print(f"  CodeSearchNet Evaluation - QMD Hybrid Search")
    print(f"  Queries: {len(queries)} | Top-k: {top_k} | Target: RANGER NDCG={RANGER_NDCG}")
    print(f"{'='*70}\n")

    results = []
    start   = time.time()

    for i, q in enumerate(queries):
        r = evaluate_query(q, top_k)
        results.append(r)

        if verbose:
            status = "+" if r["graded_ndcg"] > 0 else "x"
            print(f"  [{status}] [{r['language']:<6}] {r['query'][:55]:<55s}  "
                  f"NDCG={r['graded_ndcg']:.3f}  MRR={r['mrr']:.3f}")
        else:
            if (i + 1) % 10 == 0:
                partial = aggregate_graded_metrics(results)
                print(f"  {i+1:3d}/{len(queries)}  running NDCG={partial['graded_ndcg_at_k']:.4f}")

    elapsed = time.time() - start
    agg     = aggregate_graded_metrics(results)

    lang_breakdown = {}
    for lang in sorted({r["language"] for r in results}):
        lang_results = [r for r in results if r["language"] == lang]
        lang_breakdown[lang] = aggregate_graded_metrics(lang_results)

    return {
        "metrics":        agg,
        "lang_breakdown": lang_breakdown,
        "per_query":      results,
        "top_k":          top_k,
        "num_queries":    len(queries),
        "elapsed_seconds": elapsed,
        "timestamp":      datetime.now().isoformat(),
    }


# ============================================================================
# Reporting + summary.json (benchmark_suite compatible)
# ============================================================================

def print_results(result: dict):
    m    = result["metrics"]
    k    = result["top_k"]
    ndcg = m["graded_ndcg_at_k"]
    vs   = ndcg - RANGER_NDCG

    print(f"\n{'='*70}")
    print(f"  CODESEARCH RESULTS  (Graded NDCG@{k})")
    print(f"{'='*70}")
    print(f"  Graded NDCG@{k:<4}: {ndcg:.4f}   (RANGER = {RANGER_NDCG:.3f}, "
          f"{'+ ' if vs >= 0 else ''}{vs:+.4f})")
    print(f"  MRR@{k:<9}: {m['mrr_at_k']:.4f}")
    print(f"  Queries     : {result['num_queries']}  in {result['elapsed_seconds']:.1f}s")

    print(f"\n  Per-language breakdown:")
    print(f"  {'Language':<12} {'Queries':<10} {'NDCG@'+str(k):<12} {'MRR@'+str(k)}")
    print(f"  {'-'*48}")
    for lang, lm in sorted(result["lang_breakdown"].items()):
        print(f"  {lang:<12} {lm['num_queries']:<10} {lm['graded_ndcg_at_k']:<12.4f} {lm['mrr_at_k']:.4f}")

    print(f"{'='*70}\n")


def write_summary(result: dict):
    """Write summary.json in the benchmark_suite standard format."""
    m    = result["metrics"]
    ndcg = m["graded_ndcg_at_k"]

    # Queries where NDCG > 0 count as "passed" for the results table
    passed = sum(1 for r in result["per_query"] if r["graded_ndcg"] > 0)
    total  = result["num_queries"]
    accuracy = round(ndcg * 100, 2)

    # Per-language scores for detailed view
    lang_scores = {}
    for lang, lm in result["lang_breakdown"].items():
        lang_scores[lang] = {
            "ndcg": round(lm["graded_ndcg_at_k"], 4),
            "mrr":  round(lm["mrr_at_k"], 4),
            "queries": lm["num_queries"],
        }

    summary = {
        "benchmark": "codesearch",
        "timestamp": datetime.now().isoformat(),
        "model": "qmd-hybrid",
        "results": {
            "passed": passed,
            "total": total,
            "accuracy": accuracy,
            "graded_ndcg": round(ndcg, 4),
            "mrr": round(m["mrr_at_k"], 4),
            "ranger_ndcg": RANGER_NDCG,
        },
        "per_language": lang_scores,
        "config": {
            "top_k": result["top_k"],
            "elapsed_seconds": round(result["elapsed_seconds"], 1),
        },
    }

    summary_path = RESULTS_DIR / "summary.json"
    with open(summary_path, "w") as f:
        json.dump(summary, f, indent=2)
    print(f"  Summary: {summary_path}")

    # Also save detailed per-query results
    detail_path = RESULTS_DIR / "detailed_results.json"
    with open(detail_path, "w") as f:
        json.dump(result, f, indent=2)
    print(f"  Details: {detail_path}")


# ============================================================================
# Main
# ============================================================================

def main():
    import argparse
    parser = argparse.ArgumentParser(description="Evaluate QMD on CodeSearchNet")
    parser.add_argument("--skip-download", action="store_true",
                        help="Use already-downloaded files (skip Steps 1-3)")
    parser.add_argument("--skip-index", action="store_true",
                        help="Use existing QMD collection (skip Step 4)")
    parser.add_argument("--language", "-l", type=str, default=None,
                        help="Filter to single language (Python/Go/Java/JavaScript/PHP/Ruby)")
    parser.add_argument("--top-k", type=int, default=TOP_K,
                        help=f"Top-k cutoff (default: {TOP_K})")
    parser.add_argument("--verbose", "-v", action="store_true",
                        help="Show per-query results")
    parser.add_argument("--dry-run", action="store_true",
                        help="Parse & show dataset stats, don't run eval")
    args = parser.parse_args()

    RESULTS_DIR.mkdir(parents=True, exist_ok=True)

    print("\n" + "="*70)
    print("  CodeSearchNet Eval Pipeline")
    print("="*70)

    # -- Step 1: Get annotations --
    if not args.skip_download:
        csv_path = download_annotations()
    else:
        csv_path = str(CSN_CACHE_CSV)
        if not CSN_CACHE_CSV.exists():
            print(f"ERROR: {CSN_CACHE_CSV} not found - remove --skip-download")
            sys.exit(1)

    # -- Step 2: Parse --
    print(f"\n[Step 2] Parsing annotations (language={args.language or 'all'})...")
    dataset = parse_annotations(csv_path, language_filter=args.language)
    queries       = dataset["queries"]
    all_files     = dataset["all_files"]
    files_by_lang = dataset["files_by_lang"]
    active_langs  = sorted({q["language"] for q in queries})

    print(f"  Queries   : {len(queries)}")
    print(f"  Unique files: {len(all_files)}")
    langs = {}
    for q in queries:
        langs[q["language"]] = langs.get(q["language"], 0) + 1
    for lang, count in sorted(langs.items()):
        avg_ann = sum(len(q["annotations"]) for q in queries if q["language"] == lang) / count
        n_files = len(files_by_lang.get(lang, {}))
        print(f"    {lang:<12} {count:3d} queries, {n_files:4d} files, avg {avg_ann:.1f} annotated/query")

    if args.dry_run:
        print("\n  [dry-run] Stopping here.")
        return

    # -- Step 3: Download files (per-language dirs) --
    if not args.skip_download:
        print(f"\n[Step 3] Downloading source files to {CSN_FILES_DIR}/...")
        download_files(files_by_lang)
        _SHA_TO_DIR.clear()
        _build_sha_map()
    else:
        n = sum(1 for _ in CSN_FILES_DIR.rglob("*") if _.is_file()) if CSN_FILES_DIR.exists() else 0
        print(f"\n[Step 3] Skipped - {n} files already in {CSN_FILES_DIR}")

    # -- Step 4: Index per-language collections --
    if not args.skip_index:
        print(f"\n[Step 4] Indexing per-language QMD collections...")
        ok = index_into_qmd(active_langs)
        if not ok:
            print("  WARNING: some languages failed to index")
    else:
        colls = [_collection_name(l) for l in active_langs]
        print(f"\n[Step 4] Skipped - using existing collections: {', '.join(colls)}")

    # -- Step 5+6: Eval --
    print(f"\n[Step 5] Running {len(queries)} queries through QMD hybrid search...")
    result = run_evaluation(queries, top_k=args.top_k, verbose=args.verbose)

    print_results(result)
    write_summary(result)


if __name__ == "__main__":
    main()
