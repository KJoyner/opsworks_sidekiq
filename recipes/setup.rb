# Setup sudoer file for each deploy user so that user can restart workers.

include_recipe 'deploy'
include_recipe "opsworks_sidekiq::service"

node[:deploy].each do |application, deploy|

	if deploy[:application_type] != 'rails'
		Chef::Log.debug("Skipping opsworks_sidekiq::setup application #{application} as it is not a Rails app")
		next
	end

	user  = deploy[:user]

	# TODO: What if sudoers file already exists for the deploy user? Should we do this differently.
	# allow deploy user to restart workers
	template "/etc/sudoers.d/#{user}" do
		mode 0440
		source "sudoer.erb"
		variables user: user
	end

end
