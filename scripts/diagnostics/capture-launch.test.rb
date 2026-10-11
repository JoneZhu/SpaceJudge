require 'minitest/autorun'
require 'fileutils'
require_relative 'capture-launch'

class LaunchCaptureTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir('spacejudge-capture-test-')
    @app = File.join(@root, 'SpaceJudge.app')
    FileUtils.mkdir_p(File.join(@app, 'Contents/MacOS'))
    File.write(File.join(@app, 'Contents/MacOS/SpaceJudge'), 'synthetic executable')
    @options = { mode: 'snapshot', minutes: 1, app: @app, parent: @root }
  end

  def teardown
    # Only our exact task-private synthetic fixture, never a user application.
    FileUtils.remove_entry_secure(@root)
  end

  class FakeRunner
    attr_reader :calls
    def initialize(executable: nil, fail_log: false, interrupted: false)
      @executable, @fail_log, @interrupted, @calls = executable, fail_log, interrupted, []
    end
    def run(command, destination, seconds:)
      @calls << command
      text = if command.first == '/usr/bin/pgrep'
               "12345\n"
             elsif command.first == '/bin/ps' && command.last == 'comm='
               "#{@executable}\n"
             else
               'fixture'
             end
      File.open(destination, File::WRONLY | File::CREAT | File::EXCL, 0600) { |f| f.write(text) }
      status = if @interrupted && command[1] == 'stream'
                 'interrupted'
               elsif @fail_log && command.first == '/usr/bin/log'
                 'timeout'
               else
                 'ok'
               end
      { 'command' => command, 'status' => status, 'exitCode' => 0, 'bytes' => text.bytesize }
    end
  end

  def test_defaults_and_valid_options
    assert_equal 'snapshot', SpaceJudgeLaunchCapture.options([])[:mode]
    options = SpaceJudgeLaunchCapture.options(['--mode', 'watch', '--minutes', '120', '--app', @app, '--output-parent', @root])
    assert_equal 120, options[:minutes]
    assert_equal 'watch', options[:mode]
  end

  def test_bad_options_are_rejected
    [%w[--minutes 0], %w[--minutes 121], %w[--minutes abc], %w[--mode delete], %w[--app relative], %w[--app /Applications/Other.app], %w[--output-parent relative], ['extra']].each do |argv|
      assert_raises(ArgumentError, OptionParser::ParseError) { SpaceJudgeLaunchCapture.options(argv) }
    end
  end

  def test_unique_private_directory_and_files
    fake = FakeRunner.new
    collector = SpaceJudgeLaunchCapture::Collector.new(@options, runner: fake)
    another = SpaceJudgeLaunchCapture::Collector.new(@options, runner: fake)
    refute_equal collector.directory, another.directory
    capture_io { collector.capture }
    assert_equal 0700, File.stat(collector.directory).mode & 0777
    Dir.children(collector.directory).each do |name|
      assert_equal 0600, File.stat(File.join(collector.directory, name)).mode & 0777
    end
    data = JSON.parse(File.read(File.join(collector.directory, 'manifest.json')))
    assert data['complete']
    assert_match(/PRIVATE/, data['privacy'])
    assert_match(/other applications/, data['privacy'])
    assert_equal 'synthetic executable', File.read(File.join(@app, 'Contents/MacOS/SpaceJudge'))
  end

  def test_cannot_create_inside_app_or_for_missing_executable
    assert_raises(ArgumentError) { SpaceJudgeLaunchCapture::Collector.new(@options.merge(parent: @app)) }
    assert_raises(ArgumentError) { SpaceJudgeLaunchCapture::Collector.new(@options.merge(app: '/missing/SpaceJudge.app')) }
  end

  def test_cannot_create_inside_managed_scan_cache
    cache = File.join(@root, 'Library/Caches/SpaceJudge')
    FileUtils.mkdir_p(cache)
    Dir.stub(:home, @root) do
      assert_raises(ArgumentError) { SpaceJudgeLaunchCapture::Collector.new(@options.merge(parent: cache)) }
    end
    assert_empty Dir.children(cache)
  end

  def test_exact_process_identity_and_read_only_commands
    fake = FakeRunner.new(executable: File.join(@app, 'Contents/MacOS/SpaceJudge'))
    collector = SpaceJudgeLaunchCapture::Collector.new(@options, runner: fake)
    capture_io { collector.capture }
    assert_equal 2, fake.calls.count { |command| command.first == '/usr/bin/sample' }
    refute fake.calls.any? { |command| %w[/usr/bin/open /bin/kill /usr/sbin/spctl /usr/bin/tccutil /usr/bin/sudo].include?(command.first) }
    fake.calls.select { |command| command.first == '/usr/bin/xattr' }.each { |command| assert_equal '-l', command[1] }
    fake.calls.select { |command| command.first == '/usr/bin/codesign' }.each { |command| refute_includes command, '--sign' }
  end

  def test_same_name_unrelated_process_is_not_sampled
    fake = FakeRunner.new(executable: '/some/other/SpaceJudge')
    collector = SpaceJudgeLaunchCapture::Collector.new(@options, runner: fake)
    capture_io { collector.capture }
    refute fake.calls.any? { |command| command.first == '/usr/bin/sample' }
  end

  def test_failure_is_preserved_and_not_reported_as_no_event
    collector = SpaceJudgeLaunchCapture::Collector.new(@options, runner: FakeRunner.new(fail_log: true))
    capture_io { collector.capture }
    assert collector.manifest['commands'].any? { |command| command['status'] == 'timeout' }
    assert_match(/Missing logs are not proof/, collector.manifest['limits'])
  end

  def test_watch_has_a_deadline_and_history_afterwards
    fake = FakeRunner.new
    collector = SpaceJudgeLaunchCapture::Collector.new(@options.merge(mode: 'watch'), runner: fake)
    capture_io { collector.capture }
    stream = fake.calls.find { |command| command[1] == 'stream' }
    assert_equal '1m', stream[stream.index('--timeout') + 1]
    assert_includes stream, '--level'
    assert fake.calls.any? { |command| command[1] == 'show' }
  end

  def test_local_authentication_processes_are_captured_in_history
    fake = FakeRunner.new
    collector = SpaceJudgeLaunchCapture::Collector.new(@options, runner: fake)
    capture_io { collector.capture }
    histories = fake.calls.select { |command| command.first == '/usr/bin/log' && command[1] == 'show' }
    system_history = histories.find { |command| command.last == SpaceJudgeLaunchCapture::SYSTEM_PREDICATE }
    refute_nil system_history
    %w[syspolicyd authd coreauthd coreautha loginwindow].each do |process|
      assert_includes system_history.last, "process == \"#{process}\""
    end
    # Authentication callbacks lack the product name; do not require it here.
    assert_match(/process == "coreauthd" OR process == "coreautha" OR/, system_history.last)
  end

  def test_local_authentication_processes_are_captured_live
    fake = FakeRunner.new
    collector = SpaceJudgeLaunchCapture::Collector.new(@options.merge(mode: 'watch'), runner: fake)
    capture_io { collector.capture }
    stream = fake.calls.find { |command| command.first == '/usr/bin/log' && command[1] == 'stream' }
    refute_nil stream
    assert_includes stream.last, SpaceJudgeLaunchCapture::APP_PREDICATE
    assert_includes stream.last, SpaceJudgeLaunchCapture::SYSTEM_PREDICATE
    assert_includes stream.last, 'process == "coreauthd"'
    assert_includes stream.last, 'process == "coreautha"'
  end

  def test_interrupt_preserves_partial_manifest_and_stops_collection
    fake = FakeRunner.new(interrupted: true)
    collector = SpaceJudgeLaunchCapture::Collector.new(@options.merge(mode: 'watch'), runner: fake)
    capture_io { collector.capture }
    refute collector.manifest['complete']
    assert collector.manifest['finishedAtUTC']
    refute fake.calls.any? { |command| command[1] == 'show' }
  end

  def test_runner_success_failure_and_no_overwrite
    runner = SpaceJudgeLaunchCapture::Runner.new
    target = File.join(@root, 'command.txt')
    result = runner.run(['/bin/echo', 'fixture'], target)
    assert_equal 'ok', result['status']
    assert_equal 0, result['exitCode']
    assert_equal 0600, File.stat(target).mode & 0777
    assert_raises(Errno::EEXIST) { runner.run(['/bin/echo', 'overwrite'], target) }
    assert_equal "fixture\n", File.read(target)
    failure = runner.run(['/usr/bin/false'], File.join(@root, 'failure.txt'))
    assert_equal 'failed', failure['status']
    assert_equal 1, failure['exitCode']
  end

  def test_runner_missing_tool_is_explicit
    result = SpaceJudgeLaunchCapture::Runner.new.run(['/no/such/tool'], File.join(@root, 'missing.txt'))
    assert_equal 'failed', result['status']
    assert_equal 'Errno::ENOENT', result['errorClass']
  end

  def test_runner_timeout_terminates_only_owned_command
    result = SpaceJudgeLaunchCapture::Runner.new.run(['/bin/sleep', '5'], File.join(@root, 'timeout.txt'), seconds: 0.1)
    assert_equal 'timeout', result['status']
    assert_operator result['durationSeconds'], :<, 2
  end

  def test_runner_output_limit
    result = SpaceJudgeLaunchCapture::Runner.new.run(['/usr/bin/yes', 'fixture'], File.join(@root, 'limit.txt'), seconds: 5, max_bytes: 1_024)
    assert_equal 'output_limit', result['status']
    assert_operator result['bytes'], :>, 1_024
  end
end
