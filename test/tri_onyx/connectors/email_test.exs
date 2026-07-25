defmodule TriOnyx.Connectors.EmailTest do
  use ExUnit.Case, async: true

  alias TriOnyx.Connectors.Email

  @tmp_dir "tmp/test-email-#{:erlang.unique_integer([:positive])}"

  setup do
    File.mkdir_p!(@tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    %{tmp_dir: @tmp_dir}
  end

  describe "send_email/1 — draft validation" do
    test "rejects missing draft file" do
      assert {:error, msg} = Email.send_email("/nonexistent/draft.json")
      assert msg =~ "cannot read draft"
    end

    test "rejects invalid JSON" do
      path = Path.join(@tmp_dir, "bad.json")
      File.write!(path, "not json")
      assert {:error, "invalid JSON in draft file"} = Email.send_email(path)
    end

    test "rejects draft missing 'to' field" do
      path = Path.join(@tmp_dir, "no-to.json")
      File.write!(path, Jason.encode!(%{"subject" => "Hi", "body" => "Hello"}))
      assert {:error, "missing required field: to"} = Email.send_email(path)
    end

    test "rejects draft missing 'subject' field" do
      path = Path.join(@tmp_dir, "no-subject.json")
      File.write!(path, Jason.encode!(%{"to" => "a@b.com", "body" => "Hello"}))
      assert {:error, "missing required field: subject"} = Email.send_email(path)
    end

    test "rejects draft missing 'body' field" do
      path = Path.join(@tmp_dir, "no-body.json")
      File.write!(path, Jason.encode!(%{"to" => "a@b.com", "subject" => "Hi"}))
      assert {:error, "missing required field: body"} = Email.send_email(path)
    end

    test "rejects draft with empty 'to' field" do
      path = Path.join(@tmp_dir, "empty-to.json")
      File.write!(path, Jason.encode!(%{"to" => "", "subject" => "Hi", "body" => "Hello"}))
      assert {:error, "empty required field: to"} = Email.send_email(path)
    end

    test "rejects draft with invalid email address" do
      path = Path.join(@tmp_dir, "bad-email.json")
      File.write!(path, Jason.encode!(%{"to" => "not-an-email", "subject" => "Hi", "body" => "Hello"}))
      assert {:error, msg} = Email.send_email(path)
      assert msg =~ "invalid email address"
    end

    test "rejects draft with invalid cc email address" do
      path = Path.join(@tmp_dir, "bad-cc.json")

      File.write!(
        path,
        Jason.encode!(%{
          "to" => "valid@example.com",
          "cc" => "not-valid",
          "subject" => "Hi",
          "body" => "Hello"
        })
      )

      assert {:error, msg} = Email.send_email(path)
      assert msg =~ "invalid email address"
    end

    test "rejects when email not configured" do
      # With no :email config, send_email should fail at SMTP config step
      path = Path.join(@tmp_dir, "valid-draft.json")

      File.write!(
        path,
        Jason.encode!(%{
          "to" => "valid@example.com",
          "subject" => "Test",
          "body" => "Hello world"
        })
      )

      assert {:error, msg} = Email.send_email(path)
      assert msg =~ "email not configured"
    end
  end

  describe "move_email/4" do
    test "returns error when IMAP not configured" do
      agent_dir = Path.join(@tmp_dir, "agent")
      source = Path.join([agent_dir, "inbox", "12345"])
      File.mkdir_p!(source)
      File.write!(Path.join(source, "message.json"), "{}")

      assert {:error, msg} = Email.move_email("12345", "inbox", "receipts", agent_dir)
      assert msg =~ "IMAP not configured"

      # Source should NOT have been moved — no partial filesystem-only move
      assert File.dir?(source)
      refute File.dir?(Path.join([agent_dir, "receipts", "12345"]))
    end

    test "rejects path traversal in source_folder" do
      assert {:error, msg} = Email.move_email("12345", "../etc", "inbox", @tmp_dir)
      assert msg =~ "path traversal"
    end

    test "rejects path traversal in dest_folder" do
      assert {:error, msg} = Email.move_email("12345", "inbox", "../etc", @tmp_dir)
      assert msg =~ "path traversal"
    end

    test "rejects folder names with slashes" do
      assert {:error, msg} = Email.move_email("12345", "inbox/sub", "dest", @tmp_dir)
      assert msg =~ "path separators"
    end

    test "rejects folder names with special characters" do
      assert {:error, msg} = Email.move_email("12345", "inbox", "rec@ipts", @tmp_dir)
      assert msg =~ "alphanumeric"
    end

    test "returns error when source directory doesn't exist" do
      agent_dir = Path.join(@tmp_dir, "agent-empty")
      File.mkdir_p!(agent_dir)

      # The local scope check runs before the IMAP mutation, so a UID the
      # caller does not hold locally fails here rather than after the server
      # has already moved it.
      assert {:error, msg} = Email.move_email("99999", "inbox", "dest", agent_dir)
      assert msg =~ "source email directory not found"
    end

    test "rejects an IMAP sequence set as a uid" do
      # `1:*` would move the entire mailbox.
      assert {:error, msg} = Email.move_email("1:*", "inbox", "dest", @tmp_dir)
      assert msg =~ "invalid email uid"
    end

    test "rejects a uid carrying a CRLF-injected IMAP command" do
      assert {:error, msg} =
               Email.move_email("1\r\nX001 DELETE Sent", "inbox", "dest", @tmp_dir)

      assert msg =~ "invalid email uid"
    end

    test "rejects non-numeric, zero-prefixed, and out-of-range uids" do
      for uid <- ["abc", "", "0", "007", " 12", "12 ", "99999999999", "4294967296"] do
        assert {:error, msg} = Email.move_email(uid, "inbox", "dest", @tmp_dir),
               "expected #{inspect(uid)} to be rejected"

        assert msg =~ "invalid email uid"
      end
    end

    test "uid validation runs before folder validation and before any IMAP call" do
      # A bad uid must not depend on folder names or IMAP config to be caught.
      assert {:error, msg} = Email.move_email("1:*", "../etc", "../etc", @tmp_dir)
      assert msg =~ "invalid email uid"
    end

    test "accepts the maximum valid 32-bit uid (fails later, not on validation)" do
      assert {:error, msg} = Email.move_email("4294967295", "inbox", "dest", @tmp_dir)
      refute msg =~ "invalid email uid"
      assert msg =~ "source email directory not found"
    end
  end

  describe "Poller.parse_search_response/2" do
    alias TriOnyx.Connectors.Email.Poller

    test "returns only UIDs above the high-water mark, sorted" do
      resp = "* SEARCH 12 15 13\r\nA003 OK SEARCH completed\r\n"
      assert Poller.parse_search_response(resp, 11) == ["12", "13", "15"]
    end

    test "drops the reversed-range echo when the newest message was moved away" do
      # `UID SEARCH UID 43:*` against a mailbox whose highest UID is now 40:
      # the server evaluates the range reversed and answers with 40. That UID
      # is already processed and must not be re-fetched.
      resp = "* SEARCH 40\r\nA003 OK SEARCH completed\r\n"
      assert Poller.parse_search_response(resp, 42) == []
    end

    test "excludes the high-water mark itself" do
      resp = "* SEARCH 42\r\nA003 OK SEARCH completed\r\n"
      assert Poller.parse_search_response(resp, 42) == []
    end

    test "ignores non-numeric tokens" do
      resp = "* SEARCH 12 bogus 14\r\nA003 OK SEARCH completed\r\n"
      assert Poller.parse_search_response(resp, 0) == ["12", "14"]
    end

    test "returns empty when the server reports no matches" do
      assert Poller.parse_search_response("A003 OK SEARCH completed\r\n", 5) == []
    end
  end

  describe "create_folder/2" do
    test "returns error when IMAP not configured" do
      agent_dir = Path.join(@tmp_dir, "agent-folder")
      File.mkdir_p!(agent_dir)

      assert {:error, msg} = Email.create_folder("receipts", agent_dir)
      assert msg =~ "IMAP not configured"
    end

    test "rejects folder names with path traversal" do
      assert {:error, msg} = Email.create_folder("..", @tmp_dir)
      assert msg =~ "path traversal"
    end

    test "rejects folder names with slashes" do
      assert {:error, msg} = Email.create_folder("a/b", @tmp_dir)
      assert msg =~ "path separators"
    end

    test "rejects folder names with special characters" do
      assert {:error, msg} = Email.create_folder("my folder!", @tmp_dir)
      assert msg =~ "alphanumeric"
    end

    test "accepts valid folder names with hyphens and underscores (fails on IMAP, not validation)" do
      agent_dir = Path.join(@tmp_dir, "agent-valid")
      File.mkdir_p!(agent_dir)

      # These pass validation but fail because IMAP is not configured in test
      assert {:error, msg} = Email.create_folder("important-emails", agent_dir)
      assert msg =~ "IMAP not configured"

      assert {:error, _} = Email.create_folder("work_items", agent_dir)
      assert {:error, _} = Email.create_folder("Archive2024", agent_dir)
    end
  end

  describe "write_email_dir/4" do
    test "writes message.json and attachment files" do
      base_dir = Path.join(@tmp_dir, "inbox")

      message = %{
        "from" => "sender@example.com",
        "subject" => "Test email",
        "body_text" => "Hello"
      }

      attachments = [
        {"report.pdf", "pdf-content-here"},
        {"data.csv", "col1,col2\na,b"}
      ]

      assert {:ok, files} = Email.write_email_dir(base_dir, "12345", message, attachments)

      assert length(files) == 3
      assert File.exists?(Path.join([base_dir, "12345", "message.json"]))

      json = Jason.decode!(File.read!(Path.join([base_dir, "12345", "message.json"])))
      assert json["uid"] == "12345"
      assert json["from"] == "sender@example.com"

      # Attachments are prefixed with index
      assert File.exists?(Path.join([base_dir, "12345", "attachment-1-report.pdf"]))
      assert File.exists?(Path.join([base_dir, "12345", "attachment-2-data.csv"]))
    end

    test "writes message.json without attachments" do
      base_dir = Path.join(@tmp_dir, "inbox-no-attach")

      message = %{"from" => "sender@example.com", "subject" => "No attachments"}

      assert {:ok, files} = Email.write_email_dir(base_dir, "12346", message, [])
      assert length(files) == 1
    end
  end
end
