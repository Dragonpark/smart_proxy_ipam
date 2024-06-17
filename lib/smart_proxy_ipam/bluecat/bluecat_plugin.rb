module Proxy::Bluecat
  class Plugin < ::Proxy::Provider
    plugin :externalipam_bluecat, Proxy::Ipam::VERSION

    requires :externalipam, Proxy::Ipam::VERSION
    validate :verify_ssl, verify_ssl: true
    validate_presence :user, :password, :url

    load_classes(proc do
      require 'smart_proxy_ipam/bluecat/bluecat_client'
    end)

    load_dependency_injection_wirings(proc do |container_instance, settings|
      container_instance.dependency :externalipam_client, -> { ::Proxy::Bluecat::BluecatClient.new(settings) }
    end)
  end
end
