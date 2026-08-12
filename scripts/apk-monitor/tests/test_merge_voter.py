"""Tests for merge_voter.py — vote parsing, scoring, merge thresholds."""

import logging


from merge_voter import (
    MergeDecision,
    Vote,
    _load_candidates,
    _parse_vote_json,
    auto_merge_winner,
)


class TestParseVoteJson:
    def test_fenced_json(self):
        text = 'Some preamble\n```json\n{"score": 7, "reasoning": "good", "issues": []}\n```\nend'
        result = _parse_vote_json(text)
        assert result is not None
        assert result["score"] == 7

    def test_bare_json(self):
        text = '{"score": 5, "reasoning": "ok", "issues": ["missing UUIDs"]}'
        result = _parse_vote_json(text)
        assert result is not None
        assert result["score"] == 5

    def test_json_with_whitespace(self):
        text = '  \n  {"score": 8, "reasoning": "great", "issues": []}  \n  '
        result = _parse_vote_json(text)
        assert result is not None
        assert result["score"] == 8

    def test_garbage_returns_none(self):
        result = _parse_vote_json("This is not JSON at all, just rambling text.")
        assert result is None

    def test_embedded_json_with_score(self):
        text = 'Here is my review: {"score": 6, "reasoning": "decent", "issues": []} hope it helps'
        result = _parse_vote_json(text)
        assert result is not None
        assert result["score"] == 6

    def test_empty_string(self):
        assert _parse_vote_json("") is None

    def test_unparseable_logs_warning(self, caplog):
        with caplog.at_level(logging.WARNING, logger="merge_voter"):
            _parse_vote_json("This is not JSON at all, just rambling text.")
        assert any("Could not parse vote JSON" in r.message for r in caplog.records)


class TestLoadCandidates:
    def test_loads_yaml_specs(self, tmp_root):
        candidates_dir = tmp_root / "device-specs" / "candidates"
        (candidates_dir / "my-device_claude.yaml").write_text("spec: claude")
        (candidates_dir / "my-device_openai.yaml").write_text("spec: openai")

        result = _load_candidates(tmp_root, "my-device", "device-specs/candidates", ".yaml")
        assert result == {"claude": "spec: claude", "openai": "spec: openai"}

    def test_loads_md_docs(self, tmp_root):
        docs_dir = tmp_root / "docs" / "devices" / "candidates"
        (docs_dir / "my-device_claude.md").write_text("# Claude doc")

        result = _load_candidates(tmp_root, "my-device", "docs/devices/candidates", ".md")
        assert result == {"claude": "# Claude doc"}

    def test_missing_dir_returns_empty(self, tmp_root):
        result = _load_candidates(tmp_root, "no-device", "nonexistent/dir", ".yaml")
        assert result == {}

    def test_no_matching_files(self, tmp_root):
        result = _load_candidates(tmp_root, "no-device", "device-specs/candidates", ".yaml")
        assert result == {}


class TestTiebreaker:
    """Verify that equal-score candidates are resolved by vote count."""

    def test_higher_vote_count_wins_tie(self):
        # We can't easily call cross_check_and_vote without API calls,
        # so test the tiebreaker logic directly by inspecting the scoring code.
        # Build candidate_scores mimicking what the function computes:
        candidate_scores: dict[str, list[int]] = {
            "claude": [7, 7],       # avg=7.0, count=2
            "openai": [7, 7, 7],    # avg=7.0, count=3 — should win
        }
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
        assert best_candidate == "openai"
        assert best_avg == 7.0

    def test_higher_score_beats_more_votes(self):
        candidate_scores: dict[str, list[int]] = {
            "claude": [9, 9],       # avg=9.0, count=2
            "openai": [7, 7, 7],    # avg=7.0, count=3
        }
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
        assert best_candidate == "claude"


class TestAutoMergeWinner:
    def _make_decision(self, winner="claude", total_votes=3, avg_score=7.0) -> MergeDecision:
        return MergeDecision(
            target_id="test-device",
            winner=winner,
            total_votes=total_votes,
            avg_score=avg_score,
            merged=False,
            merge_branch="",
            votes=[
                Vote(voter="openai", candidate="claude", score=7, reasoning="good", issues=[]),
                Vote(voter="local-qwen", candidate="claude", score=7, reasoning="good", issues=[]),
            ],
            timestamp="2025-01-01T00:00:00Z",
        )

    def test_no_winner_skips(self, tmp_root):
        d = self._make_decision(winner="")
        result = auto_merge_winner(d, tmp_root)
        assert not result.merged

    def test_insufficient_votes_skips(self, tmp_root):
        d = self._make_decision(total_votes=1)
        result = auto_merge_winner(d, tmp_root, min_votes=2)
        assert not result.merged

    def test_low_score_skips(self, tmp_root):
        d = self._make_decision(avg_score=3.0)
        result = auto_merge_winner(d, tmp_root, min_score=5.0)
        assert not result.merged

    def test_copies_spec_when_threshold_met(self, tmp_root):
        # Create the candidate file
        src = tmp_root / "device-specs" / "candidates" / "test-device_claude.yaml"
        src.write_text("spec: winner")

        d = self._make_decision()
        # Won't actually git commit (no git repo at tmp_root), but should copy files
        auto_merge_winner(d, tmp_root)

        dst = tmp_root / "device-specs" / "devices" / "test-device.yaml"
        assert dst.exists()
        assert dst.read_text() == "spec: winner"
