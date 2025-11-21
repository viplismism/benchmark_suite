#!/usr/bin/env python3
"""
Compare benchmark results between different model runs
"""

import json
import sys
import os
from pathlib import Path
from typing import Dict, List
from datetime import datetime

def load_aggregate_results(results_dir: str) -> Dict:
    """Load aggregate_results.json from a results directory"""
    aggregate_file = Path(results_dir) / "aggregate_results.json"
    if not aggregate_file.exists():
        raise FileNotFoundError(f"No aggregate results found in {results_dir}")
    
    with open(aggregate_file) as f:
        return json.load(f)

def compare_benchmarks(baseline: Dict, current: Dict) -> Dict:
    """Compare two benchmark result sets"""
    comparison = {
        "baseline_model": baseline.get("model"),
        "current_model": current.get("model"),
        "baseline_timestamp": baseline.get("timestamp"),
        "current_timestamp": current.get("timestamp"),
        "improvements": [],
        "regressions": [],
        "unchanged": []
    }
    
    baseline_benchmarks = baseline.get("benchmarks", {})
    current_benchmarks = current.get("benchmarks", {})
    
    # Compare each benchmark
    for benchmark_name in set(baseline_benchmarks.keys()) | set(current_benchmarks.keys()):
        baseline_data = baseline_benchmarks.get(benchmark_name, {})
        current_data = current_benchmarks.get(benchmark_name, {})
        
        # Find the score metric
        score_key = None
        for key in ['resolve_rate', 'accuracy', 'pass_rate', 'success_rate']:
            if key in baseline_data or key in current_data:
                score_key = key
                break
        
        if not score_key:
            continue
        
        baseline_score = baseline_data.get(score_key, 0)
        current_score = current_data.get(score_key, 0)
        delta = current_score - baseline_score
        delta_pct = (delta / baseline_score * 100) if baseline_score > 0 else 0
        
        result = {
            "benchmark": benchmark_name,
            "baseline_score": baseline_score,
            "current_score": current_score,
            "delta": delta,
            "delta_pct": delta_pct
        }
        
        if delta > 0.5:  # Improvement threshold
            comparison["improvements"].append(result)
        elif delta < -0.5:  # Regression threshold
            comparison["regressions"].append(result)
        else:
            comparison["unchanged"].append(result)
    
    return comparison

def print_comparison(comparison: Dict):
    """Pretty print the comparison results"""
    print("\n" + "="*80)
    print("BENCHMARK COMPARISON RESULTS")
    print("="*80)
    print(f"Baseline:  {comparison['baseline_model']} ({comparison['baseline_timestamp']})")
    print(f"Current:   {comparison['current_model']} ({comparison['current_timestamp']})")
    print("="*80)
    
    # Improvements
    if comparison['improvements']:
        print("\n✓ IMPROVEMENTS:")
        print(f"{'Benchmark':<25} {'Baseline':<15} {'Current':<15} {'Delta':<15}")
        print("-"*80)
        for item in sorted(comparison['improvements'], key=lambda x: x['delta'], reverse=True):
            print(f"{item['benchmark']:<25} {item['baseline_score']:<15.1f} "
                  f"{item['current_score']:<15.1f} +{item['delta']:.1f} ({item['delta_pct']:+.1f}%)")
    
    # Regressions
    if comparison['regressions']:
        print("\n✗ REGRESSIONS:")
        print(f"{'Benchmark':<25} {'Baseline':<15} {'Current':<15} {'Delta':<15}")
        print("-"*80)
        for item in sorted(comparison['regressions'], key=lambda x: x['delta']):
            print(f"{item['benchmark']:<25} {item['baseline_score']:<15.1f} "
                  f"{item['current_score']:<15.1f} {item['delta']:.1f} ({item['delta_pct']:+.1f}%)")
    
    # Unchanged
    if comparison['unchanged']:
        print("\n→ UNCHANGED:")
        print(f"{'Benchmark':<25} {'Score':<15}")
        print("-"*80)
        for item in comparison['unchanged']:
            print(f"{item['benchmark']:<25} {item['current_score']:<15.1f}")
    
    print("\n" + "="*80)
    
    # Summary statistics
    total = len(comparison['improvements']) + len(comparison['regressions']) + len(comparison['unchanged'])
    improved = len(comparison['improvements'])
    regressed = len(comparison['regressions'])
    
    print(f"Total benchmarks: {total}")
    print(f"Improved: {improved} ({improved/total*100:.1f}%)")
    print(f"Regressed: {regressed} ({regressed/total*100:.1f}%)")
    print(f"Unchanged: {len(comparison['unchanged'])} ({len(comparison['unchanged'])/total*100:.1f}%)")
    print("="*80)

def save_comparison(comparison: Dict, output_file: str):
    """Save comparison results to file"""
    with open(output_file, 'w') as f:
        json.dump(comparison, f, indent=2)
    print(f"\nComparison saved to: {output_file}")

def main():
    if len(sys.argv) < 3:
        print("Usage: python compare_results.py <baseline_dir> <current_dir> [output_file]")
        print("\nExample:")
        print("  python compare_results.py \\")
        print("    benchmark_results/kat-72b/20250119_100000 \\")
        print("    benchmark_results/kat-72b/20250119_150000 \\")
        print("    comparison_results.json")
        sys.exit(1)
    
    baseline_dir = sys.argv[1]
    current_dir = sys.argv[2]
    output_file = sys.argv[3] if len(sys.argv) > 3 else "comparison_results.json"
    
    try:
        # Load results
        print(f"Loading baseline from: {baseline_dir}")
        baseline = load_aggregate_results(baseline_dir)
        
        print(f"Loading current from: {current_dir}")
        current = load_aggregate_results(current_dir)
        
        # Compare
        comparison = compare_benchmarks(baseline, current)
        
        # Display
        print_comparison(comparison)
        
        # Save
        save_comparison(comparison, output_file)
        
    except FileNotFoundError as e:
        print(f"Error: {e}")
        sys.exit(1)
    except Exception as e:
        print(f"Unexpected error: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)

if __name__ == "__main__":
    main()
