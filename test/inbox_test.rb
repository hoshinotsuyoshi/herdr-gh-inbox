# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "tmpdir"
require "open3"
require "fileutils"
require "pty"
require "timeout"
require "io/console"
load File.expand_path("../bin/herdr-gh-inbox", __dir__)

class InboxTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir
    @log = File.join(@directory, "calls")
    ENV["FAKE_GH_LOG"] = @log
    ENV.delete("FAKE_GH_AUTH")
    ENV.delete("FAKE_GH_304")
    ENV.delete("FAKE_GH_PAGES")
    ENV.delete("FAKE_GH_ORDER")
    ENV.delete("FAKE_HERDR_LOG")
    ENV.delete("FAKE_HERDR_SPACES")
    ENV.delete("HERDR_GH_INBOX_AGENT_ARGV")
    ENV.delete("HERDR_GH_INBOX_TASK_TEMPLATE")
    ENV.delete("HERDR_GH_INBOX_REPO_DIRS")
    @out = StringIO.new
    @inbox = HerdrGhInbox::Inbox.new(gh: HerdrGhInbox::Gh.new(File.join(__dir__, "fixtures/fake-gh")), output: @out)
  end

  def teardown
    ENV.delete("FAKE_GH_LOG")
    ENV.delete("FAKE_GH_AUTH")
    ENV.delete("FAKE_GH_304")
    ENV.delete("FAKE_GH_PAGES")
    ENV.delete("FAKE_GH_ORDER")
    ENV.delete("FAKE_HERDR_LOG")
    ENV.delete("FAKE_HERDR_SPACES")
    ENV.delete("HERDR_GH_INBOX_AGENT_ARGV")
    ENV.delete("HERDR_GH_INBOX_TASK_TEMPLATE")
    ENV.delete("HERDR_GH_INBOX_REPO_DIRS")
    FileUtils.remove_entry(@directory)
  end

  def test_fetch_state_304_and_mark_read
    assert @inbox.fetch
    assert_equal 2, @inbox.items.size
    assert_equal 90, @inbox.interval
    assert_equal "\e]7501;state=blocked:kind=question\e\\", @out.string
    ENV["FAKE_GH_304"] = "1"
    refute @inbox.fetch
    assert_equal 2, @inbox.items.size
    assert_equal "\e]7501;state=blocked:kind=question\e\\", @out.string
    @inbox.mark(@inbox.items.first, "PATCH")
    assert_equal "\e]7501;state=blocked:kind=question\e\\\e]7501;state=done\e\\", @out.string
    @inbox.mark(@inbox.items.first, "DELETE")
    assert_equal "idle", @inbox.state_for_items
    assert_includes @out.string, "state=idle"
    assert_includes File.read(@log), "If-Modified-Since: Sun, 15 Nov 2026 12:00:00 GMT"
  end

  def test_detail_is_lazy_and_cached
    @inbox.fetch
    assert_equal 1, File.readlines(@log).length
    first = @inbox.items.first
    assert_equal "日本語の本文", @inbox.detail(first).first["body"]
    @inbox.detail(first)
    assert_equal 3, File.readlines(@log).length
  end

  def test_auth_status
    ENV["FAKE_GH_AUTH"] = "1"
    assert_raises(HerdrGhInbox::AuthError) { @inbox.fetch }
    assert_equal "\e]7501;state=blocked:kind=auth\e\\", @out.string
  end

  def test_pagination
    ENV["FAKE_GH_PAGES"] = "1"
    @inbox.fetch
    assert_equal 51, @inbox.items.size
    assert_includes File.read(@log), "page=2"
  end

  def test_display_width
    assert_equal "日本  ", HerdrGhInbox::Display.clip("日本", 6)
    assert_equal "á ", HerdrGhInbox::Display.clip("á", 2)
    @inbox.fetch
    row = HerdrGhInbox::Display.item_line(@inbox.items.first, now: Time.utc(2026, 11, 15, 15))
    assert_includes row, "PR"
    assert_includes row, "review_requested"
    assert_includes row, "3h"
    assert_includes row, "日本語の修正"
    assert_equal HerdrGhInbox::Display.width(HerdrGhInbox::Display.heading.split("TITLE").first), HerdrGhInbox::Display.width(row.split("日本語の修正").first)
  end

  def test_urgent_reasons_are_first_and_ambient_rows_are_dim
    ENV["FAKE_GH_ORDER"] = "ambient_first"
    @inbox.fetch
    assert_equal %w[review_requested subscribed], @inbox.items.map { |item| item["reason"] }
    assert_equal "2d", HerdrGhInbox::Display.age("2026-11-13T12:00:00Z", now: Time.utc(2026, 11, 15, 12))
  end

  def test_selected_body_loads_without_enter
    output = run_tui_with_keys("", {}, wait_for: "Latest comment:", quit: false)
    assert_includes output, "日本語の本文"
    assert_includes output, "\e[1;33m"
    assert_includes output, "\e[2m"
    assert_match(/Updated \d\d:\d\d · next in \d+s/, output)
    assert_includes File.read(@log), "GET /repos/example-org/app/pulls/4"
  end

  def test_herdr_keys_match_clone_and_launch_configured_agent
    app, log = fake_herdr_app
    @inbox.fetch
    tui = HerdrGhInbox::Tui.new(@inbox, input: StringIO.new, output: StringIO.new)
    tui.instance_variable_set(:@herdr, app)
    tui.send(:handle, "g", 1)
    tui.send(:handle, "a", 1)
    calls = File.readlines(log)
    assert_includes calls, "do space.select {\"id\":\"space-1\"}\n"
    launch = JSON.parse(calls.find { |line| line.start_with?("do tab.new ") }.sub("do tab.new ", ""))
    assert_equal "space-1", launch["space"]
    assert_equal ["claude"], launch["argv"]
    assert_equal "Please review this PR: https://github.com/example-org/app/pull/4", launch["task"]
    assert_equal File.join(@directory, "app"), launch["folder"]
  end

  def test_herdr_agent_settings_and_missing_clone
    app, log = fake_herdr_app
    ENV["HERDR_GH_INBOX_AGENT_ARGV"] = '["codex", "--model", "example"]'
    ENV["HERDR_GH_INBOX_TASK_TEMPLATE"] = "Check %{repo} at %{url}"
    @inbox.fetch
    launch = app.launch_agent(@inbox.items.first)
    assert_equal ["codex", "--model", "example"], launch["argv"]
    assert_equal "Check example-org/app at https://github.com/example-org/app/pull/4", launch["task"]
    File.write(ENV.fetch("FAKE_HERDR_SPACES"), JSON.generate([]))
    other = @inbox.items.last
    error = assert_raises(HerdrGhInbox::ApiError) { app.launch_agent(other) }
    assert_match(/Local clone not found/, error.message)
    refute File.readlines(log).any? { |line| line.include?("other") }
  end

  def test_repo_name_alone_does_not_match_a_different_owner
    app, log = fake_herdr_app
    root = File.join(@directory, "app")
    File.write(File.join(root, ".git", "config"), "[remote \"origin\"]\n  url = https://github.com/another-org/app.git\n")
    @inbox.fetch
    error = assert_raises(HerdrGhInbox::ApiError) { app.select_space(@inbox.items.first) }
    assert_match(/Local clone not found/, error.message)
    refute File.readlines(log).any? { |line| line.start_with?("do ") }
  end

  def test_explicit_clone_mapping_launches_without_space
    _app, log = fake_herdr_app
    File.write(ENV.fetch("FAKE_HERDR_SPACES"), JSON.generate([]))
    root = File.join(@directory, "app")
    ENV["HERDR_GH_INBOX_REPO_DIRS"] = JSON.generate({"example-org/app" => root})
    @inbox.fetch
    mapped = HerdrGhInbox::HerdrApp.new(File.join(__dir__, "fixtures/fake-herdr-app"))
    launch = mapped.launch_agent(@inbox.items.first)
    assert_equal root, launch["folder"]
    refute launch.key?("space")
    assert File.readlines(log).any? { |line| line.start_with?("do tab.new ") }
  end

  def test_json_lines
    env = {"HERDR_GH_INBOX_GH" => File.join(__dir__, "fixtures/fake-gh"), "FAKE_GH_LOG" => @log}
    command = ENV["INBOX_BIN"] || RbConfig.ruby
    args = ENV["INBOX_BIN"] ? [] : [File.expand_path("../bin/herdr-gh-inbox", __dir__)]
    output, error, status = Open3.capture3(env, command, *args, "--json")
    assert status.success?, error
    assert_equal 2, output.lines.size
    assert_equal "101", JSON.parse(output.lines.first)["id"]
    refute_includes output, "\e]7501"
  end

  def test_repeated_read_keys_only_mark_one_thread_with_slow_gh
    output = run_tui_with_keys("rrrrrr", {"FAKE_GH_MARK_SLEEP" => "0.6"})
    calls = File.readlines(@log)
    assert_equal 1, calls.count { |line| line.start_with?("PATCH ") }
    assert_includes calls, "PATCH /notifications/threads/101 \n"
    assert_includes output, "Marking read"
    assert_includes output, "Marked read"
    assert_operator output.index("Marking read"), :<, output.index("Marked read")
  end

  def test_failed_mark_keeps_item_and_does_not_retry_queued_keys
    output = run_tui_with_keys("rrrr", {"FAKE_GH_MARK_SLEEP" => "0.3", "FAKE_GH_MARK_FAIL" => "1"})
    calls = File.readlines(@log)
    assert_equal 1, calls.count { |line| line.start_with?("PATCH ") }
    assert_includes output, "read failed"
    assert_includes output, "2 unread"
  end

  # Runs the TUI with a 1 second poll interval and presses nothing: the list must be fetched again.
  # Catches `!@mark_thread`, which Spinel compiles to a constant false, so the timed refresh never ran
  def test_list_refreshes_after_the_poll_interval
    env = {"HERDR_GH_INBOX_MIN_INTERVAL" => "1", "FAKE_GH_POLL_INTERVAL" => "1"}
    fetches = -> { File.exist?(@log) ? File.readlines(@log).count { |line| line.start_with?("GET /notifications?") } : 0 }
    run_tui_with_keys("", env, wait_until: -> { fetches.call >= 2 }, quit: false)
    assert_operator fetches.call, :>=, 2
  end

  # Spinel compiles `!@ivar` to a constant false when the ivar holds a Thread or nil, so the
  # binary silently skips the branch. Write `@ivar.nil?` instead
  def test_no_negated_instance_variables
    source = File.read(File.expand_path("../bin/herdr-gh-inbox", __dir__))
    offenders = source.lines.each_with_index.select { |line, _| line.match?(/!@\w+(?![\w.(\[])/) }
    assert_empty offenders.map { |line, index| "#{index + 1}: #{line.strip}" }
  end

  private

  def fake_herdr_app
    root = File.join(@directory, "app")
    FileUtils.mkdir_p(File.join(root, ".git"))
    File.write(File.join(root, ".git", "config"), "[remote \"origin\"]\n  url = git@github.com:example-org/app.git\n")
    subfolder = File.join(root, "src")
    FileUtils.mkdir_p(subfolder)
    spaces = File.join(@directory, "spaces.json")
    log = File.join(@directory, "herdr-calls")
    File.write(spaces, JSON.generate([{"id" => "space-1", "name" => "Example app", "folder" => subfolder, "machine" => nil}]))
    ENV["FAKE_HERDR_SPACES"] = spaces
    ENV["FAKE_HERDR_LOG"] = log
    [HerdrGhInbox::HerdrApp.new(File.join(__dir__, "fixtures/fake-herdr-app")), log]
  end

  def run_tui_with_keys(keys, extra_env, wait_for: nil, wait_until: nil, quit: true)
    command = ENV["INBOX_BIN"] || RbConfig.ruby
    args = ENV["INBOX_BIN"] ? [] : [File.expand_path("../bin/herdr-gh-inbox", __dir__)]
    env = {"HERDR_GH_INBOX_GH" => File.join(__dir__, "fixtures/fake-gh"), "FAKE_GH_LOG" => @log}.merge(extra_env)
    output = +"".b
    reader, writer, pid = PTY.spawn(env, command, *args)
    writer.winsize = [24, 120]
    stage = "initial draw"
    begin
      Timeout.timeout(8) do
        until output.include?("GitHub inbox:")
          IO.select([reader], nil, nil, 0.1)
          chunk = reader.read_nonblock(8192, exception: false)
          output << chunk if chunk.is_a?(String)
        end
        writer.write(keys)
        stage = "target"
        target = wait_for || (extra_env["FAKE_GH_MARK_FAIL"] == "1" ? "read failed" : "Marked read")
        until wait_until ? wait_until.call : output.include?(target.b)
          IO.select([reader], nil, nil, 0.1)
          chunk = reader.read_nonblock(8192, exception: false)
          output << chunk if chunk.is_a?(String)
        end
        if quit
          writer.write("q")
          stage = "exit"
          Process.waitpid(pid)
        end
      end
    rescue Timeout::Error
      flunk "TUI timed out at #{stage}: #{output[-700, 700].inspect}; calls=#{File.exist?(@log) ? File.read(@log) : '(none)'}"
    ensure
      begin
        if Process.waitpid(pid, Process::WNOHANG).nil?
          Process.kill("KILL", pid)
          Process.waitpid(pid)
        end
      rescue Errno::ECHILD
        nil
      end
      reader.close
      writer.close
    end
    output.force_encoding(Encoding::UTF_8)
  end
end
