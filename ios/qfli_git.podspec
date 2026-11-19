#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint qfli_git.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'qfli_git'
  s.version          = '0.1.0'
  s.summary          = 'Local git operations backed by libgit2 and mbedTLS.'
  s.description      = <<-DESC
Local git operations for Flutter apps. The framework is built by the native CI
job and copied into Frameworks/qfli_git.xcframework.
                       DESC
  s.homepage         = 'https://github.com/azurekiln2333/qflistudio-git'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'AzureKiln' => 'azurekiln2333@users.noreply.github.com' }

  s.source           = { :path => '.' }

  # The dynamic framework is prebuilt. CocoaPods embeds it in the app bundle.
  s.vendored_frameworks = 'Frameworks/qfli_git.xcframework'

  s.dependency 'Flutter'
  s.platform = :ios, '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end