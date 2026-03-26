"""
Evaluation metrics for code retrieval benchmarks.

Implements:
- Recall@k: Fraction of queries where the correct item appears in top-k
- NDCG@k: Normalized Discounted Cumulative Gain (rewards items ranked higher)
- MRR@k: Mean Reciprocal Rank (average rank of first correct item)
- Graded NDCG@k: NDCG with multi-level relevance (0-3), used for CodeSearchNet
"""

import math
from typing import List, Optional


def _mean(values: List[float]) -> float:
    """Compute mean of a list."""
    if not values:
        return 0.0
    return sum(values) / len(values)


def _std(values: List[float]) -> float:
    """Compute population standard deviation."""
    if not values:
        return 0.0
    m = _mean(values)
    variance = sum((x - m) ** 2 for x in values) / len(values)
    return math.sqrt(variance)


def recall_at_k(predicted_ids: List[str], ground_truth_ids: List[str], k: int) -> float:
    """
    Recall@k: Did the correct answer appear anywhere in the top-k results?
    
    Args:
        predicted_ids: Ranked list of prediction IDs (top-k)
        ground_truth_ids: List of acceptable ground-truth IDs
        k: Cutoff rank
        
    Returns:
        1.0 if any ground_truth_id is in predicted_ids[:k], else 0.0
    """
    predicted_at_k = set(predicted_ids[:k])
    ground_truth_set = set(ground_truth_ids)
    
    # If there's any intersection, we found the answer
    if predicted_at_k & ground_truth_set:
        return 1.0
    return 0.0


def ndcg_at_k(predicted_ids: List[str], ground_truth_ids: List[str], k: int) -> float:
    """
    NDCG@k: Normalized Discounted Cumulative Gain.
    Rewards correct items ranked higher (position 1 > position 5).
    
    Args:
        predicted_ids: Ranked list of prediction IDs
        ground_truth_ids: List of acceptable ground-truth IDs
        k: Cutoff rank
        
    Returns:
        NDCG@k score in range [0, 1]
    """
    ground_truth_set = set(ground_truth_ids)
    
    # Compute DCG@k
    dcg = 0.0
    for i in range(min(k, len(predicted_ids))):
        if predicted_ids[i] in ground_truth_set:
            # Discount factor: log2(position + 1), so position 1 gets 1/log2(2) = 1.0
            discount = 1.0 / math.log2(i + 2)  # i+2 because position is 1-indexed
            dcg += discount
    
    # Compute IDCG@k (ideal ranking - all ground truths first)
    # If there are N ground truths, IDCG = sum(1/log2(i+2)) for i in 0..min(N-1, k-1)
    num_ground_truths = len(ground_truth_ids)
    idcg = 0.0
    for i in range(min(num_ground_truths, k)):
        discount = 1.0 / math.log2(i + 2)
        idcg += discount
    
    # Normalize: DCG / IDCG
    if idcg == 0:
        return 0.0
    return dcg / idcg


def mrr_at_k(predicted_ids: List[str], ground_truth_ids: List[str], k: int) -> float:
    """
    MRR@k: Mean Reciprocal Rank.
    Returns 1/rank of the first correct item, 0 if not found in top-k.
    
    Args:
        predicted_ids: Ranked list of prediction IDs
        ground_truth_ids: List of acceptable ground-truth IDs
        k: Cutoff rank
        
    Returns:
        1/rank if found, else 0.0
    """
    ground_truth_set = set(ground_truth_ids)
    
    for i in range(min(k, len(predicted_ids))):
        if predicted_ids[i] in ground_truth_set:
            return 1.0 / (i + 1)  # Rank is 1-indexed
    
    return 0.0


def compute_metrics(predicted_ids: List[str], ground_truth_ids: List[str], k: int):
    """
    Compute all metrics for a single query.
    
    Args:
        predicted_ids: Ranked list of predictions
        ground_truth_ids: List of acceptable answers
        k: Cutoff rank
        
    Returns:
        Dict with recall, ndcg, mrr scores
    """
    return {
        "recall": recall_at_k(predicted_ids, ground_truth_ids, k),
        "ndcg": ndcg_at_k(predicted_ids, ground_truth_ids, k),
        "mrr": mrr_at_k(predicted_ids, ground_truth_ids, k),
    }


def aggregate_metrics(results: List[dict], k: int):
    """
    Aggregate metrics across multiple queries.
    
    Args:
        results: List of dicts with "recall", "ndcg", "mrr" keys
        k: For display purposes
        
    Returns:
        Dict with mean metrics
    """
    if not results:
        return {"recall": 0.0, "ndcg": 0.0, "mrr": 0.0}
    
    recall_scores = [r["recall"] for r in results]
    ndcg_scores = [r["ndcg"] for r in results]
    mrr_scores = [r["mrr"] for r in results]
    
    return {
        "recall_at_k": _mean(recall_scores),
        "ndcg_at_k": _mean(ndcg_scores),
        "mrr_at_k": _mean(mrr_scores),
        "std_recall": _std(recall_scores),
        "std_ndcg": _std(ndcg_scores),
        "std_mrr": _std(mrr_scores),
        "num_queries": len(results),
    }


# ─────────────────────────────────────────────────────────────────────────────
# Graded NDCG — for CodeSearchNet (relevance 0–3)
# ─────────────────────────────────────────────────────────────────────────────

def graded_ndcg_at_k(predicted_ids: List[str], grade_map: dict, k: int) -> float:
    """
    Graded NDCG@k using multi-level relevance (0–3), matching RANGER / CSN eval.

    Formula:
        DCG  = Σ (2^rel_i - 1) / log2(i + 2)   for i in 0..k-1
        IDCG = DCG of the ideal (sorted by grade desc) ordering
        NDCG = DCG / IDCG

    Args:
        predicted_ids: Ranked list of file IDs returned by the search tool.
        grade_map:     Dict mapping file_id → int relevance grade (0–3).
                       Files not present are treated as grade 0.
        k:             Cutoff rank.

    Returns:
        Graded NDCG@k in [0, 1]. Returns 0 if no annotated file has grade > 0.
    """
    def gain(grade: int) -> float:
        return 2 ** grade - 1

    # DCG for the predicted ranking
    dcg = 0.0
    for i, fid in enumerate(predicted_ids[:k]):
        rel = grade_map.get(fid, 0)
        if rel > 0:
            dcg += gain(rel) / math.log2(i + 2)

    # IDCG: sort all annotated files by grade descending, take top-k
    all_grades = sorted(grade_map.values(), reverse=True)
    idcg = 0.0
    for i, rel in enumerate(all_grades[:k]):
        if rel > 0:
            idcg += gain(rel) / math.log2(i + 2)

    if idcg == 0.0:
        return 0.0
    return dcg / idcg


def aggregate_graded_metrics(results: List[dict]) -> dict:
    """
    Aggregate graded NDCG + MRR across CSN queries.

    Args:
        results: List of dicts with "graded_ndcg", "mrr" keys.
    """
    if not results:
        return {}
    ndcg_scores   = [r["graded_ndcg"] for r in results]
    mrr_scores    = [r["mrr"] for r in results]
    recall_scores = [r.get("recall", 0.0) for r in results]
    return {
        "graded_ndcg_at_k": _mean(ndcg_scores),
        "mrr_at_k":         _mean(mrr_scores),
        "recall_at_k":      _mean(recall_scores),
        "std_ndcg":         _std(ndcg_scores),
        "std_mrr":          _std(mrr_scores),
        "std_recall":       _std(recall_scores),
        "num_queries":      len(results),
    }
