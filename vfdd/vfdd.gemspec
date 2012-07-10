# -*- encoding: utf-8 -*-

Gem::Specification.new do |s|
  s.name = %q{vfdd-gateway}
  s.version = "0.9"
  s.required_ruby_version = ">= 1.9.2"
  s.platform = "ruby"
  s.required_rubygems_version = ">= 0"
  s.author = "VMware"
  s.email = %q{lhe@vmware.com}
  s.homepage = %q{http://cloudfoundry.org}
  s.summary = %q{Cloud Foundry service gateway for vFabric Data Director}
  s.description = %q{A stright-forward implementation of Cloud Foundry service gateway for vFabric Data Director}
  s.require_paths = ["lib"]
  s.files         = `git ls-files`.split("\n")
  s.test_files    = `git ls-files -- {test,spec,features}/*`.split("\n")
  s.executables   = `git ls-files -- bin/*`.split("\n").map{ |f| File.basename(f) }
end
