platform :ios, '9.0'
source 'https://github.com/CocoaPods/Specs.git'

use_frameworks!

def shared_pods
    # OWS Pods
    pod 'AxolotlKit', git: 'https://github.com/signalapp/SignalProtocolKit.git', branch: 'master', inhibit_warnings: true
    pod 'HKDFKit', git: 'https://github.com/signalapp/HKDFKit.git', inhibit_warnings: true
    pod 'GRKOpenSSLFramework', git: 'https://github.com/signalapp/GRKOpenSSLFramework', inhibit_warnings: true
    pod 'SocketRocket', :git => 'https://github.com/signalapp/SocketRocket.git', branch: 'mkirk/handle-sec-err', inhibit_warnings: true

    # Forsta pods
    pod 'RelayServiceKit', path: '.'
    pod 'SignalCoreKit', :git => 'https://github.com/ForstaLabs/SignalCoreKit.git', inhibit_warnings: true
    pod 'Curve25519Kit', git: 'https://github.com/ForstaLabs/Curve25519Kit.git', branch: 'autoProvision', inhibit_warnings: true
    pod 'NSAttributedString-DDHTML', :git => 'https://github.com/ForstaLabs/NSAttributedString-DDHTML.git', :inhibit_warnings => true

    # third party pods
    pod 'YapDatabase/SQLCipher', '~> 3.1.2', inhibit_warnings: true
    pod 'AFNetworking', inhibit_warnings: true
    pod 'Mantle', '~> 2.1.0', :inhibit_warnings => true
    pod 'PureLayout', '~> 3.1.4',:inhibit_warnings => true
    pod 'Reachability', '~> 3.2',:inhibit_warnings => true
    pod 'YYImage', '~> 1.0.4', :inhibit_warnings => true
    pod 'GoogleWebRTC', '~> 1.1', :inhibit_warnings => true
    pod 'UIImageView+Extension', '~> 0.2', :inhibit_warnings => true
    pod 'ZXingObjC', '~> 3.5', :inhibit_warnings => true
    pod 'URLEmbeddedView', :inhibit_warnings => true
    pod 'Fabric', '~> 1.0', :inhibit_warnings => true
    pod 'Crashlytics', '~> 3.0', :inhibit_warnings => true
end

target 'RelayDev' do
    shared_pods
    pod 'ReCaptcha', '1.2', :inhibit_warnings => true
#    pod 'ATAppUpdater', :inhibit_warnings => true
    pod 'SSZipArchive', :inhibit_warnings => true
end


target 'Relay' do
    shared_pods
    pod 'ReCaptcha', '1.2', :inhibit_warnings => true
#    pod 'ATAppUpdater', :inhibit_warnings => true
    pod 'SSZipArchive', :inhibit_warnings => true

    target 'RelayTests' do
        inherit! :search_paths
    end
end

target 'RelayDevShareExtension' do
    shared_pods
end

target 'RelayShareExtension' do
    shared_pods
end

target 'RelayMessaging' do
    shared_pods
end

post_install do |installer|
    enable_extension_support_for_purelayout(installer)
end

# PureLayout by default makes use of UIApplication, and must be configured to be built for an extension.
def enable_extension_support_for_purelayout(installer)
    installer.pods_project.targets.each do |target|
        if target.name.end_with? "PureLayout"
            target.build_configurations.each do |build_configuration|
                if build_configuration.build_settings['APPLICATION_EXTENSION_API_ONLY'] == 'YES'
                    build_configuration.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] = ['$(inherited)', 'PURELAYOUT_APP_EXTENSIONS=1']
                end
            end
        end
    end
end

