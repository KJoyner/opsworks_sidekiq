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

# When we deploy a new app, we need to do the following:
#   1) Send a STOP+TERM signal to the current monit configuration group
#   2) Create and link to the new monit configuration group
#   3) Reload monit
#   4) Restart configuration group
#
# When rolling back to a previous app, we need to do the following:
#	1) Send a STOP+TERM signal to the current monit configuration group
#	2) Link to the previous monit configuration group
#   3) Unlink the current monit configuration group
# 	4) Reload monit
#	5) Start the previous monit configuration group

# setup sidekiq service per app
node[:deploy].each do |application, deploy|

	if deploy[:application_type] != 'rails'
		Chef::Log.debug("Skipping opsworks_sidekiq::setup application #{application} as it is not a Rails app")
		next
	end

	app_shared_config_dir = "#{deploy['deploy_to']}/shared/config"

	app_non_shared_config_dir = "#{deploy['deploy_to']}/config"
	app_non_shared_pids_dir   = "#{app_shared_dir}/config"

	user  = deploy[:user]
	group = deploy[:group]

	if node[:sidekiq][application]

		Chef::Log.debug("Stopping current Sidekiq workers for #{application}")
		execute "stopping sidekiq workers for #{application}" do
			command "sudo monit stop -g sidekiq_#{application}"
		end

		# Currently, the global sidekiq config is applicable to all versions of this app. It configures the client
		# and the server with parameters applicable to all versions (e.g. redis endpoint).
		#
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

		# The individual worker configuration files and the Monit configuration file which refers to these workers
		# are created within the release directory. This enables us to overlap monit stop command on current workers
		# and start command on new workers (in particular, the pidfiles need to be different). Also, there is no real
		# advantage to keeping these files in a shared directory.

		# Make sure the non-shared PIDs directory exists since this doesn't normally get created
		#
		directory app_non_shared_pids_dir do
			owner user
			group group
			mode 0770

			action :create
			recursive true
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
				file "#{app_non_shared_config_dir}/sidekiq_#{worker}#{n+1}.yml" do
					owner user
					group group
					mode 0644
					action :create
					content yaml
				end
			end
		end

		sidekiq_monitrc_file = "#{app_non_shared_config_dir}/sidekiq_#{application}.monitrc}"
		link "#{node[:monit][:conf_dir]}/sidekiq_#{application}.monitrc" do
			to sidekiq_monitrc_file
			mode 0644
		end

		# create template after link so when we reload server, everything is good to go
		template sidekiq_monitrc_file do
			source "sidekiq_monitrc.erb"

			owner user
			group group
			mode 0644

			variables({
						  :deploy => deploy,
						  :application => application,
						  :workers => workers,
						  :syslog => node[:sidekiq][application][:syslog]
					  })

			notifies :reload, resources(service:  'monit'), :immediately
		end


		# TODO: Determine if we need to start sidekiq workers or if the reload will start them!
	end
end
