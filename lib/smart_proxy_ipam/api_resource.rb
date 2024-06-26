require 'yaml'
require 'json'
require 'net/http'
require 'uri'
require 'smart_proxy_ipam/ipam_helper'

module Proxy::Ipam
  # Class to handle authentication and HTTP transactions with External IPAM providers
  class ApiResource
    include ::Proxy::Log
    include Proxy::Ipam::IpamHelper

    def initialize(params = {})
      @api_base = params[:api_base]
      @token = params[:token]
      @auth_header = params[:auth_header] || 'Authorization'
    end

    def get(path)
      uri = URI(@api_base + path)
      request = Net::HTTP::Get.new(uri)
      request[@auth_header] = @token
      request['Accept'] = 'application/json'

      Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https', :verify_mode => OpenSSL::SSL::VERIFY_NONE) do |http|
        http.request(request)
      end
    end

    def delete(path)
      uri = URI(@api_base + path)
      request = Net::HTTP::Delete.new(uri)
      request[@auth_header] = @token
      request['Accept'] = 'application/json'

      Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https', :verify_mode => OpenSSL::SSL::VERIFY_NONE) do |http|
        http.request(request)
      end
    end

    def post(path, body = nil)
      uri = URI(@api_base + path)
      request = Net::HTTP::Post.new(uri)
      request.body = body
      request[@auth_header] = @token
      request['Accept'] = 'application/json'
      request['Content-Type'] = 'application/json'

      Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https', :verify_mode => OpenSSL::SSL::VERIFY_NONE) do |http|
        http.request(request)
      end
    end
  end
end
