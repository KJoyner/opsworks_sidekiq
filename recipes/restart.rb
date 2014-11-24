include_recipe 'deploy'

node[:deploy].each do |application, deploy|

	execute "stop Rails app #{application}" do
		command "sudo monit restart -g sidekiq_#{application}_group"
	end

end
