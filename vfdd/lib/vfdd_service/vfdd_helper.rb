# Copyright (c) 2012 VMware, Inc. All Rights Reserved.
# VMware copyrighted code is licensed to you under the Apache License, Version
# 2.0 (the "License").  
#
# In addition to the VMware copyrighted code, vFabric Data Director Gateway for
# Cloud Foundry includes a number of components with separate copyright notices
# and license terms. Your use of these components is subject to the terms and
# conditions of the component's license, as noted in the LICENSE file.

$:.unshift File.dirname(__FILE__)

require 'vfdd_error'

require 'net/http'
require 'net/https'
require 'base64'
require 'json'
require 'uri'

class VCAP::Services::Vfdd::Helper

  include VCAP::Services::Vfdd

  def initialize(vfdd_config, logger)
    @logger = logger

    @host = vfdd_config[:host]
    @port = vfdd_config[:port] || 443
    @api_path = vfdd_config[:api_path] || '/datadirector/api/v1'
    @nameserver = vfdd_config[:nameserver]
    @username = vfdd_config[:username]
    @password = vfdd_config[:password]
    @org = vfdd_config[:org]
    @dbgroup = vfdd_config[:dbgroup]
    @template = vfdd_config[:template]
    @backup_template = vfdd_config[:backup_template]
    @task_timeout = vfdd_config[:task_timeout] || 300

    @dbgroup_id = vfdd_config[:dbgroup_id]
    @template_id = vfdd_config[:template_id]
    @backup_template_id = vfdd_config[:backup_template_id]

    @global_headers = {
            'Authorization' => "Basic %s" % Base64.encode64("%s:%s" % [@username, @password]),
            'Accept' => 'application/json',
            'Content-type' => 'application/json'
    }

    init_vfdd
  end

  def init_vfdd
    org_id = get_org_by_name(@org)
    if org_id.nil?
      @logger.error "can not found org with name: #{@org}"
      raise VfddError.new(VfddError::VFDD_BACKEND_ERROR_DEFAULT)
    end

    @dbgroup_id = @dbgroup_id || get_dbg_by_name(org_id, @dbgroup)
    if @dbgroup_id.nil?
      @logger.error "can not found dbgroup with name: #{@dbgroup}"
      raise VfddError.new(VfddError::VFDD_BACKEND_ERROR_DEFAULT)
    end

    @template_id = @template_id || get_template_by_name(org_id, @template)
    if @template_id.nil?
      @logger.error "can not found template with name: #{@template}"
      raise VfddError.new(VfddError::VFDD_BACKEND_ERROR_DEFAULT)
    end

    @backup_template_id = @backup_template_id ||
                          get_backup_template_by_name(org_id, @backup_template)
    if @backup_template_id.nil?
      @logger.error "can not found backup template with name: #{@backup_template}"
      raise VfddError.new(VfddError::VFDD_BACKEND_ERROR_DEFAULT)
    end

    @logger.debug "param: org:#{org_id}, dbgroup:#{@dbgroup_id}, template=#{@template_id},#{@backup_template_id}"
  end

  def get_connection
    # assume no keep-alive
    conn = Net::HTTP::new(@host, @port)
    conn.use_ssl = true
    conn.verify_mode = OpenSSL::SSL::VERIFY_NONE

    conn
  end

  def http_request(method, path, body = {})
    case method
      when :POST
        resp = get_connection.post(path, body.to_json, @global_headers)
      when :GET
        resp = get_connection.get(path, @global_headers)
      when :PUT
        resp = get_connection.put(path, body.to_json, @global_headers)
      when :DELETE
        resp = get_connection.delete(path, @global_headers)
    end

    if Net::HTTPAccepted === resp
      uris = resp.get_fields('location')
      return uris[0]
    end

    begin
      JSON.parse(resp.body) if resp.body && !resp.body.empty?
    rescue JSON::ParserError
      @logger.error "failed to parse response: #{resp.body}"
      nil
    end
  end

  def get_resource_by_name(uris, name)
    uris.each do |e|
      resource = http_request(:GET, URI(e['href']).path)
      return resource['id'] if resource && resource['name'] == name
    end

    nil
  end

  def get_org_by_name(name)
    orgs = http_request(:GET, '%s/orgs' % @api_path)
    get_resource_by_name(orgs, name) if orgs
  end

  def get_dbg_by_name(org_id, name)
    dbgs = http_request(:GET, '%s/org/%s/dbgroups' % [@api_path, org_id])
    get_resource_by_name(dbgs, name) if dbgs
  end

  def get_template_by_name(org_id, name)
    tmps = http_request(:GET, '%s/org/%s/databasetemplates' % [@api_path, org_id])
    get_resource_by_name(tmps, name) if tmps
  end

  def get_backup_template_by_name(org_id, name)
    tmps = http_request(:GET, '%s/org/%s/backuptemplates' % [@api_path, org_id])
    get_resource_by_name(tmps, name) if tmps
  end

  def wait_task(task_uri, timeout = @task_timeout)
    path = URI(task_uri).path
    while timeout > 0
      task = http_request(:GET, path)
      # status:
      # PENDING, RUNNING,  REVERTING, SUCCESS,  FAILED,  CANCELLED, ERROR_WAIT
      break if ['SUCCESS', 'FAILED', 'CANCELLED'].include? task['status']
      if task['status'] == 'ERROR_WAIT'
       http_request(:POST, '%s?action=cancel' % path)
      end

      sleep 5
      timeout -= 5
    end

    if !task || task['status'] != 'SUCCESS'
      @logger.error "Task timeout or failed: #{task_uri}"
      raise VfddError.new(VfddError::VFDD_BACKEND_ERROR_DEFAULT)
    end

    task
  end

  def create_database(name, user, password)
    @logger.debug "create_database #{name}, #{user}"
    spec = {
      'name' => name,
      'description' => 'database created for cloud foundry',
      'dbgroupId' => @dbgroup_id,
      'ownerName' => user,
      'ownerPassword' => password,
      'dbConfigTemplateId' => @template_id,
      'backupConfigTemplateId' => @backup_template_id
    }

    task = wait_task http_request(:POST, '%s/databases' % @api_path, spec)
    db_uri = task['location']
    db = http_request(:GET, URI(db_uri).path)
    [db['id'], db['uuid']]
  end

  def delete_database!(db_id, delete_backup = false)
    @logger.debug "delete_database #{db_id}"
    return if find_database_by_id(db_id).nil?
    stop_database db_id

    path = '%s/database/%s' % [@api_path, db_id]
    wait_task http_request(:DELETE, path)
  end

  def rename_database(db_id, svc_name)
    @logger.debug "update_database #{db_id}"
    spec = {
      'name' => svc_name,
      'description' => 'databases currently used by Cloud Foundry',
      'dbConfigTemplateId' => @template_id,
      'backupConfigTemplateId' => @backup_template_id,
      'restartIfNeeded' => true
    }

    path = '%s/database/%s' % [@api_path, db_id]
    wait_task http_request(:PUT, path, spec)
  end


  def find_database_by_id(id)
    path = '%s/database/%s' % [@api_path, id]
    http_request(:GET, path)
  end

  def find_database_by_name(name)
    path = '%s/databases' % @api_path
    uris = http_request(:GET, path)
    uris.each do |e|
      db = http_request(:GET, URI(e['href']).path)
      return db if db['name'] == name
    end

    nil
  end

  def start_database(db_id)
    db = find_database_by_id db_id
    return if db.nil?
    if db['status'] == 'STOPPED' # XXX unsafe code
      path = '%s/database/%s?action=start' % [@api_path, db_id]
      wait_task http_request(:POST, path)
    end
  end

  def stop_database(db_id)
    @logger.debug "stop_database #{db_id}"
    db = find_database_by_id db_id
    return if db.nil?
    if db['status'] == 'RUNNING' # XXX unsafe code
      path = '%s/database/%s?action=stop' % [@api_path, db_id]
      wait_task http_request(:POST, path)
    end
  end

  def delete_all_databases!
  @logger.debug "delete_all_databases!"
    path = '%s/databases' % @api_path
    uris = http_request(:GET, path)
    uris.each do |e|
      db = http_request(:GET, URI(e['href']).path)
      delete_database! db['id']
    end

    nil
  end
end
