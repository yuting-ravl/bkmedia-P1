Vagrant.configure("2") do |config|
  config.vm.define "server1" do |server1|
    server1.vm.box = "bento/ubuntu-18.04"
    server1.vm.network "private_network", ip: "192.168.33.10"
    server1.vm.synced_folder ".", "/vagrant"
    server1.vm.hostname = "server1"  
  end

  config.vm.define "server2" do |server2|
    server2.vm.box = "bento/ubuntu-18.04"
    server2.vm.network "private_network", ip: "192.168.33.11"
    server2.vm.synced_folder ".", "/vagrant"
    server2.vm.hostname = "server2"  
  end
end