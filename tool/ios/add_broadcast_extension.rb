# frozen_string_literal: true
#
# iOS yayın uzantısını (ekran yansıtma) Flutter'ın Xcode projesine ekler.
# Mac'e dokunmadan, Codemagic derlemesi sırasında çalışır. Tekrar çalıştırılması güvenlidir.
#
# Kullanım (proje kökünde, `flutter create --platforms ios .` sonrası):
#   BUILD_NAME=0.1.0 BUILD_NUMBER=12 ruby tool/ios/add_broadcast_extension.rb
#
require 'fileutils'
require 'xcodeproj'

EXT_NAME = 'Broadcast'
EXT_SOURCES = %w[SampleHandler.swift H264Encoder.swift MirrorServer.swift DarwinBus.swift].freeze
EXT_RESOURCES = %w[ekran.html jmuxer.min.js].freeze
RUNNER_SOURCES = %w[YolcuMirrorBridge.swift DarwinBus.swift].freeze
DEPLOYMENT_TARGET = '13.0'

tool_dir = __dir__
root = File.expand_path('../..', tool_dir)
ios_dir = File.join(root, 'ios')
project_path = File.join(ios_dir, 'Runner.xcodeproj')
abort "Xcode projesi bulunamadı: #{project_path}. Önce `flutter create --platforms ios .` çalıştırın." unless File.exist?(project_path)

build_name = ENV.fetch('BUILD_NAME', '1.0.0')
build_number = ENV.fetch('BUILD_NUMBER', '1')

# ---------------------------------------------------------------------------
# 1) Dosyaları ios/ altına kopyala (her çalıştırmada güncellenir)
# ---------------------------------------------------------------------------
ext_dir = File.join(ios_dir, EXT_NAME)
FileUtils.mkdir_p(ext_dir)
Dir[File.join(tool_dir, 'Broadcast', '*')].each { |f| FileUtils.cp(f, ext_dir) }
FileUtils.cp(File.join(tool_dir, 'Shared', 'DarwinBus.swift'), ext_dir)
EXT_RESOURCES.each { |f| FileUtils.cp(File.join(root, 'assets', 'web', f), ext_dir) }

runner_dir = File.join(ios_dir, 'Runner')
FileUtils.cp(File.join(tool_dir, 'Runner', 'YolcuMirrorBridge.swift'), runner_dir)
FileUtils.cp(File.join(tool_dir, 'Shared', 'DarwinBus.swift'), runner_dir)

# ---------------------------------------------------------------------------
# 2) Xcode projesi
# ---------------------------------------------------------------------------
project = Xcodeproj::Project.open(project_path)
runner = project.targets.find { |t| t.name == 'Runner' } or abort 'Runner hedefi bulunamadı.'
main_bundle_id = runner.build_configurations
                       .map { |c| c.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] }
                       .compact.first or abort 'Runner PRODUCT_BUNDLE_IDENTIFIER bulunamadı.'
ext_bundle_id = "#{main_bundle_id}.#{EXT_NAME}"

# Runner: köprü dosyaları
runner_group = project.main_group.children.find { |g| g.display_name == 'Runner' } or abort 'Runner grubu yok.'
RUNNER_SOURCES.each do |name|
  next if runner_group.files.any? { |f| f.path == name }
  ref = runner_group.new_reference(name)
  runner.add_file_references([ref])
end

ext = project.targets.find { |t| t.name == EXT_NAME }
if ext.nil?
  ext = project.new_target(:app_extension, EXT_NAME, :ios, DEPLOYMENT_TARGET, nil, :swift)
  # xcodeproj, Foundation'ı sabit bir SDK sürümü yoluyla ekliyor (ör. iPhoneOS26.0.sdk);
  # farklı Xcode sürümünde derlemeyi kırmasın diye kaldırıyoruz. Swift bunu zaten otomatik bağlar.
  ext.frameworks_build_phase.files.to_a.each do |build_file|
    ref = build_file.file_ref
    build_file.remove_from_project
    ref&.remove_from_project if ref && ref.build_files.empty?
  end

  group = project.main_group.new_group(EXT_NAME, EXT_NAME)
  ext.add_file_references(EXT_SOURCES.map { |f| group.new_reference(f) })
  ext.add_resources(EXT_RESOURCES.map { |f| group.new_reference(f) })
  group.new_reference('Info.plist')

  # Flutter'da Debug/Release dışında Profile yapılandırması da var.
  unless ext.build_configurations.any? { |c| c.name == 'Profile' }
    release = ext.build_configurations.find { |c| c.name == 'Release' }
    profile = project.new(Xcodeproj::Project::Object::XCBuildConfiguration)
    profile.name = 'Profile'
    profile.build_settings = Marshal.load(Marshal.dump(release.build_settings))
    ext.build_configuration_list.build_configurations << profile
  end

  # Runner uzantıya bağımlı olsun ve onu PlugIns klasörüne gömsün.
  runner.add_dependency(ext)
  embed = runner.new_copy_files_build_phase('Embed App Extensions')
  embed.symbol_dst_subfolder_spec = :plug_ins
  build_file = embed.add_file_reference(ext.product_reference, true)
  build_file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }

  # Gömme adımı Flutter'ın "Thin Binary" betiğinden ÖNCE olmalı;
  # aksi halde Xcode "Cycle inside Runner" hatası verir.
  phases = runner.build_phases
  phases.delete(embed)
  thin = phases.index { |p| p.respond_to?(:name) && p.name == 'Thin Binary' }
  phases.insert(thin || phases.length, embed)

  puts "Broadcast hedefi eklendi (#{ext_bundle_id})."
else
  puts 'Broadcast hedefi zaten var; dosyalar ve ayarlar güncellendi.'
end

# Her çalıştırmada güncellenen ayarlar (sürüm numarası uygulamayla aynı olmalı).
runner_team = runner.build_configurations.map { |c| c.build_settings['DEVELOPMENT_TEAM'] }.compact.first
ext.build_configurations.each do |config|
  s = config.build_settings
  s['PRODUCT_BUNDLE_IDENTIFIER'] = ext_bundle_id
  s['PRODUCT_NAME'] = '$(TARGET_NAME)'
  s['INFOPLIST_FILE'] = "#{EXT_NAME}/Info.plist"
  s['GENERATE_INFOPLIST_FILE'] = 'NO'
  s['SWIFT_VERSION'] = '5.0'
  s['IPHONEOS_DEPLOYMENT_TARGET'] = DEPLOYMENT_TARGET
  s['TARGETED_DEVICE_FAMILY'] = '1,2'
  s['MARKETING_VERSION'] = build_name
  s['CURRENT_PROJECT_VERSION'] = build_number
  s['SKIP_INSTALL'] = 'YES'
  s['APPLICATION_EXTENSION_API_ONLY'] = 'YES'
  s['ENABLE_BITCODE'] = 'NO'
  s['CODE_SIGN_STYLE'] ||= 'Automatic'
  s['DEVELOPMENT_TEAM'] = runner_team if runner_team
  s['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/Frameworks', '@executable_path/../../Frameworks']
  if config.name == 'Debug'
    s['SWIFT_OPTIMIZATION_LEVEL'] = '-Onone'
  else
    s['SWIFT_OPTIMIZATION_LEVEL'] = '-O'
    s['SWIFT_COMPILATION_MODE'] = 'wholemodule'
  end
end

project.save

# ---------------------------------------------------------------------------
# 3) AppDelegate: köprüyü eklentilerle aynı kayıt nesnesine bağla
# ---------------------------------------------------------------------------
app_delegate = File.join(runner_dir, 'AppDelegate.swift')
code = File.read(app_delegate)
unless code.include?('YolcuMirrorBridge')
  pattern = /^(\s*)GeneratedPluginRegistrant\.register\(with:\s*(.+?)\)\s*$/
  patched = code.sub(pattern) do
    indent = Regexp.last_match(1)
    registry = Regexp.last_match(2)
    "#{indent}GeneratedPluginRegistrant.register(with: #{registry})\n" \
      "#{indent}YolcuMirrorBridge.register(with: #{registry})"
  end
  abort 'AppDelegate.swift içinde GeneratedPluginRegistrant satırı bulunamadı.' if patched == code
  File.write(app_delegate, patched)
  puts 'AppDelegate.swift güncellendi.'
end

puts "Hazır: uygulama #{main_bundle_id}, uzantı #{ext_bundle_id}, sürüm #{build_name} (#{build_number})"
