require 'yaml'
require 'json'
require 'net/http'
require 'uri'
require 'sinatra'
require 'smart_proxy_ipam/ipam'
require 'smart_proxy_ipam/ipam_helper'
require 'smart_proxy_ipam/ipam_validator'
require 'smart_proxy_ipam/api_resource'
require 'smart_proxy_ipam/ip_cache'

module Proxy::Bluecat
  # Implementation class for External IPAM provider Bluecat
  class BluecatClient
    include Proxy::Log
    include Proxy::Ipam::IpamHelper
    include Proxy::Ipam::IpamValidator

    def initialize(conf)
      @conf = conf
      @api_base = "/Services/REST/v1/"
      @default_group = @conf[:default_group]
      @token = authenticate
      @api_resource = Proxy::Ipam::ApiResource.new(api_base: @api_base, token: "#{@token}")
      @ip_cache = Proxy::Ipam::IpCache.instance
      @ip_cache.set_provider_name('bluecat')
    end

    def get_ipam_subnet(cidr, group_name = nil)
      if group_name.nil? || group_name.empty?
        logger.debug(@default_group)
        group_id =  get_group_id(@default_group)
      else
        group_id = get_group_id(group_name)
      end

      get_ipam_subnet_by_cidr(cidr, group_id)
    end

    def get_ipam_subnet_by_cidr(cidr)
      params = URI.encode_www_form({ types: 'IP4Network', keyword: cidr, count: 10, start: 0 })
      response = @api_resource.get("searchByObjectTypes?#{params}")
      json_body = JSON.parse(response.body)
      return nil if json_body['count'].zero?
      subnet = subnet_from_result(json_body['results'][0])
      return subnet if json_body['results']
    end
    
    def get_ipam_groups
      params = URI.encode_www_form({ type: 'Configuration', parentId: 0, count: 100, start: 0 })
      response = @api_resource.get("getEntities?#{params}")
      json_body = JSON.parse(response.body)
      groups = []

      return groups if json_body['count'].zero?

      json_body['results'].each do |group|
        groups.push({
          name: group['name'],
          description: group['properties'].split("|")[0].split("=")[1]
        })
      end

      groups
    end
    
    def get_ipam_group(group_name)
      return nil if group_name.nil?
      params = URI.encode_www_form({ parentId: 0, name: group_name, type: 'Configuration' })
      group = @api_resource.get("getEntityByName?#{params}")
      json_body = JSON.parse(group.body)
      raise ERRORS[:no_group] if json_body['data'].nil?

      data = {
        id: json_body['id'],
        name: json_body['name'],
        type: json_body['type'],
        properties: json_body['properties']
      }

      return data if json_body['data']
    end
    
    def get_group_id(group_name)
      return nil if group_name.nil? || group_name.empty?
      group = get_ipam_group(group_name)
      raise ERRORS[:no_group] if group.nil?
      group[:id]
    end

    def add_ip_to_subnet(ip, params)       #WIP
      desc = 'Address auto added by Foreman'
      group_id = get_group_id(params[:group_name])
      properties = "Notes=Address auto added by Foreman|name="
      params = URI.encode_www_form({ action: 'MAKE_STATIC', configurationId: group_id, hostInfo: '', ip4Address: ip, properties: 'Notes=Created by Foreman' })

      response = @api_resource.post("assignIP4Address?#{params}")
      return nil if response.code != '200'
      { error: "Unable to add #{address} in External IPAM server" }
    end

    def delete_ip_from_subnet(ip, params)
      params = URI.encode_www_form({ types: 'IP4Address', keyword: ip, count: 10, start: 0 })
      
      response = @api_resource.delete("searchByObjectTypes?#{params}")
      json_body = JSON.parse(response.body)

      return { error: ERRORS[:no_ip] } if json_body['count'].zero?

      address_id = json_body[0]['id']
      params = URI.encode_www_form({ objectId: address_id})
      response = @api_resource.delete("delete/#{params}/")
      return nil if response.code != '200'
      { error: "Unable to delete #{ip} in External IPAM server" }
    end

    def get_next_ip(mac, cidr, group_name)
      subnet = get_ipam_subnet(cidr, group_name)
      raise ERRORS[:no_subnet] if subnet.nil?
      params = URI.encode_www_form({ parentId: subnet['parentId'] })
      response = @api_resource.get("getNextAvailableIP4Address?#{params}")
      json_body = JSON.parse(response.body)
      return nil if json_body.empty?
      ip = json_body
      next_ip = cache_next_ip(@ip_cache, ip, mac, cidr, subnet[:id], group_name)
      { data: next_ip }
    end

    def groups_supported?
      true
    end

    def authenticated?
      !@token.nil?
    end

    private

    def authenticate
      auth_uri = URI("https://#{@conf[:url]}#{@api_base}login")
      auth_uri.query = "username=#{@conf[:user]}&password=#{@conf[:password]}"

      request = Net::HTTP::Get.new(auth_uri)
      request['Content-Type'] = 'application/json'

      response = Net::HTTP.start(auth_uri.hostname, auth_uri.port, use_ssl: auth_uri.scheme == 'https', :verify_mode => OpenSSL::SSL::VERIFY_NONE) do |http|
        http.request(request)
      end
      if response.code == '200'
        token = response.body.split()[2] + " " + response.body.split()[3]
      end
    end

    def subnet_from_result(result)
      {
        id: result['id'],
        subnet: result['properties'].split("CIDR=")[1].split("|")[0].split("/").first,
        mask: result['properties'].split("CIDR=")[1].split("|")[0].split("/").last,
        description: result['name']
      }
    end
  end
end
