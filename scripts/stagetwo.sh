#!/bin/bash

export SUDOUSER=$1
export COCKPIT=$2
export AZURE=$3
export MASTER=$4

echo $(date) " - Modifying sudoers"

sed -i -e "s/Defaults    requiretty/# Defaults    requiretty/" /etc/sudoers
sed -i -e '/Defaults    env_keep += "LC_TIME LC_ALL LANGUAGE LINGUAS _XKB_CHARSET XAUTHORITY"/aDefaults    env_keep += "PATH"' /etc/sudoers

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

	#runuser $SUDOUSER -c "ansible-playbook ~/setup-azure-node.yml"

	#if [ $? -eq 0 ]
	#then
	#   echo $(date) " - Cloud Provider setup of node config on App Nodes completed successfully"
	#else
	#	echo $(date) "- Cloud Provider setup of node config on App Nodes failed to completed"
	#   exit 9
	#fi

	#runuser $SUDOUSER -c "ansible-playbook ~/delete-stuck-nodes.yml"

	#if [ $? -eq 0 ]
	#then
	#   echo $(date) " - Cloud Provider setup of OpenShift Cluster completed successfully"
	#else
	#   echo $(date) "- Cloud Provider setup failed to delete stuck Master nodes or was not able to set them as unschedulable"
	#   exit 10
	#fi
fi

oc label nodes --all logging-infra-fluentd=true logging=true