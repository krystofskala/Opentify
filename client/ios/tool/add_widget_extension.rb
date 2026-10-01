# Přidá do Runner.xcodeproj rozšíření OpentifyWidgets (Live Activity +
# ovládání v Ovládacím centru). Spouští se v CI (macOS) před `flutter build
# ios` -- bez Macu nejde target přidat v Xcode ručně. Idempotentní.
#
#   gem install xcodeproj && ruby ios/tool/add_widget_extension.rb
require 'xcodeproj'

IOS = File.expand_path('..', __dir__)
project = Xcodeproj::Project.open(File.join(IOS, 'Runner.xcodeproj'))
runner = project.targets.find { |t| t.name == 'Runner' }
abort 'Runner target nenalezen' unless runner

if project.targets.any? { |t| t.name == 'OpentifyWidgets' }
  puts 'OpentifyWidgets už v projektu je'
  exit 0
end

version = File.read(File.join(IOS, '..', 'pubspec.yaml'))[/^version:\s*([^\s+]+)/, 1] || '1.0.0'

ext = project.new_target(:app_extension, 'OpentifyWidgets', :ios, '17.0', nil, :swift)

widgets_group = project.main_group.find_subpath('OpentifyWidgets', true)
widgets_group.set_source_tree('<group>')
widgets_group.set_path('OpentifyWidgets')
shared_group = project.main_group.find_subpath('Shared', true)
shared_group.set_source_tree('<group>')
shared_group.set_path('Shared')
runner_group = project.main_group.find_subpath('Runner', false)

ext_swift = widgets_group.new_reference('OpentifyWidgets.swift')
widgets_group.new_reference('Info.plist')
widgets_group.new_reference('OpentifyWidgets.entitlements')
shared_swift = shared_group.new_reference('NowPlayingAttributes.swift')
bridge_swift = runner_group.new_reference('NowPlayingActivity.swift')
runner_group.new_reference('Runner.entitlements')

ext.add_file_references([ext_swift, shared_swift])
runner.add_file_references([shared_swift, bridge_swift])

%w[WidgetKit SwiftUI ActivityKit AppIntents].each { |fw| ext.add_system_framework(fw) }

ext.build_configurations.each do |config|
  s = config.build_settings
  s['PRODUCT_BUNDLE_IDENTIFIER'] = 'app.opentify.OpentifyWidgets'
  s['PRODUCT_NAME'] = '$(TARGET_NAME)'
  s['INFOPLIST_FILE'] = 'OpentifyWidgets/Info.plist'
  s['GENERATE_INFOPLIST_FILE'] = 'NO'
  s['CODE_SIGN_ENTITLEMENTS'] = 'OpentifyWidgets/OpentifyWidgets.entitlements'
  s['SWIFT_VERSION'] = '5.0'
  s['TARGETED_DEVICE_FAMILY'] = '1,2'
  s['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
  s['SKIP_INSTALL'] = 'YES'
  s['MARKETING_VERSION'] = version
  s['CURRENT_PROJECT_VERSION'] = '1'
  s['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/Frameworks', '@executable_path/../../Frameworks']
  s['ENABLE_BITCODE'] = 'NO'
  s['ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME'] = ''
  s['ASSETCATALOG_COMPILER_WIDGET_BACKGROUND_COLOR_NAME'] = ''
end

runner.build_configurations.each do |config|
  config.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'Runner/Runner.entitlements'
end

# Vložit .appex do appky (PlugIns). Fáze hned za Resources -- za skripty
# Flutteru ("Thin Binary") by Xcode hlásil cyklus závislostí.
runner.add_dependency(ext)
embed = runner.new_copy_files_build_phase('Embed Foundation Extensions')
embed.symbol_dst_subfolder_spec = :plug_ins
build_file = embed.add_file_reference(ext.product_reference, true)
build_file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
runner.build_phases.delete(embed)
resources_index = runner.build_phases.index(runner.resources_build_phase) || (runner.build_phases.size - 1)
runner.build_phases.insert(resources_index + 1, embed)

project.save
puts "OpentifyWidgets přidán (verze #{version})"
