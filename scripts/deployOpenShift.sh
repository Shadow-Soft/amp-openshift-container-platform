#!/bin/bash

echo $(date) " - Starting Script"

set -e

export SUDOUSER=$1
export PASSWORD="$2"
PRIVATEKEY=$3
MASTER=$4
MASTERPUBLICIPHOSTNAME=$5
MASTERPUBLICIPADDRESS=$6
export INFRA=$7
NODE=$8
NODECOUNT=$9
INFRACOUNT=${10}
MASTERCOUNT=${11}
ROUTING=${12}
export REGISTRYSA=${13}
export REGSAKEY="${14}"
export TENANTID=${15}
export SUBSCRIPTIONID=${16}
AZURE=${17}
export AADCLIENTID=${18}
export AADCLIENTSECRET="${19}"
export RESOURCEGROUP=${20}
export LOCATION=${21}
STORAGEACCOUNT1=${22}
SAKEY1=${23}
NODESUBNET=${24}

export BASTION=$(hostname)

# Determine if Commercial Azure or Azure Government
CLOUD=$( curl -H Metadata:true "http://169.254.169.254/metadata/instance/compute/location?api-version=2017-04-02&format=text" | cut -c 1-2 )
CLOUD=${CLOUD^^}

MASTERLOOP=$((MASTERCOUNT - 1))
INFRALOOP=$((INFRACOUNT - 1))
NODELOOP=$((NODECOUNT - 1))

export INFRATYPE="infra"

# Copying files to $SUDOUSER home directory
currentDir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
if [ $MASTERCOUNT -eq 1 ]
then
	cp ${currentDir}/setup-azure-master-single.yml /home/${SUDOUSER}/setup-azure-master.yml
else
	cp ${currentDir}/setup-azure-master-multi.yml /home/${SUDOUSER}/setup-azure-master.yml
fi
cp ${currentDir}/setup-azure-node-master.yml /home/${SUDOUSER}/
cp ${currentDir}/setup-azure-node.yml /home/${SUDOUSER}/
cp ${currentDir}/delete-stuck-nodes.yml /home/${SUDOUSER}/
cp ${currentDir}/configurestorageclass.yml /home/${SUDOUSER}/
cp ${currentDir}/vars.yml /home/${SUDOUSER}/
cp ${currentDir}/addocpuser.yml /home/${SUDOUSER}/
cp ${currentDir}/assignclusteradminrights.yml /home/${SUDOUSER}/
cp ${currentDir}/assignrootpassword.yml /home/${SUDOUSER}/
cp ${currentDir}/dockerregistry.yml /home/${SUDOUSER}/
chown -R ${SUDOUSER}. /home/${SUDOUSER}/*

cd /home/${SUDOUSER}
# Generate private keys for use by Ansible
echo $(date) " - Generating Private keys for use by Ansible for OpenShift Installation"

echo "Generating Private Keys"

runuser $SUDOUSER -c "echo \"$PRIVATEKEY\" > ~/.ssh/id_rsa"
runuser $SUDOUSER -c "chmod 600 ~/.ssh/id_rsa*"

echo "Configuring SSH ControlPath to use shorter path name"

sed -i -e "s/^# control_path = %(directory)s\/%%h-%%r/control_path = %(directory)s\/%%h-%%r/" /etc/ansible/ansible.cfg
sed -i -e "s/^#host_key_checking = False/host_key_checking = False/" /etc/ansible/ansible.cfg
sed -i -e "s/^#pty=False/pty=False/" /etc/ansible/ansible.cfg

# Run on MASTER-0 node - configure registry to use Azure Storage
# Create docker registry config based on Commercial Azure or Azure Government

if [[ $CLOUD == "US" ]]
then
	sed -i '${s/.$/ -e REGISTRY_STORAGE_AZURE_REALM=core.usgovcloudapi.net"/}' /home/${SUDOUSER}/dockerregistry.yml
fi

# Create Ansible Hosts File
echo $(date) " - Create Ansible Hosts file"

# Build glusterfs node list
# Grab drive name from host

runuser $SUDOUSER -c "ssh-keyscan -H ${NODESUBNET}4 >> ~/.ssh/known_hosts"
drive=$(runuser $SUDOUSER -c "ssh ${NODESUBNET}4 'sudo /usr/sbin/fdisk -l'" | awk '$1 == "Disk" && $2 ~ /^\// && ! /mapper/ {if (drive) print drive; drive = $2; sub(":", "", drive);} drive && /^\// {drive = ""} END {if (drive) print drive;}')

# Fill in the first line of glusterinfo
glusterInfo="${NODE}-0 glusterfs_ip=${NODESUBNET}4 glusterfs_devices='[ \"${drive}\" ]'"

# Loop to fill in the rest of the lines in the same way
for (( c=1; c<$NODECOUNT; c++ ))
do
runuser $SUDOUSER -c "ssh-keyscan -H ${NODESUBNET}$((c+4)) >> ~/.ssh/known_hosts"
drive=$(runuser $SUDOUSER -c "ssh ${NODESUBNET}$((c+4)) 'sudo /usr/sbin/fdisk -l'" | awk '$1 == "Disk" && $2 ~ /^\// && ! /mapper/ {if (drive) print drive; drive = $2; sub(":", "", drive);} drive && /^\// {drive = ""} END {if (drive) print drive;}')
glusterInfo="$glusterInfo
${NODE}-${c} glusterfs_ip=${NODESUBNET}$((c+4)) glusterfs_devices='[ \"${drive}\" ]'"
done

# Creating the first half of the hosts file
cat > /etc/ansible/hosts <<EOF
# Set variables common for all OSEv3 hosts
[OSEv3:vars]
ansible_ssh_user=$SUDOUSER
ansible_become=yes
openshift_install_examples=true
deployment_type=openshift-enterprise
openshift_release=v3.6
docker_udev_workaround=True
openshift_use_dnsmasq=True
openshift_master_default_subdomain=${ROUTING}
openshift_override_hostname_check=true
#osm_use_cockpit=false
os_sdn_network_plugin_name='redhat/openshift-ovs-multitenant'
openshift_master_console_port=443
openshift_master_api_port=443
openshift_cloudprovider_kind=azure
osm_default_node_selector='type=app'
openshift_disable_check=memory_availability,docker_image_availability

#Cloud Native Container Storage
openshift_hosted_registry_storage_kind=glusterfs
#openshift_storage_glusterfs_use_default_selector=False
#openshift_storage_glusterfs_namespace=glusterfs 
#openshift_storage_glusterfs_name=storage
#openshift_storage_glusterfs_nodeselector='type=${INFRATYPE}'
#openshift_storage_glusterfs_is_native=True

# default selectors for router and registry services
openshift_router_selector='type=${INFRATYPE}'
openshift_registry_selector='type=${INFRATYPE}'

openshift_master_cluster_method=native
openshift_master_cluster_hostname=$MASTERPUBLICIPHOSTNAME
openshift_master_cluster_public_hostname=$MASTERPUBLICIPHOSTNAME

# Enable HTPasswdPasswordIdentityProvider
openshift_master_identity_providers=[{'name': 'htpasswd_auth', 'login': 'true', 'challenge': 'true', 'kind': 'HTPasswdPasswordIdentityProvider', 'filename': '/etc/origin/master/htpasswd'}]

# Setup metrics
openshift_hosted_metrics_deploy=false
openshift_metrics_cassandra_storage_type=dynamic
openshift_metrics_start_cluster=true
openshift_metrics_hawkular_nodeselector={"type":"${INFRATYPE}"}
openshift_metrics_cassandra_nodeselector={"type":"${INFRATYPE}"}
openshift_metrics_heapster_nodeselector={"type":"${INFRATYPE}"}
openshift_hosted_metrics_public_url=https://metrics.${ROUTING}/hawkular/metrics

# Setup logging
openshift_hosted_logging_deploy=false
openshift_hosted_logging_storage_kind=dynamic
openshift_logging_fluentd_nodeselector={"logging":"true"}
openshift_logging_es_nodeselector={"type":"${INFRATYPE}"}
openshift_logging_kibana_nodeselector={"type":"${INFRATYPE}"}
openshift_logging_curator_nodeselector={"type":"${INFRATYPE}"}
openshift_master_logging_public_url=https://kibana.${ROUTING}

EOF

# Creating the 2nd half of the hosts file
if [ $MASTERCOUNT -eq 1 ]
then
echo $(date) " - Configuring host file based on single master"

cat >> /etc/ansible/hosts <<EOF
# Create an OSEv3 group that contains the masters and nodes groups
[OSEv3:children]
masters
nodes
master0
glusterfs
glusterfs_registry
new_nodes

# host group for masters
[masters]
$MASTER-0

[master0]
$MASTER-0

[glusterfs]
$glusterInfo

[glusterfs_registry]
$glusterInfo

# host group for nodes
[nodes]
$MASTER-0 openshift_node_labels="{'type': 'master', 'zone': 'default'}" openshift_hostname=$MASTER-0
EOF

else
echo $(date) " - Configuring host file based on multi-master"

cat >> /etc/ansible/hosts <<EOF
# Create an OSEv3 group that contains the masters and nodes groups
[OSEv3:children]
masters
nodes
etcd
master0
glusterfs
glusterfs_registry
new_nodes

# host group for masters
[masters]
$MASTER-[0:${MASTERLOOP}]

# host group for etcd
[etcd]
$MASTER-[0:${MASTERLOOP}] 

[master0]
$MASTER-0

[glusterfs]
$glusterInfo

[glusterfs_registry]
$glusterInfo

# host group for nodes
[nodes]
EOF

	# Loop to add Masters

	for (( c=0; c<$MASTERCOUNT; c++ ))
	do
	  echo "$MASTER-$c openshift_node_labels=\"{'type': 'master', 'zone': 'default'}\" openshift_hostname=$MASTER-$c" >> /etc/ansible/hosts
	done
fi


# Loop to add Infra Nodes to /etc/ansible/hosts

for (( c=0; c<$INFRACOUNT; c++ ))
do
  echo "$INFRA-$c openshift_node_labels=\"{'type': 'infra', 'zone': 'default'}\" openshift_hostname=$INFRA-$c" >> /etc/ansible/hosts
done

# Loop to add Nodes to /etc/ansible/hosts

for (( c=0; c<$NODECOUNT; c++ ))
do
  echo "$NODE-$c openshift_node_labels=\"{'type': 'app', 'zone': 'default'}\" openshift_hostname=$NODE-$c" >> /etc/ansible/hosts
done

# Create new_nodes group in /etc/ansible/hosts

cat >> /etc/ansible/hosts <<EOF

# host group for adding new nodes
[new_nodes]
EOF

echo $(date) " - Running network_manager.yml playbook" 
DOMAIN=`domainname -d` 

# Setup NetworkManager to manage eth0 
runuser $SUDOUSER -c "ansible-playbook /usr/share/ansible/openshift-ansible/playbooks/byo/openshift-node/network_manager.yml" 

# Configure resolv.conf on all hosts through NetworkManager 
echo $(date) " - Setting up NetworkManager on eth0" 

runuser $SUDOUSER -c "ansible all -b -m service -a \"name=NetworkManager state=restarted\"" 
sleep 5 
runuser $SUDOUSER -c "ansible all -b -m command -a \"nmcli con modify eth0 ipv4.dns-search $DOMAIN\"" 
runuser $SUDOUSER -c "ansible all -b -m service -a \"name=NetworkManager state=restarted\"" 

# Initiating installation of OpenShift Container Platform using Ansible Playbook
echo $(date) " - Installing OpenShift Container Platform via Ansible Playbook"

runuser $SUDOUSER -c "ansible-playbook /usr/share/ansible/openshift-ansible/playbooks/byo/config.yml -vvvvv"

if [ $? -eq 0 ]
then
   echo $(date) " - OpenShift Cluster installed successfully"
else
   echo $(date) " - OpenShift Cluster failed to install"
   exit 6
fi

echo $(date) " - Modifying sudoers"

sed -i -e "s/Defaults    requiretty/# Defaults    requiretty/" /etc/sudoers
sed -i -e '/Defaults    env_keep += "LC_TIME LC_ALL LANGUAGE LINGUAS _XKB_CHARSET XAUTHORITY"/aDefaults    env_keep += "PATH"' /etc/sudoers

# Deploying Registry
echo $(date) "- Registry automatically deployed to infra nodes"

# Deploying Router
echo $(date) "- Router automaticaly deployed to infra nodes"

echo $(date) "- Re-enabling requiretty"

sed -i -e "s/# Defaults    requiretty/Defaults    requiretty/" /etc/sudoers

# Install OpenShift Atomic Client
echo $(date) "- Installing OpenShift CLI tool (oc)"
cd /root
mkdir .kube
runuser ${SUDOUSER} -c "scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${SUDOUSER}@${MASTER}-0:~/.kube/config /tmp/kube-config"
cp /tmp/kube-config /root/.kube/config
mkdir /home/${SUDOUSER}/.kube
cp /tmp/kube-config /home/${SUDOUSER}/.kube/config
chown --recursive ${SUDOUSER} /home/${SUDOUSER}/.kube
rm -f /tmp/kube-config
yum -y install atomic-openshift-clients 

# Adding user to OpenShift authentication file
echo $(date) "- Adding OpenShift user"

runuser $SUDOUSER -c "ansible-playbook ~/addocpuser.yml"

# Assigning cluster admin rights to OpenShift user
echo $(date) "- Assigning cluster admin rights to user"

runuser $SUDOUSER -c "ansible-playbook ~/assignclusteradminrights.yml"

if [[ $COCKPIT == "true" ]]
then

# Setting password for root if Cockpit is enabled
echo $(date) "- Assigning password for root, which is used to login to Cockpit"

runuser $SUDOUSER -c "ansible-playbook ~/assignrootpassword.yml"
fi

# Configure Docker Registry to use Azure Storage Account
echo $(date) "- Configuring Docker Registry to use Azure Storage Account"

runuser $SUDOUSER -c "ansible-playbook ~/dockerregistry.yml"

if [[ $AZURE == "true" ]]
then
	# Create Storage Classes
	echo $(date) "- Creating Storage Classes"

	runuser $SUDOUSER -c "ansible-playbook ~/configurestorageclass.yml"

	echo $(date) "- Sleep for 120"

	sleep 120

	# Execute setup-azure-master and setup-azure-node playbooks to configure Azure Cloud Provider
	echo $(date) "- Configuring OpenShift Cloud Provider to be Azure"

	runuser $SUDOUSER -c "ansible-playbook ~/setup-azure-master.yml"

	if [ $? -eq 0 ]
	then
	   echo $(date) " - Cloud Provider setup of master config on Master Nodes completed successfully"
	else
	   echo $(date) "- Cloud Provider setup of master config on Master Nodes failed to completed"
	   exit 7
	fi

	runuser $SUDOUSER -c "ansible-playbook ~/setup-azure-node-master.yml"

	if [ $? -eq 0 ]
	then
	   echo $(date) " - Cloud Provider setup of node config on Master Nodes completed successfully"
	else
	   echo $(date) "- Cloud Provider setup of node config on Master Nodes failed to completed"
	   exit 8
	fi

	runuser $SUDOUSER -c "ansible-playbook ~/setup-azure-node.yml"

	if [ $? -eq 0 ]
	then
	   echo $(date) " - Cloud Provider setup of node config on App Nodes completed successfully"
	else
	   echo $(date) "- Cloud Provider setup of node config on App Nodes failed to completed"
	   exit 9
	fi

	runuser $SUDOUSER -c "ansible-playbook ~/delete-stuck-nodes.yml"

	if [ $? -eq 0 ]
	then
	   echo $(date) " - Cloud Provider setup of OpenShift Cluster completed successfully"
	else
	   echo $(date) "- Cloud Provider setup failed to delete stuck Master nodes or was not able to set them as unschedulable"
	   exit 10
	fi
fi

oc label nodes --all logging-infra-fluentd=true logging=true

# Delete postinstall.yml file
echo $(date) "- Deleting unecessary files"

rm /home/${SUDOUSER}/addocpuser.yml
rm /home/${SUDOUSER}/assignclusteradminrights.yml
rm /home/${SUDOUSER}/assignrootpassword.yml
rm /home/${SUDOUSER}/dockerregistry.yml
rm /home/${SUDOUSER}/vars.yml
rm /home/${SUDOUSER}/setup-azure-master.yml
rm /home/${SUDOUSER}/setup-azure-node-master.yml
rm /home/${SUDOUSER}/setup-azure-node.yml
rm /home/${SUDOUSER}/delete-stuck-nodes.yml

echo $(date) " - Script complete"
