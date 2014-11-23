# Adapted from unicorn::rails: https://github.com/aws/opsworks-cookbooks/blob/master/unicorn/recipes/rails.rb

include_recipe "opsworks_sidekiq::service"

# setup sidekiq service per app
node[:deploy].each do |application, deploy|

	if deploy[:application_type] != 'rails'
		Chef::Log.debug("Skipping opsworks_sidekiq::setup application #{application} as it is not a Rails app")
		next
	end

	opsworks_deploy_user do
		deploy_data deploy
	end

	user  = deploy['user']
	group = deploy['group']

	opsworks_deploy_dir do
		user  user
		group group
		path  deploy[:deploy_to]
	end

	# Allow deploy user to restart workers
	template "/etc/sudoers.d/#{deploy[:user]}" do
		mode 0440
		source "sudoer.erb"
		variables :user => deploy[:user]
	end

	if node[:sidekiq][application]

		app_dir               = "#{deploy['deploy_to']}/current"
		app_shared_dir        = "#{deploy['deploy_to']}/shared"
		app_shared_config_dir = "#{app_shared_dir}/config"

		shared_sidekiq_config_file = "#{app_shared_config_dir}/sidekiq.yml"
		template "#{shared_sidekiq_config_file}" do
			source 'sidekiq.yml.erb'

			mode '0644'
			owner user
			group group

			variables({
						  :redis =>  node[:sidekiq][application]['redis'] || {}
					  })
		end
		link "#{app_dir}/config/sidekiq.yml" do
			to shared_sidekiq_config_file
			owner user
			group group
		end

		workers = node[:sidekiq][application].to_hash.reject {|k,v| k.to_s =~ /restart_command|syslog/ }
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

			# Convert YAML string keys to symbol keys for sidekiq while preserving
			# indentation. (queues: to :queues:)
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
			notifies :reload, resources(:service => "monit"), :immediately
		end

	end
end
