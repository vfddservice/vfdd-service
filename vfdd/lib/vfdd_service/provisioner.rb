# Copyright (c) 2012 VMware, Inc. All Rights Reserved.
# VMware copyrighted code is licensed to you under the Apache License, Version
# 2.0 (the "License").  
#
# In addition to the VMware copyrighted code, vFabric Data Director Gateway for
# Cloud Foundry includes a number of components with separate copyright notices
# and license terms. Your use of these components is subject to the terms and
# conditions of the component's license, as noted in the LICENSE file.

$:.unshift File.join(File.dirname(__FILE__), '.')

require "thread"
require "datamapper"
require "uuidtools"

require "base/provisioner"

require "common"
require "vfdd_helper"
require "vfdd_error"


class VCAP::Services::Vfdd::Provisioner < VCAP::Services::Base::Provisioner
  class DatabaseSet
    include DataMapper::Resource
    property :name, String, :key => true
    has n, :databases
  end

  class Database
    include DataMapper::Resource
    property :name, String, :key => true
    property :username, String, :required => true
    property :password, String, :required => true
    property :id, String
    property :uuid, String

    belongs_to :database_set
    
    def to_s
      "id = #{id}, uuid = #{uuid}, name = #{name}"
    end
  end

  include VCAP::Services::Vfdd::Common
  include VCAP::Services::Vfdd

  VFDD_CONFIG_FILE = File.expand_path("../../../config/vfdd_gateway.yml", __FILE__)

  def to_s
    "VCAP::Services::Vfdd::Provisioner instance: #{@vfdd_config.inspect}"
  end

  def get_vfdd_config
    config_file = YAML.load_file(VFDD_CONFIG_FILE)
    config = VCAP.symbolize_keys(config_file)
    config[:vfdd]
  end

  def initialize(options)
    super(options)
    @vfdd_config = options[:additional_options][:vfdd] || get_vfdd_config
    @logger.debug "vfdd_config: #{@vfdd_config.inspect}"

    init_db(@vfdd_config[:local_db])

    @nameserver = @vfdd_config[:nameserver]
    @nameserver_port = @vfdd_config[:nameserver_port]
    @min_pool_size = @vfdd_config[:min_pool_size] || 3
    @db_pool_check_cycle = @vfdd_config[:db_pool_check_cycle] || 10
    @db_cleanup_check_cycle = @vfdd_config[:db_cleanup_check_cycle] || 60
    @update_service_name = @vfdd_config[:update_service_name] || false
    @vfdd_helper = VCAP::Services::Vfdd::Helper.new(@vfdd_config, @logger)

    # start the background worker
    # The reasons to use sync/blocking style instead of em style of 
    # async/non-blocking call are:
    #   1) simple and easy to read
    #   2) the IO model in service gateway is not the bottleneck
    EM.run do
      EM.defer do
        fill_database_pool
      end

      EM.defer do
        cleanup_databases
      end
    end
  end

  def init_db(db_uri)
    DataMapper.setup(:default, db_uri)
    DataMapper.finalize
    DataMapper.auto_upgrade!

    dbset 'creating'
    dbset 'pooled'
    dbset 'deleting'
    dbset 'failed'
  end

  def dbset(category)
    if ['creating', 'pooled', 'deleting', 'failed'].include? category
      DatabaseSet.first_or_create(:name => category)
    end
  end

  def dump_database_status
    ['creating', 'pooled', 'deleting', 'failed'].each do |key|
      databases = dbset(key).databases
      @logger.debug "number of #{key} databases: #{databases.count}"
      databases.each do |db|
        @logger.debug "#{key} db: #{db}"
      end
    end

    nil
  end

  # navie policy
  def pool_under_reserve?
    dump_database_status
    dbset('pooled').databases.count < @min_pool_size
  end

  def check_created_db
    dbset('creating').databases.each do |db|
      @logger.debug "found previous db creation task, name = #{db[:name]}"
      database = @vfdd_helper.find_database_by_name db[:name]
      if database.nil?
        @logger.debug "it's a failed task, no database is created}"
        db.destroy
      else
        case database['status']
          when 'RUNNING'
            db.database_set = dbset('pooled')
            db.save
            @logger.debug "found previously created database: #{db[:name]}"
            true
          when 'PROVISIONING'
            @logger.debug "database creation task is still in progress: #{db[:name]}"
            # do nothing
          else
            # regard as failed
            @logger.warn "database creation failed: #{db[:name]}"
            
            db.database_set = dbset('failed')
            db.save
        end
      end
    end

    nil
  end

  def fill_database_pool
    retries = 0
    while pool_under_reserve? do
      next if check_created_db

      begin
        name = UUIDTools::UUID.random_create.to_s
        username = "cfapp"
        password = UUIDTools::UUID.random_create.hexdigest()[0..16]

        dbset('creating').databases.create(
            :name => name,
            :username => username,
            :password => password,
            :id => nil,
            :uuid => nil)
        service_id, uuid = @vfdd_helper.create_database name, username, password
        retries = 0
        @logger.debug "created new dataabse: #{name}"

        db = dbset('creating').databases.first(:name => name)
        db[:id] = service_id
        db[:uuid] = uuid
        db.database_set = dbset('pooled')
        db.save
      rescue => e
        @logger.error "database creation failed: #{db[:name]}, check detailed information from vFDD side, #{e}"
        db = dbset('creating').databases.first(:name => name)
        db.database_set = dbset('failed')
        db.save
        retries += 1
        sleep retries * 30
        break if retries > 5
        retry
      end
    end

    EM.add_timer(@db_pool_check_cycle) do
      EM.defer do
        fill_database_pool
      end
    end
  end

  def cleanup_databases
    db = dbset('deleting').databases.first
    retries = 0
    while db
      @logger.debug "deleting database: #{db[:id]}"
      begin
        # TODO make this idempotent, i.e. delete an non-existent db will success
        @vfdd_helper.delete_database! db[:id]
        db.destroy
        retries = 0
      rescue => e
        @logger.error "failed to delete database, check details inside vFDD, #{e}"
        retries += 1
        sleep retries * 30
        if retries > 3
          @logger.error "failed to delete database: #{db[:id]}, give up"
          db.database_set = dbset('failed')
          db.save
          db = dbset('deleting').databases.first
          next
        end

        retry
      end
      @logger.debug "database deleted: #{db[:id]}"
      db = dbset('deleting').databases.first
    end

    EM.add_timer(@db_cleanup_check_cycle) do
      EM.defer do
        cleanup_databases
      end
    end
  end

  def provision_service(request, prov_handle=nil, &blk)
    @logger.debug("Attempting to provision instance (request=#{request.inspect})")
    db = dbset('pooled').databases.first
    return blk.call(failure(VfddError.new(VfddError::VFDD_BACKEND_ERROR_POOL_EMPTY))) if db.nil?
    @logger.debug "provision db from pool: #{db}"

    svc_name = db[:name]
    if @update_service_name
      svc_name = request.extract[:name]
      EM.defer do
        # XXX there can be a problem, EM has limited threads which can be used up
        @vfdd_helper.rename_database db[:id], svc_name
      end
    end

    svc = {
           :data => {'name' => svc_name},
           :service_id => db[:id],
           :credentials => {
             'nameserver' => @nameserver,
             'nameserver_port' => @nameserver_port,
             'uuid' => db[:uuid],
             'name' => svc_name,
             'username' => db[:username],
             'password' => db[:password]}
        }

    svc_local = {:configuration => svc[:data],
                 :service_id => svc[:service_id],
                 :credentials => svc[:credentials]}
    db.destroy
    @prov_svcs[svc_local[:service_id]] = svc_local
    @logger.debug("Service provisioned available: #{svc.inspect}")
    blk.call(success(svc))
  end

  def unprovision_service(instance_id, &blk)
    @logger.debug("Attempting to unprovision instance (instance id=#{instance_id})")
    db = @prov_svcs[instance_id]
    if db.nil?
      @logger.warn "trying to delete an non-existent service: #{instance_id}"
    else
      @logger.debug "inserting to delete #{db.inspect}"
      dbset('deleting').databases.create(
          :id => instance_id,
          :name => db[:configuration]['name'],
          :uuid => db[:credentials]['uuid'],
          :username => db[:credentials]['username'],
          :password => db[:credentials]['password']
          )
      @prov_svcs.delete instance_id
    end

    blk.call(success())
  end

  def bind_instance(instance_id, binding_options, bind_handle=nil, &blk)
    @logger.debug("attempting to bind service: #{instance_id}")
    @logger.debug("Current services: #{@prov_svcs}")
    if instance_id.nil? or @prov_svcs[instance_id].nil?
      @logger.warn("invalid instance: #{instance_id}")
      return blk.call(internal_fail)
    end

    svc = @prov_svcs[instance_id]
    handle_id = UUIDTools::UUID.random_create.to_s
    svc_bind = {:service_id => handle_id,
                :configuration => svc[:configuration],
                :credentials => svc[:credentials]}

    @prov_svcs[handle_id] = svc_bind
    blk.call(success(svc_bind))
  end

  def unbind_instance(instance_id, handle_id, binding_options, &blk)
    @logger.debug("attempting to unbind service: #{instance_id}")
    if handle_id.nil? or @prov_svcs[handle_id].nil?
      @logger.warn("invalid bind handle: #{handle_id}")
      return blk.call(internal_fail)
    end

    @prov_svcs.delete handle_id
    blk.call(success())
  end
end
