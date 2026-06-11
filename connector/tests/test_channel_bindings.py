"""Tests for Slack channel name derivation from GitHub repos."""

from connector.channel_bindings import _resolve_names, channel_name_for_repo


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
