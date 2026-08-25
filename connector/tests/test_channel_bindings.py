"""Tests for Slack channel name derivation from GitHub repos."""

import pytest

from connector.channel_bindings import (
    _MAX_CHANNEL_NAME_LEN,
    _resolve_names,
    channel_name_for_repo,
)


class TestChannelNameForRepo:
    def test_uses_repo_name_with_prefix(self):
        assert channel_name_for_repo("myorg/my-repo", "gh-") == "gh-my-repo"

    def test_sanitizes_to_slack_rules(self):
        assert channel_name_for_repo("MyOrg/My.Repo_Name", "gh-") == "gh-my-repo_name"
        assert channel_name_for_repo("o/repo--with---dots...", "gh-") == "gh-repo--with---dots"

    def test_qualified_includes_owner(self):
        assert channel_name_for_repo("myorg/api", "gh-", qualified=True) == "gh-myorg-api"

    def test_truncates_to_slack_limit(self):
        name = channel_name_for_repo("o/" + "x" * 200, "gh-")
        assert len(name) <= 80
        assert name.startswith("gh-")

    def test_custom_prefix(self):
        assert channel_name_for_repo("o/repo", "repo-") == "repo-repo"


class TestResolveNames:
    def test_skips_bindings_with_explicit_channel(self):
        bindings = [
            {"agent": "a", "github_repo": "o/x", "slack_channel": "C123"},
            {"agent": "b", "github_repo": "o/y", "slack_channel": None},
        ]
        names = _resolve_names(bindings, "gh-")
        assert "a" not in names
        assert names["b"] == "gh-y"

    def test_collision_qualifies_with_owner(self):
        bindings = [
            {"agent": "a", "github_repo": "org1/api", "slack_channel": None},
            {"agent": "b", "github_repo": "org2/api", "slack_channel": None},
        ]
        names = _resolve_names(bindings, "gh-")
        assert names["a"] == "gh-api"
        assert names["b"] == "gh-org2-api"

    def test_ignores_bindings_without_repo(self):
        bindings = [{"agent": "a", "github_repo": None, "slack_channel": None}]
        assert _resolve_names(bindings, "gh-") == {}

    def test_two_agents_never_share_a_channel(self):
        """Same owner *and* same repo name: the owner qualifier cannot break
        the tie, so a numeric suffix must."""
        bindings = [
            {"agent": "a", "github_repo": "org/api", "slack_channel": None},
            {"agent": "b", "github_repo": "org/api", "slack_channel": None},
            {"agent": "c", "github_repo": "org/api", "slack_channel": None},
        ]
        names = _resolve_names(bindings, "gh-")
        assert names == {"a": "gh-api", "b": "gh-org-api", "c": "gh-org-api-2"}
        assert len(set(names.values())) == 3

    def test_names_stay_unique_after_truncation(self):
        """Long repo names all truncate to the same prefix — still unique."""
        long_name = "x" * 200
        bindings = [
            {"agent": f"a{i}", "github_repo": f"org/{long_name}", "slack_channel": None}
            for i in range(4)
        ]
        names = _resolve_names(bindings, "gh-")
        assert len(set(names.values())) == 4
        assert all(len(n) <= _MAX_CHANNEL_NAME_LEN for n in names.values())

    def test_hard_fails_when_no_unique_name_is_left(self):
        bindings = [
            {"agent": f"a{i}", "github_repo": "org/api", "slack_channel": None}
            for i in range(60)
        ]
        with pytest.raises(ValueError, match="unique Slack channel name"):
            _resolve_names(bindings, "gh-")
