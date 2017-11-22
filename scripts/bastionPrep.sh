#!/bin/bash
echo $(date) " - Starting Bastion Prep Script"

RHSMUSERNAME=$1
RHSMPASSWORD="$2"
OS_POOL_ID=$3
STOR_POOL_ID=$4
CLUSTERSIZE=$5

# Remove RHUI

rm -f /etc/yum.repos.d/rh-cloud.repo
sleep 10

# Register Host with Cloud Access Subscription
echo $(date) " - Register host with Cloud Access Subscription"

subscription-manager register --username="$RHSMUSERNAME" --password="$RHSMPASSWORD" || subscription-manager register --activationkey="$RHSMPASSWORD" --org="$RHSMUSERNAME"

if [ $? -eq 0 ]
then
   echo "Subscribed successfully"
else
   echo "Incorrect Username or Password specified"
   exit 3
fi

subscription-manager attach --pool=$OS_POOL_ID > attach.log
if [ $? -eq 0 ]
then
   echo "Pool attached successfully"
else
   evaluate=$( cut -f 2-5 -d ' ' attach.log )
   if [[ $evaluate == "unit has already had" ]]
      then
         echo "Pool $OS_POOL_ID for OpenShift was already attached and was not attached again."
	  else
         echo "Incorrect Pool ID or no entitlements available"
         exit 4
   fi
fi

subscription-manager attach --pool=$STOR_POOL_ID > attach.log
if [ $? -eq 0 ]
then
   echo "Pool attached successfully"
else
   evaluate=$( cut -f 2-5 -d ' ' attach.log )
   if [[ $evaluate == "unit has already had" ]]
      then
         echo "Pool $STOR_POOL_ID for Storage was already attached and was not attached again."
	  else
         echo "Incorrect Pool ID or no entitlements available"
         exit 4
   fi
fi

# Disable all repositories and enable only the required ones
echo $(date) " - Disabling all repositories and enabling only the required repos"

subscription-manager repos --disable="*"

subscription-manager repos \
    --enable="rhel-7-server-rpms" \
    --enable="rhel-7-server-extras-rpms" \
    --enable="rhel-7-server-ose-3.6-rpms" \
    --enable="rhel-7-fast-datapath-rpms" \
	--enable="rh-gluster-3-client-for-rhel-7-server-rpms"

# Install base packages and update system to latest packages
echo $(date) " - Install base packages and update system to latest packages"

yum -y install wget git net-tools bind-utils iptables-services bridge-utils bash-completion httpd-tools kexec-tools sos psacct
yum -y update --exclude=WALinuxAgent

# Ensure proper repos are still enabled
subscription-manager repos \
    --enable="rhel-7-server-rpms" \
    --enable="rhel-7-server-extras-rpms" \
    --enable="rhel-7-server-ose-3.6-rpms" \
    --enable="rhel-7-fast-datapath-rpms" \
	--enable="rh-gluster-3-client-for-rhel-7-server-rpms"

yum -y install atomic-openshift-excluder atomic-openshift-docker-excluder

atomic-openshift-excluder unexclude

# Install OpenShift utilities
echo $(date) " - Installing OpenShift utilities"

yum -y install atomic-openshift-utils

# Create playbook to update ansible.cfg file to include path to library

cat > updateansiblecfg.yaml <<EOF
#!/usr/bin/ansible-playbook
- hosts: localhost
  gather_facts: no
  tasks:
  - lineinfile:
      dest: /etc/ansible/ansible.cfg
      regexp: '^library '
      insertafter: '#library        = /usr/share/my_modules/'
      line: 'library = /usr/share/ansible/openshift-ansible/library/'
EOF

# Run Ansible Playbook to update ansible.cfg file

echo $(date) " - Updating ansible.cfg file"

ansible-playbook ./updateansiblecfg.yaml

if [ $CLUSTERSIZE == "testdrive" ]
then
	sed -i -e "s/glusterfs_nodes | count >= 3/glusterfs_nodes | count >= 1/" /usr/share/ansible/openshift-ansible/roles/openshift_storage_glusterfs/tasks/glusterfs_deploy.yml
fi

echo $(date) " - Script Complete"
