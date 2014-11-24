
include_recipe 'deploy'

node[:deploy].each do |application, deploy|

  if deploy[:application_type] != 'rails'
    Chef::Log.debug("Skipping opsworks_sidekiq::undeploy application #{application} as it is not an Rails app")
    next
  end

  sidekiq_monitrc_file = "#{node[:monit][:conf_dir]}/sidekiq_#{application}.monitrc"
  file  sidekiq_monitrc_file do
	  action :delete

	  notifies :reload, resources(service:  'monit'), :immediately

	  only_if do
		  File.exists?(sidekiq_monitrc_file)
	  end
  end

end
