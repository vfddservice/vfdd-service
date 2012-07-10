# Copyright (c) 2012 VMware, Inc. All Rights Reserved.
# VMware copyrighted code is licensed to you under the Apache License, Version
# 2.0 (the "License").  
#
# In addition to the VMware copyrighted code, vFabric Data Director Gateway for
# Cloud Foundry includes a number of components with separate copyright notices
# and license terms. Your use of these components is subject to the terms and
# conditions of the component's license, as noted in the LICENSE file.

$LOAD_PATH.unshift File.join(File.dirname(__FILE__), '..', '..', '..', 'base', 'lib')

require "base/service_error"

module VCAP
  module Services
    module Vfdd
      class VfddError < VCAP::Services::Base::Error::ServiceError
        VFDD_BACKEND_ERROR_DEFAULT = [31801, HTTP_INTERNAL, 'vFabric Data Director internal error']
        VFDD_BACKEND_ERROR_POOL_EMPTY = [31802, HTTP_INTERNAL, 'No available database in pool']
      end
    end
  end
end
