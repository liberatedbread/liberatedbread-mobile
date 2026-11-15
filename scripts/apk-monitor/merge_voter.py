#!/usr/bin/env python3
"""Cross-check RE agent results and vote on the best spec to merge.

Each agent produces a candidate device spec and protocol doc.  This module:
1. Loads all agent results for a given target.
2. Sends each agent's output to the OTHER agents for review (cross-checking).
3. Collects votes on which spec is most complete/accurate.
4. If a winner gets enough votes, auto-merges it into the main branch.
"""

import json
import logging
import re
import shutil
import subprocess
import textwrap
from dataclasses import dataclass, asdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

from config import DEFAULT_OPENAI_BASE_URL, ModelConfig
from re_agents import _call_anthropic, _call_openai

log = logging.getLogger("merge_voter")


@dataclass
class Vote:
    voter: str        # agent name that cast this vote
    candidate: str    # agent name whose spec is being voted on
    score: int        # 1-10
    reasoning: str
    issues: list[str]


@dataclass
class MergeDecision:
    target_id: str
    winner: str           # agent name with best spec
    total_votes: int
    avg_score: float
    merged: bool
    merge_branch: str
    votes: list[Vote]
    timestamp: str


def _load_candidates(root_dir: Path, target_id: str,
                     subdir: str, extension: str) -> dict[str, str]:
    """Load candidate files from a subdirectory.

    Args:
        subdir: Relative path under root_dir (e.g. "device-specs/candidates").
        extension: File extension including dot (e.g. ".yaml").
    """
    candidates: dict[str, str] = {}
    candidates_dir = root_dir / subdir
    if not candidates_dir.exists():
        return candidates
    for f in candidates_dir.glob(f"{target_id}_*{extension}"):
        agent_name = f.stem.replace(f"{target_id}_", "")
        candidates[agent_name] = f.read_text()
    return candidates


def _build_review_prompt(target_id: str, candidate_agent: str,
                         spec_yaml: str, protocol_doc: str,
                         all_specs: dict[str, str]) -> str:
    """Build the prompt for a reviewer agent to score a candidate."""
    other_specs = ""
    for name, spec in all_specs.items():
        if name != candidate_agent:
            other_specs += f"\n### {name}'s spec (for comparison)\n```yaml\n{spec[:3000]}\n```\n"

    return textwrap.dedent(f"""\
    # Review Task: Evaluate RE Spec for {target_id}

    You are reviewing the reverse-engineering output from agent "{candidate_agent}".
    Score it on completeness, accuracy, and usefulness.

    ## Candidate Spec (by {candidate_agent})
    ```yaml
    {spec_yaml[:5000]}
    ```

    ## Candidate Protocol Doc (by {candidate_agent})
    ```markdown
    {protocol_doc[:5000]}
    ```

    ## Other Agents' Specs (for comparison)
    {other_specs}

    ## Scoring Criteria
    1. **Completeness** (1-10): Are all GATT services/characteristics documented?
    2. **Accuracy** (1-10): Are UUIDs, opcodes, and formats correct and well-evidenced?
    3. **Usefulness** (1-10): Could someone build a replacement app from this spec?
    4. **Clean-room compliance** (pass/fail): No vendor source code or UI copy?

    ## Required Output Format (JSON only)
    ```json
    {{
      "score": <1-10 overall>,
      "reasoning": "<2-3 sentences>",
      "issues": ["<issue 1>", "<issue 2>"],
      "clean_room_pass": true
    }}
    ```
    Return ONLY the JSON block above, nothing else.
    """)


def _parse_vote_json(text: str) -> Optional[dict]:
    """Extract and parse JSON from a model response."""
    # Try fenced ```json block first
    match = re.search(r"```json\s*\n(.*?)```", text, re.DOTALL)
    if match:
        try:
            return json.loads(match.group(1))
        except json.JSONDecodeError:
            pass
    # Try parsing the whole response as JSON
    try:
        return json.loads(text.strip())
    except json.JSONDecodeError:
        pass
    # Try finding any JSON object containing "score"
    match = re.search(r"\{[^{}]*\"score\"[^{}]*\}", text, re.DOTALL)
    if match:
        try:
            return json.loads(match.group(0))
        except json.JSONDecodeError:
            pass
    log.warning("Could not parse vote JSON from response: %s", text[:200])
    return None


def _call_reviewer(
    reviewer_name: str,
    prompt: str,
    model: str,
    api_key: str,
    base_url: str = "",
) -> Optional[dict]:
    """Call a reviewer model and parse its vote."""
    system = "You are a code reviewer specializing in BLE/Bluetooth protocol specifications. Return only valid JSON."

    try:
        if reviewer_name == "claude":
            text, _ = _call_anthropic(system, prompt, model, api_key)
        else:
            url = base_url or DEFAULT_OPENAI_BASE_URL
            text, _ = _call_openai(system, prompt, model, api_key, url)
    except Exception as exc:
        log.warning("Reviewer %s failed: %s", reviewer_name, exc)
        return None

    return _parse_vote_json(text)


def cross_check_and_vote(
    target_id: str,
    root_dir: Path,
    models: ModelConfig,
) -> MergeDecision:
    """Have each agent review the others' specs and vote."""
    specs = _load_candidates(root_dir, target_id, "device-specs/candidates", ".yaml")
    docs = _load_candidates(root_dir, target_id, "docs/devices/candidates", ".md")

    if not specs:
        log.warning("No candidate specs found for %s", target_id)
        return MergeDecision(
            target_id=target_id, winner="", total_votes=0, avg_score=0.0,
            merged=False, merge_branch="", votes=[],
            timestamp=datetime.now(timezone.utc).isoformat(),
        )

    reviewers = {name: (model, key, url) for name, model, key, url in models.agent_configs()}

    all_votes: list[Vote] = []

    for candidate_name in specs:
        spec_yaml = specs.get(candidate_name, "")
        protocol_doc = docs.get(candidate_name, "")

        for reviewer_name, (model, api_key, base_url) in reviewers.items():
            if reviewer_name == candidate_name:
                continue
            if not api_key and reviewer_name != "local-qwen":
                continue

            prompt = _build_review_prompt(target_id, candidate_name, spec_yaml, protocol_doc, specs)
            vote_data = _call_reviewer(reviewer_name, prompt, model, api_key, base_url)

            if vote_data:
                vote = Vote(
                    voter=reviewer_name,
                    candidate=candidate_name,
                    score=int(vote_data.get("score", 0)),
                    reasoning=vote_data.get("reasoning", ""),
                    issues=vote_data.get("issues", []),
                )
                all_votes.append(vote)
                log.info("Vote: %s gives %s score=%d", reviewer_name, candidate_name, vote.score)

    # Tally scores per candidate
    candidate_scores: dict[str, list[int]] = {}
    for v in all_votes:
        candidate_scores.setdefault(v.candidate, []).append(v.score)

    best_candidate = ""
    best_avg = 0.0
    best_vote_count = 0
    for candidate, scores in candidate_scores.items():
        avg = sum(scores) / len(scores) if scores else 0
        count = len(scores)
        if (avg, count) > (best_avg, best_vote_count):
            best_avg = avg
            best_vote_count = count
            best_candidate = candidate

    if not best_candidate and candidate_scores:
        log.warning("No candidate scored above 0 for %s", target_id)

    return MergeDecision(
        target_id=target_id,
        winner=best_candidate,
        total_votes=len(all_votes),
        avg_score=best_avg,
        merged=False,
        merge_branch="",
        votes=all_votes,
        timestamp=datetime.now(timezone.utc).isoformat(),
    )


def auto_merge_winner(
    decision: MergeDecision,
    root_dir: Path,
    min_votes: int = 2,
    min_score: float = 5.0,
) -> MergeDecision:
    """If the winner meets thresholds, copy their spec into the final locations and commit."""
    if not decision.winner:
        log.info("No winner for %s — skipping merge", decision.target_id)
        return decision

    if decision.total_votes < min_votes:
        log.info("Not enough votes (%d < %d) for %s — skipping merge",
                 decision.total_votes, min_votes, decision.target_id)
        return decision

    if decision.avg_score < min_score:
        log.info("Score too low (%.1f < %.1f) for %s — skipping merge",
                 decision.avg_score, min_score, decision.target_id)
        return decision

    src_spec = root_dir / "device-specs" / "candidates" / f"{decision.target_id}_{decision.winner}.yaml"
    dst_spec = root_dir / "device-specs" / "devices" / f"{decision.target_id}.yaml"
    dst_spec.parent.mkdir(parents=True, exist_ok=True)

    src_doc = root_dir / "docs" / "devices" / "candidates" / f"{decision.target_id}_{decision.winner}.md"
    dst_doc = root_dir / "docs" / "devices" / f"{decision.target_id}.md"

    files_to_commit: list[str] = []

    if src_spec.exists():
        shutil.copy2(src_spec, dst_spec)
        files_to_commit.append(str(dst_spec.relative_to(root_dir)))

    if src_doc.exists():
        shutil.copy2(src_doc, dst_doc)
        files_to_commit.append(str(dst_doc.relative_to(root_dir)))

    # Save the vote decision as metadata
    decision_dir = root_dir / "workspace" / "apk-monitor" / "decisions"
    decision_dir.mkdir(parents=True, exist_ok=True)
    decision_file = decision_dir / f"{decision.target_id}.json"
    with open(decision_file, "w") as f:
        json.dump(asdict(decision), f, indent=2, default=str)

    if files_to_commit:
        branch = f"re-merged/{decision.target_id}/{datetime.now(timezone.utc).strftime('%Y%m%d')}"
        branch_created = False
        try:
            subprocess.run(
                ["git", "checkout", "-b", branch],
                cwd=root_dir, capture_output=True, check=True,
            )
            branch_created = True
            for fpath in files_to_commit:
                subprocess.run(
                    ["git", "add", fpath],
                    cwd=root_dir, capture_output=True, check=True,
                )
            msg = (
                f"Add RE spec for {decision.target_id} "
                f"(winner: {decision.winner}, "
                f"score: {decision.avg_score:.1f}/{decision.total_votes} votes)"
            )
            subprocess.run(
                ["git", "commit", "-m", msg],
                cwd=root_dir, capture_output=True, check=True,
            )
            decision.merged = True
            decision.merge_branch = branch
            log.info("Merged spec for %s on branch %s", decision.target_id, branch)
        except subprocess.CalledProcessError as exc:
            log.error(
                "Merge commit failed for %s on branch %s: %s",
                decision.target_id, branch if branch_created else "(not created)", exc,
            )

    return decision


if __name__ == "__main__":
    import sys
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")

    if len(sys.argv) < 2:
        print("Usage: merge_voter.py <target_id>")
        sys.exit(1)

    target_id = sys.argv[1]
    root = Path(__file__).resolve().parents[2]

    from config import load_config
    cfg = load_config()
    mc = ModelConfig.from_cfg(cfg)

    decision = cross_check_and_vote(target_id=target_id, root_dir=root, models=mc)
    decision = auto_merge_winner(decision, root)
    print(json.dumps(asdict(decision), indent=2, default=str))
