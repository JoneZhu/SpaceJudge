#!/usr/bin/ruby
# Build-only local diagnostic. No install, launch, approval, or security writes.
require_relative 'capture-launch'
require 'fileutils'
require 'securerandom'
require 'digest'
require 'open3'

abort 'Usage: build-full-launch-control.rb /absolute/existing/output-parent /absolute/signed/spacejudge-agent-cli' unless ARGV.length == 2 && ARGV.all? { |p| p.start_with?('/') }
abort 'macOS required' unless RUBY_PLATFORM.include?('darwin')
parent = File.realpath(ARGV[0])
helper = File.realpath(ARGV[1])
abort 'Existing output directory and signed CLI file required' unless File.directory?(parent) && File.file?(helper) && File.basename(helper) == 'spacejudge-agent-cli'
repo = File.expand_path('../..', __dir__)
File.umask(0077)
$stdout.sync = true
directory = Dir.mktmpdir('SpaceJudge-full-control-', parent)
stage_root = Dir.mktmpdir('SpaceJudge-full-stage-')
token = SecureRandom.hex(6)
identifier = "com.hongdazhu.SpaceJudgeLaunchControl.r#{token}"
name = "SpaceJudge Launch Control #{token}"
manifest = {
  'schema' => 1, 'purpose' => 'Full local launch diagnostic, not a release or a fix',
  'createdAtUTC' => Time.now.utc.iso8601(3), 'runId' => token,
  'bundleIdentifier' => identifier, 'appName' => name, 'stageRoot' => stage_root,
  'expectedCacheBasename' => "SpaceJudgeLaunchControl-#{token}",
  'complete' => false, 'commands' => [],
  'limitations' => 'Fresh identity, recompiled main binary and isolated cache differ from installed product; shared system security caches are not reset.'
}
save = lambda { File.write(File.join(directory, 'manifest.json'), JSON.pretty_generate(manifest) + "\n") }
runner = SpaceJudgeLaunchCapture::Runner.new
run = lambda do |label, argv, seconds=30|
  puts label
  result = runner.run(argv, File.join(directory, label + '.log'), seconds: seconds)
  manifest['commands'] << result.merge('file' => label + '.log')
  save.call
  raise "#{label} failed (#{result['status']})" unless result['status'] == 'ok'
end
begin
  puts "Build evidence: #{directory}"
  run.call('verify-source-cli', ['/usr/bin/codesign', '--verify', '--strict', helper])
  manifest['bundledCLISHA256'] = Digest::SHA256.file(helper).hexdigest
  %w[App/SpaceJudgeApp/AppDelegate.swift App/SpaceJudgeApp/SpaceJudgeApp.swift Sources/SpaceJudgeAppSupport/SnapshotWorkspace.swift Sources/SpaceJudgeAppSupport/StartupDiagnostics.swift].each do |relative|
    (manifest['sourceSHA256'] ||= {})[relative] = Digest::SHA256.file(File.join(repo, relative)).hexdigest
  end
  derived = File.join(stage_root, 'DerivedData')
  run.call('build-universal-release', [
    '/usr/bin/xcodebuild', '-project', File.join(repo, 'App/SpaceJudge.xcodeproj'),
    '-scheme', 'SpaceJudge', '-configuration', 'Release', '-destination', 'generic/platform=macOS',
    '-derivedDataPath', derived, 'ARCHS=arm64 x86_64', 'ONLY_ACTIVE_ARCH=NO',
    'CODE_SIGNING_ALLOWED=NO', "PRODUCT_BUNDLE_IDENTIFIER=#{identifier}",
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=SPACEJUDGE_LAUNCH_CONTROL', 'build'
  ], 900)
  staging = File.join(stage_root, 'staging')
  FileUtils.mkdir_p(staging)
  bundle = File.join(staging, name + '.app')
  run.call('stage-built-app', ['/usr/bin/ditto', File.join(derived, 'Build/Products/Release/SpaceJudge.app'), bundle])
  plist = File.join(bundle, 'Contents/Info.plist')
  run.call('name-diagnostic', ['/usr/libexec/PlistBuddy', '-c', "Set :CFBundleName #{name}", plist])
  run.call('label-diagnostic', ['/usr/libexec/PlistBuddy', '-c', "Add :CFBundleDisplayName string #{name}", plist])
  observed, status = Open3.capture2e('/usr/libexec/PlistBuddy', '-c', 'Print :CFBundleIdentifier', plist)
  raise 'Wrong built diagnostic identity' unless status.success? && observed.strip == identifier
  FileUtils.mkdir_p(File.join(bundle, 'Contents/Helpers'))
  destination_helper = File.join(bundle, 'Contents/Helpers/spacejudge-agent-cli')
  run.call('stage-unchanged-cli', ['/usr/bin/ditto', helper, destination_helper])
  raise 'CLI copy changed' unless Digest::SHA256.file(destination_helper).hexdigest == manifest['bundledCLISHA256']
  run.call('sign-main', ['/usr/bin/codesign', '--force', '--options', 'runtime', '--timestamp=none', '--sign', '-', bundle])
  run.call('verify-bundle', ['/usr/bin/codesign', '--verify', '--deep', '--strict', '--verbose=2', bundle])
  run.call('signature-details', ['/usr/bin/codesign', '-d', '--verbose=4', bundle])
  executable = File.join(bundle, 'Contents/MacOS/SpaceJudge')
  run.call('architectures', ['/usr/bin/lipo', '-archs', executable])
  raise 'Missing universal architectures' unless File.read(File.join(directory, 'architectures.log')).split.sort == %w[arm64 x86_64]
  %w[InstallationGuide.html PrivacyInfo.xcprivacy AppIcon.icns].each do |resource|
    raise "Missing #{resource}" unless File.file?(File.join(bundle, 'Contents/Resources', resource))
  end
  File.symlink('/Applications', File.join(staging, 'Applications'))
  dmg = File.join(directory, "SpaceJudge-Launch-Control-#{token}.dmg")
  run.call('create-dmg', ['/usr/bin/hdiutil', 'create', '-quiet', '-fs', 'HFS+', '-format', 'UDZO', '-volname', "SJ Full Control #{token}", '-srcfolder', staging, dmg], 120)
  run.call('verify-dmg', ['/usr/bin/hdiutil', 'verify', dmg], 60)
  manifest.merge!(
    'bundle' => bundle, 'executableSHA256' => Digest::SHA256.file(executable).hexdigest,
    'dmg' => dmg, 'dmgSHA256' => Digest::SHA256.file(dmg).hexdigest,
    'dmgBytes' => File.size(dmg), 'complete' => true
  )
ensure
  manifest['finishedAtUTC'] = Time.now.utc.iso8601(3)
  save.call
  puts "Saved: #{directory}"
  puts 'Not downloaded, installed, launched, approved, or publicly released.'
end
