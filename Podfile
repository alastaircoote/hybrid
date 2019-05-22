# Uncomment this line to define a global platform for your project
platform :ios, '10.0'
# Uncomment this line if you're using Swift
use_frameworks!


pod 'XCGLogger', '~> 6.0.4'
pod 'FMDB', '~> 2.6.2'
pod 'FMDBMigrationManager'
pod 'PromiseKit', '~> 4'
#pod 'EmitterKit', '~> 5'


target 'hybrid' do
    
    pod 'GCDWebServer', '~> 3.0'
end

target 'hybrid-notification-content' do
    
end

target 'notification-extension' do
    
end

post_install do |installer|
    installer.pods_project.targets.each do |target|
      if ['PromiseKit'].include? target.name
        target.build_configurations.each do |config|
          config.build_settings['SWIFT_VERSION'] = '4'
        end
      end
    end
  end
