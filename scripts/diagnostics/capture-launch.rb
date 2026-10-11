#!/usr/bin/ruby
# Read-only macOS launch diagnostics. No application launch or security writes.
require 'json'
require 'time'
require 'tmpdir'
require 'optparse'

module SpaceJudgeLaunchCapture
  APP_PREDICATE = 'subsystem == "com.hongdazhu.SpaceJudge" AND category == "Startup"'.freeze
  # Authentication messages often lack an app name. Capture those processes
  # separately, with an explicit privacy warning rather than false anonymization.
  SYSTEM_PREDICATE = 'process == "syspolicyd" OR process == "amfid" OR process == "taskgated" OR process == "taskgated-helper" OR process == "authd" OR process == "coreauthd" OR process == "coreautha" OR process == "SecurityAgent" OR process == "CoreServicesUIAgent" OR process == "loginwindow" OR ((process == "kernel" OR process == "launchservicesd" OR process == "lsd") AND eventMessage CONTAINS[c] "SpaceJudge")'.freeze
  SYSTEM_PATH = '/usr/bin:/bin:/usr/sbin:/sbin'.freeze
  MAX_BYTES = 32 * 1024 * 1024

  def self.options(argv)
    result = { mode: 'snapshot', minutes: 10, app: '/Applications/SpaceJudge.app', parent: Dir.tmpdir }
    parser = OptionParser.new do |p|
      p.banner = 'Usage: /usr/bin/ruby scripts/diagnostics/capture-launch.rb [--mode snapshot|watch] [--minutes 1..120] [--app /absolute/SpaceJudge.app] [--output-parent /absolute/existing/directory]'
      p.on('--mode MODE') { |v| result[:mode] = v }
      p.on('--minutes MINUTES', Integer) { |v| result[:minutes] = v }
      p.on('--app PATH') { |v| result[:app] = v }
      p.on('--output-parent PATH') { |v| result[:parent] = v }
      p.on('-h', '--help') { puts p; return nil }
    end
    parser.parse!(argv)
    raise ArgumentError, 'unexpected positional arguments' unless argv.empty?
    raise ArgumentError, 'mode must be snapshot or watch' unless %w[snapshot watch].include?(result[:mode])
    raise ArgumentError, 'minutes must be 1..120' unless (1..120).cover?(result[:minutes])
    [:app, :parent].each { |key| raise ArgumentError, "#{key} must be an absolute path" unless result[key].start_with?('/') }
    raise ArgumentError, 'app must be named SpaceJudge.app' unless File.basename(result[:app]) == 'SpaceJudge.app'
    result
  end

  class Runner
    # Only this invocation's subprocess group can be terminated, never an App.
    def run(command, destination, seconds: 25, max_bytes: MAX_BYTES)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = { 'command' => command, 'startedAtUTC' => Time.now.utc.iso8601(3), 'status' => 'failed' }
      pid = nil
      status = nil
      stopped = nil
      File.open(destination, File::WRONLY | File::CREAT | File::EXCL, 0600) do |file|
        begin
          pid = Process.spawn({ 'PATH' => SYSTEM_PATH }, *command, out: file, err: file, pgroup: true)
          loop do
            # Check caps before reaping: a quickly exiting producer can also
            # exceed the soft output limit.
            if File.size(destination) > max_bytes
              stopped = 'output_limit'
              break
            end
            if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started >= seconds
              stopped = 'timeout'
              break
            end
            waited = Process.waitpid2(pid, Process::WNOHANG)
            if waited
              status = waited[1]
              pid = nil
              break
            end
            sleep 0.1
          end
        rescue Interrupt
          stopped = 'interrupted'
        rescue SystemCallError => e
          # No exception message: it can contain paths. Raw command remains in
          # the private manifest, clearly disclosed to the user.
          result['errorClass'] = e.class.name
        ensure
          if pid
            begin
              Process.kill('TERM', -pid)
              10.times do
                waited = Process.waitpid2(pid, Process::WNOHANG)
                if waited
                  status = waited[1]
                  pid = nil
                  break
                end
                sleep 0.05
              end
              if pid
                Process.kill('KILL', -pid)
                status = Process.waitpid2(pid)[1]
              end
            rescue Errno::ESRCH, Errno::ECHILD
              # Process finished between inspection and cancellation.
            end
          end
        end
      end
      result['status'] = stopped || (status && status.success? ? 'ok' : 'failed')
      result['exitCode'] = status.exitstatus if status
      result['durationSeconds'] = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(3)
      result['bytes'] = File.size(destination)
      result
    end
  end

  class Collector
    attr_reader :directory, :manifest

    def initialize(options, runner: Runner.new)
      @options = options
      @runner = runner
      parent = File.realpath(options.fetch(:parent))
      raise ArgumentError, 'output parent must be an existing directory' unless File.directory?(parent)
      @app = options.fetch(:app)
      @executable = File.join(@app, 'Contents/MacOS/SpaceJudge')
      raise ArgumentError, 'installed application executable not found' unless File.file?(@executable)
      @canonical_executable = File.realpath(@executable)
      # Never use an existing output directory or create inside the bundle.
      canonical_app = File.realpath(@app)
      if parent == canonical_app || parent.start_with?(canonical_app + '/')
        raise ArgumentError, 'output cannot be inside the application'
      end
      cache = File.join(Dir.home, 'Library/Caches/SpaceJudge')
      cache = File.realpath(cache) if File.directory?(cache)
      if parent == cache || parent.start_with?(cache + '/')
        raise ArgumentError, 'output cannot be inside the managed scan cache'
      end
      @directory = Dir.mktmpdir('SpaceJudge-launch-', parent)
      File.chmod(0700, @directory)
      @manifest = {
        'schema' => 1, 'mode' => options.fetch(:mode), 'minutes' => options.fetch(:minutes),
        'startedAtUTC' => Time.now.utc.iso8601(3), 'localUTCOffsetSeconds' => Time.now.utc_offset,
        'app' => @app, 'commands' => [], 'complete' => false,
        'privacy' => 'PRIVATE: raw logs, paths, download URLs, process samples and other applications authentication events may be present. No automatic upload. Review before sharing.',
        'limits' => 'Each output has a 32 MiB soft cap checked every 0.1 seconds; transient overshoot is possible. Each command has a deadline. Missing logs are not proof of no event. No spctl/syspolicy assessment or security changes.'
      }
      save_manifest
    end

    def capture
      begin
        metadata('before')
        process_samples('before')
        if @options[:mode] == 'watch'
          puts '采集已启动。现在可手动在 Finder 打开同一个 App；记下点击授权、锁屏和解锁时间。Ctrl+C 停止。'
          collect('live.log', ['/usr/bin/log', 'stream', '--style', 'compact', '--level', 'debug', '--timeout', "#{@options[:minutes]}m", '--predicate', "(#{APP_PREDICATE}) OR (#{SYSTEM_PREDICATE})"], seconds: @options[:minutes] * 60 + 5)
          return if interrupted?
        end
        collect('startup-history.log', ['/usr/bin/log', 'show', '--last', "#{@options[:minutes]}m", '--info', '--debug', '--style', 'compact', '--predicate', APP_PREDICATE])
        collect('system-history.log', ['/usr/bin/log', 'show', '--last', "#{@options[:minutes]}m", '--info', '--debug', '--style', 'compact', '--predicate', SYSTEM_PREDICATE])
        process_samples('after')
        metadata('after')
        @manifest['complete'] = !interrupted?
      rescue Interrupt
        @manifest['interrupted'] = true
      ensure
        @manifest['finishedAtUTC'] = Time.now.utc.iso8601(3)
        save_manifest
        puts "诊断目录：#{@directory}"
        puts '原始证据可能包含隐私信息，不要直接上传整个目录。查看 manifest.json 中的失败、超时和截断状态。'
      end
    end

    private

    def interrupted?
      @manifest['interrupted'] || @manifest['commands'].any? { |x| x['status'] == 'interrupted' }
    end

    def collect(name, command, seconds: 25)
      return nil if interrupted?
      result = @runner.run(command, File.join(@directory, name), seconds: seconds)
      result['file'] = name
      @manifest['commands'] << result
      save_manifest
      result
    end

    def metadata(label)
      collect("#{label}-system-version.txt", ['/usr/bin/sw_vers'])
      collect("#{label}-boot-time.txt", ['/usr/sbin/sysctl', 'kern.boottime'])
      collect("#{label}-uptime.txt", ['/usr/bin/uptime'])
      collect("#{label}-main-sha256.txt", ['/usr/bin/shasum', '-a', '256', @executable])
      collect("#{label}-file-identity.txt", ['/usr/bin/stat', '-f', '%N inode=%i device=%d mode=%p birth=%SB modified=%Sm', '-t', '%Y-%m-%dT%H:%M:%S%z', @app, @executable])
      collect("#{label}-signature.txt", ['/usr/bin/codesign', '-d', '--verbose=4', @app])
      collect("#{label}-signature-verification.txt", ['/usr/bin/codesign', '--verify', '--deep', '--strict', @app])
      collect("#{label}-attributes.txt", ['/usr/bin/xattr', '-l', @app])
      %w[CFBundleShortVersionString CFBundleVersion CFBundleIdentifier].each do |key|
        collect("#{label}-#{key}.txt", ['/usr/libexec/PlistBuddy', '-c', "Print :#{key}", File.join(@app, 'Contents/Info.plist')])
      end
    end

    def process_samples(label)
      found = collect("#{label}-pids.txt", ['/usr/bin/pgrep', '-x', 'SpaceJudge'])
      return unless found && found['status'] == 'ok'
      # Restrict to exact executable identity, not just a same-named process.
      pids = File.read(File.join(@directory, "#{label}-pids.txt")).lines.map(&:strip).select { |s| s.match?(/\A[1-9][0-9]*\z/) }
      if pids.length > 8
        @manifest['processListTruncated'] = true
        pids = pids.first(8)
      end
      pids.each do |pid|
        identity = collect("#{label}-#{pid}-executable.txt", ['/bin/ps', '-p', pid, '-o', 'comm='])
        next unless identity && identity['status'] == 'ok'
        observed = File.read(File.join(@directory, "#{label}-#{pid}-executable.txt")).strip
        next unless observed == @executable || observed == @canonical_executable
        collect("#{label}-#{pid}-state.txt", ['/bin/ps', '-p', pid, '-o', 'pid=,lstart=,state=,etime=,rss='])
        collect("#{label}-#{pid}-sample.txt", ['/usr/bin/sample', pid, '1', '10'], seconds: 12)
      end
    end

    def save_manifest
      # The directory is new and owner-only; the manifest is a fixed name.
      path = File.join(@directory, 'manifest.json')
      File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0600) { |f| f.write(JSON.pretty_generate(@manifest) + "\n") }
    end
  end
end

if $PROGRAM_NAME == __FILE__
  $stdout.sync = true
  begin
    options = SpaceJudgeLaunchCapture.options(ARGV)
    if options
      warn '仅本地诊断：原始系统日志可能包含路径、下载 URL 及其他应用的授权信息；不会启动应用或修改权限。'
      collector = SpaceJudgeLaunchCapture::Collector.new(options)
      collector.capture
      failures = collector.manifest['commands'].any? do |x|
        no_process = x['file'].end_with?('-pids.txt') && x['status'] == 'failed' && x['exitCode'] == 1
        x['status'] != 'ok' && !no_process
      end
      exit(collector.manifest['complete'] && !failures ? 0 : 2)
    end
  rescue OptionParser::ParseError, ArgumentError, SystemCallError => e
    warn "无法采集：#{e.message}"
    exit 1
  end
end
