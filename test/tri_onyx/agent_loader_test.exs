defmodule TriOnyx.AgentLoaderTest do
  use ExUnit.Case

  alias TriOnyx.AgentLoader
  alias TriOnyx.AgentDefinition

  @valid_agent """
  ---
  name: test-agent
  description: A test agent
  tools: Read, Grep
  model: claude-sonnet-4-20250514
  ---

  You are a test agent.
  """

  @another_agent """
  ---
  name: another-agent
  tools: Write, Edit
  ---

  Another agent.
  """

  @invalid_agent """
  This is not a valid agent definition.
  No frontmatter here.
  """

  setup do
    # Create a temporary directory with test agent files
    tmp_dir = Path.join(System.tmp_dir!(), "tri_onyx_test_agents_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp_dir)

    on_cleanup = fn ->
      File.rm_rf!(tmp_dir)
    end

    %{tmp_dir: tmp_dir, cleanup: on_cleanup}
  end

  describe "load_from/1" do
    test "loads valid agent definitions from directory", %{tmp_dir: dir, cleanup: cleanup} do
      File.write!(Path.join(dir, "test-agent.md"), @valid_agent)
      File.write!(Path.join(dir, "another-agent.md"), @another_agent)

      assert {:ok, definitions} = AgentLoader.load_from(dir)
      assert length(definitions) == 2

      names = Enum.map(definitions, & &1.name)
      assert "another-agent" in names
      assert "test-agent" in names

      cleanup.()
    end

    test "skips invalid files and logs warnings", %{tmp_dir: dir, cleanup: cleanup} do
      File.write!(Path.join(dir, "valid.md"), @valid_agent)
      File.write!(Path.join(dir, "invalid.md"), @invalid_agent)

      assert {:ok, definitions} = AgentLoader.load_from(dir)
      assert length(definitions) == 1
      assert hd(definitions).name == "test-agent"

      cleanup.()
    end

    test "returns empty list for directory with no .md files", %{tmp_dir: dir, cleanup: cleanup} do
      File.write!(Path.join(dir, "readme.txt"), "not a markdown file")

      assert {:ok, []} = AgentLoader.load_from(dir)

      cleanup.()
    end

    test "returns error for non-existent directory" do
      assert {:error, :directory_not_found} = AgentLoader.load_from("/nonexistent/path")
    end

    test "returns correct tool lists for loaded agents", %{tmp_dir: dir, cleanup: cleanup} do
      File.write!(Path.join(dir, "test-agent.md"), @valid_agent)
      File.write!(Path.join(dir, "another-agent.md"), @another_agent)

      assert {:ok, definitions} = AgentLoader.load_from(dir)

      test_agent = Enum.find(definitions, &(&1.name == "test-agent"))
      assert test_agent.tools == ["Read", "Grep"]

      another_agent = Enum.find(definitions, &(&1.name == "another-agent"))
      assert another_agent.tools == ["Write", "Edit"]

      cleanup.()
    end
  end
end
