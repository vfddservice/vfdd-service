# Copyright (c) 2012 VMware, Inc. All Rights Reserved.
# VMware copyrighted code is licensed to you under the Apache License, Version
# 2.0 (the "License").  
#
# In addition to the VMware copyrighted code, vFabric Data Director Gateway for
# Cloud Foundry includes a number of components with separate copyright notices
# and license terms. Your use of these components is subject to the terms and
# conditions of the component's license, as noted in the LICENSE file.

$LOAD_PATH.unshift File.join(File.dirname(__FILE__), '..', 'lib')
$LOAD_PATH.unshift(File.expand_path("../../../base/lib", __FILE__))

require "vfdd_service/vfdd_helper"
$LOAD_PATH.unshift File.join(File.dirname(__FILE__), '..', '..', '..', '..')
require "vcap/common"

describe VCAP::Services::Vfdd::Helper do
  before :all do
    config_file = File.join(File.dirname(__FILE__), '..', 'config', 'vfdd_gateway.yml')
    config = YAML::load(File.open(config_file))
    config = VCAP.symbolize_keys(config)
    logger = Logger.new(STDOUT)
    logger.level = Logger::DEBUG
    @vfdd = VCAP::Services::Vfdd::Helper.new(config[:vfdd], logger)

    @db_name = 'database1'
    @db_new_name = 'newdatabasename'
#@id, @uuid = @vfdd.create_database @db_name, 'user1', 'password'
    @id=94
    @vfdd.rename_database @id, @db_new_name
  end

  after :all do
    @vfdd.delete_database! @id
  end

  it "find by id should work" do
    db = @vfdd.find_database_by_name @db_name
    db['id'].should == @id
  end
  
  it "find by name should work" do
    db = @vfdd.find_database_by_id @id
    db['name'].should == @db_new_name
  end

  it "stop should success" do
    @vfdd.stop_database @id
    # stop again should also success
    @vfdd.stop_database @id
  end

  it "start should success" do
    @vfdd.start_database @id
    # start again should also success
    @vfdd.start_database @id
  end
end
