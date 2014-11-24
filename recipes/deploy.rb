# Generates the sidekiq configuration files for a rails app and workers that run within the Rails application
# environment. The global configuration file will setup overall parameters for the client and server. The
# worker configuration files will setup parameters specific for each worker. For each worker, will add a
# information required for monit to monitor and manage availability of the worker.
#
# This recipe assumes you have already run the OpsWorks rails deploy recipe (e.g. rails::deploy). If using the
# standard OpsWorks Rails application layer, then this will already be done with the built in recipes. If using
# within a custom layer, either include the rails deploy recipe before this recipe or use a wrapper cookbook
# that includes both recipes.

include_recipe 'deploy'
include_recipe "opsworks_sidekiq::service"

# setup sidekiq service per app
node[:deploy].each do |application, deploy|

	if deploy[:application_type] != 'rails'
		Chef::Log.debug("Skipping opsworks_sidekiq::setup application #{application} as it is not a Rails app")
		next
	end

	app_shared_dir        = "#{deploy['deploy_to']}/shared"
	app_shared_config_dir = "#{app_shared_dir}/config"

	user  = deploy[:user]
	group = deploy[:group]

	if node[:sidekiq][application]
		template "#{app_shared_config_dir}/sidekiq.yml" do
			source 'sidekiq.yml.erb'

			mode '0644'
			owner user
			group group

			variables(redis_config: node[:sidekiq][application][:redis_config] || {})

			only_if do
				File.directory?(app_shared_config_dir)
			end
		end

		workers = node[:sidekiq][application][:workers].to_hash.reject {|k,v| k.to_s =~ /restart_command|syslog/ }
		workers.each do |worker, options|

			# Convert attribute classes to plain old ruby objects
			config = options[:config] ? options[:config].to_hash : {}
			config.each do |k, v|
				case v
					when Chef::Node::ImmutableArray
						config[k] = v.to_a
					when Chef::Node::ImmutableMash
						config[k] = v.to_hash
				end
			end

			# Generate YAML string
			yaml = YAML::dump(config)

			# Convert YAML string keys to symbol keys for sidekiq while preserving indentation. (queues: to :queues:)
			yaml = yaml.gsub(/^(\s*)([^:][^\s]*):/,'\1:\2:')

			(options[:process_count] || 1).times do |n|
				file "#{app_shared_config_dir}/sidekiq_#{worker}#{n+1}.yml" do
					mode 0644
					action :create
					content yaml
				end
			end
		end

		template "#{node[:monit][:conf_dir]}/sidekiq_#{application}.monitrc" do
			mode 0644
			source "sidekiq_monitrc.erb"
			variables({
						  :deploy => deploy,
						  :application => application,
						  :workers => workers,
						  :syslog => node[:sidekiq][application][:syslog]
					  })

			notifies :reload, resources(service:  'monit'), :immediately
		end

	end
end


  # Chef::Log.debug("Restarting Sidekiq Workers: #{application}")
  # execute "restart Rails app #{application}" do
  #   command node[:sidekiq][application][:restart_command]
  # end
