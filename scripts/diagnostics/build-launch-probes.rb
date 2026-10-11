#!/usr/bin/ruby
# Build only. Never launch, install, approve, remove quarantine, or change settings.
require 'tmpdir'
require 'fileutils'
require 'securerandom'
require 'digest'
require 'json'
require 'time'
require 'open3'

abort 'Usage: /usr/bin/ruby scripts/diagnostics/build-launch-probes.rb /absolute/existing/output-parent' unless ARGV.length == 1 && ARGV[0].start_with?('/')
parent = File.realpath(ARGV[0])
abort 'Output parent must be a directory' unless File.directory?(parent)
abort 'macOS required' unless RUBY_PLATFORM.include?('darwin')

File.umask(0077)
source = File.join(__dir__, 'LaunchProbe.m')
directory = Dir.mktmpdir('SpaceJudge-auth-probes-', parent)
# File Provider-managed Documents may add FinderInfo to loose .app directories.
# Stage in a unique system temporary directory; do not strip quarantine or attributes.
stage_root = Dir.mktmpdir('SpaceJudge-auth-stage-')
run_id = SecureRandom.hex(6)
manifest = {
  'schema' => 1, 'createdAtUTC' => Time.now.utc.iso8601(3), 'runId' => run_id,
  'purpose' => 'Local independent Gatekeeper control, not a release or a fix.',
  'sourceSHA256' => Digest::SHA256.file(source).hexdigest,
  'stageRoot' => stage_root,
  'complete' => false, 'commands' => [], 'probes' => []
}
save = lambda { File.write(File.join(directory, 'manifest.json'), JSON.pretty_generate(manifest) + "\n") }
run = lambda do |*command|
  output, status = Open3.capture2e({ 'PATH' => '/usr/bin:/bin:/usr/sbin:/sbin' }, *command)
  manifest['commands'] << { 'argv' => command, 'exitCode' => status.exitstatus, 'output' => output }
  save.call
  raise "Command failed (#{status.exitstatus}): #{command.first}" unless status.success?
  output
end

begin
  %w[A B C].each do |variant|
    name = "SpaceJudge Launch Probe #{variant} #{run_id}"
    identifier = "com.hongdazhu.SpaceJudgeLaunchProbe.#{variant.downcase}.r#{run_id}"
    stage = File.join(stage_root, variant)
    bundle = File.join(stage, name + '.app')
    executable = File.join(bundle, 'Contents', 'MacOS', 'LaunchProbe')
    FileUtils.mkdir_p(File.dirname(executable))
    # Values embedded below are generated from constants and SecureRandom, not user input.
    File.write(File.join(bundle, 'Contents', 'Info.plist'), <<~PLIST)
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0"><dict>
        <key>CFBundleExecutable</key><string>LaunchProbe</string>
        <key>CFBundleIdentifier</key><string>#{identifier}</string>
        <key>CFBundleName</key><string>#{name}</string>
        <key>CFBundleDisplayName</key><string>#{name}</string>
        <key>CFBundlePackageType</key><string>APPL</string>
        <key>CFBundleVersion</key><string>1</string>
        <key>CFBundleShortVersionString</key><string>0.0.1</string>
        <key>LSMinimumSystemVersion</key><string>14.0</string>
        <key>NSPrincipalClass</key><string>NSApplication</string>
        <key>NSHighResolutionCapable</key><true/>
      </dict></plist>
    PLIST
    run.call('/usr/bin/xcrun', 'clang', '-fobjc-arc', '-Os', '-Wall', '-Wextra', '-Werror',
             '-arch', 'arm64', '-arch', 'x86_64', '-mmacosx-version-min=14.0',
             '-framework', 'Cocoa', "-DPROBE_LABEL=\"#{name}\"", source, '-o', executable)
    run.call('/usr/bin/plutil', '-lint', File.join(bundle, 'Contents', 'Info.plist'))
    run.call('/usr/bin/codesign', '--options', 'runtime', '--timestamp=none', '--sign', '-', bundle)
    run.call('/usr/bin/codesign', '--verify', '--deep', '--strict', '--verbose=2', bundle)
    architectures = run.call('/usr/bin/lipo', '-archs', executable).split.sort
    raise 'Universal architectures missing' unless architectures == %w[arm64 x86_64]
    run.call('/usr/bin/codesign', '-d', '--verbose=4', bundle)
    dmg = File.join(directory, "#{name}.dmg")
    run.call('/usr/bin/hdiutil', 'create', '-quiet', '-fs', 'HFS+', '-format', 'UDZO',
             '-volname', "SJ Probe #{variant} #{run_id}", '-srcfolder', stage, dmg)
    run.call('/usr/bin/hdiutil', 'verify', dmg)
    manifest['probes'] << {
      'variant' => variant, 'bundle' => bundle, 'bundleIdentifier' => identifier,
      'executableSHA256' => Digest::SHA256.file(executable).hexdigest,
      'dmg' => dmg, 'dmgSHA256' => Digest::SHA256.file(dmg).hexdigest,
      'bytes' => File.size(dmg), 'architectures' => architectures
    }
    save.call
  end
  hashes = manifest['probes'].map { |p| p['executableSHA256'] }
  raise 'Probe binaries must be distinct for separate approval tests' unless hashes.uniq.length == 3
  manifest['complete'] = true
ensure
  save.call
  puts directory
  puts 'Build only: not downloaded, quarantined, installed, launched or approved. Requires a recorded user-driven test.'
end
