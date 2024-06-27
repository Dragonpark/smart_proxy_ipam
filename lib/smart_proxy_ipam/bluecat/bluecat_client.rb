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
      @api_base = "#{conf[:url]}/Services/REST/v1/"
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

      get_ipam_subnet_by_cidr(cidr)
    end

    def get_ipam_subnet_by_cidr(cidr)
      params = URI.encode_www_form({ types: 'IP4Network', keyword: cidr, count: 10, start: 0 })
      response = @api_resource.get("searchByObjectTypes?#{params}")
      json_body = JSON.parse(response.body)
      return nil if json_body.count.zero?
      subnet = subnet_from_result(json_body[0])
      return subnet
    end
    
    def get_ipam_groups
      params = URI.encode_www_form({ type: 'Configuration', parentId: 0, count: 100, start: 0 })
      response = @api_resource.get("getEntities?#{params}")
      json_body = JSON.parse(response.body)
      groups = []

      return groups if json_body.count.zero?

      json_body.each do |group|
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
      raise ERRORS[:no_group] if json_body.count.zero?

      data = {
        id: json_body['id'],
        name: json_body['name'],
        type: json_body['type'],
        properties: json_body['properties']
      }

      return data
    end
    
    def get_group_id(group_name)
      return nil if group_name.nil? || group_name.empty?
      group = get_ipam_group(group_name)
      raise ERRORS[:no_group] if group.nil?
      group[:id]
    end

    def add_ip_to_subnet(ip, params)       #WIP
      group_name = params[:group_name]
      if group_name.nil? || group_name.empty?
        group_id =  get_group_id(@default_group)
      else
        group_id = get_group_id(group_name)
      end

      properties = ""
      params = URI.encode_www_form({ action: 'MAKE_STATIC', configurationId: group_id, hostInfo: '', ip4Address: ip, properties: properties })
      response = @api_resource.post("assignIP4Address?#{params}")
      return nil if response.code == '200'
      { error: "Unable to add #{ip} in External IPAM server" }
    end

    def delete_ip_from_subnet(ip, params)
      # Be sure to ignore issues if IP address is not already assigned.
      # Only try to delete if IP is assigned
      params = URI.encode_www_form({ types: 'IP4Address', keyword: ip, count: 10, start: 0 })
      
      response = @api_resource.get("searchByObjectTypes?#{params}")
      json_body = JSON.parse(response.body)
      raise ERRORS[:no_connection] if response.code != '200'
      return nil if json_body.count.zero?

      address_id = json_body[0]['id']
      params = URI.encode_www_form({ objectId: address_id})
      response = @api_resource.delete("delete?#{params}")
      return nil if response.code == '200'
      { error: "Unable to delete #{ip} in External IPAM server" }
    end

    def get_next_ip(mac, cidr, group_name)
      subnet = get_ipam_subnet(cidr, group_name)
      raise ERRORS[:no_subnet] if subnet.nil?
      params = URI.encode_www_form({ parentId: subnet[:id] })
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

    def ip_exists?(ip, subnet_id, group_name)
      params = URI.encode_www_form({keyword: ip, count: 100, start: 0, types: "IP4Address"})
      ip = @api_resource.get("searchByObjectTypes?#{params}")
      json_body = JSON.parse(ip.body)
      return false if json_body.count.zero?
      true
    end

    def authenticated?
      !@token.nil?
    end

    def authenticate
      auth_uri = URI("#{@api_base}login")
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
