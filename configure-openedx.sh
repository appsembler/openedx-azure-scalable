#!/bin/bash

# Copyright (c) Microsoft Corporation. All Rights Reserved.
# Licensed under the MIT license. See LICENSE file on the project webpage for details.

# print commands and arguments as they are executed
set -x

echo "Starting Open edX scalable multiserver install on pid $$"
date
ps axjf

#############
# Parameters
#############

AZUREUSER=$1
PASSWORD=$2
NUM_APP_SERVERS=$3
NUM_MYSQL_SERVERS=$4
NUM_MONGO_SERVERS=$5
HOMEDIR="/home/$AZUREUSER"
VMNAME=`hostname`
echo "User: $AZUREUSER"
echo "User home dir: $HOMEDIR"
echo "vmname: $VMNAME"

###################
# Common Functions
###################

ensureAzureNetwork()
{
  # ensure the host name is resolvable
  hostResolveHealthy=1
  for i in {1..120}; do
    host $VMNAME
    if [ $? -eq 0 ]
    then
      # hostname has been found continue
      hostResolveHealthy=0
      echo "the host name resolves"
      break
    fi
    sleep 1
  done
  if [ $hostResolveHealthy -ne 0 ]
  then
    echo "host name does not resolve, aborting install"
    exit 1
  fi

  # ensure the network works
  networkHealthy=1
  for i in {1..12}; do
    wget -O/dev/null http://bing.com
    if [ $? -eq 0 ]
    then
      # hostname has been found continue
      networkHealthy=0
      echo "the network is healthy"
      break
    fi
    sleep 10
  done
  if [ $networkHealthy -ne 0 ]
  then
    echo "the network is not healthy, aborting install"
    ifconfig
    ip a
    exit 2
  fi
}
ensureAzureNetwork

###################################################
# Configure SSH keys
###################################################
time sudo apt-get -y update && sudo apt-get -y upgrade
sudo apt-get -y install sshpass
ssh-keygen -f $HOMEDIR/.ssh/id_rsa -t rsa -N ''

#copy ssh key to all app servers (including localhost)
for i in `seq 0 $(($NUM_APP_SERVERS-1))`; do
  cat $HOMEDIR/.ssh/id_rsa.pub | sshpass -p $PASSWORD ssh -o "StrictHostKeyChecking no" $AZUREUSER@10.0.0.1$i 'cat >> .ssh/authorized_keys && echo "Key copied Appserver #$i"'
done
#terrible hack for getting keys onto db server
for i in `seq 0 $(($NUM_MYSQL_SERVERS-1))`; do
  cat $HOMEDIR/.ssh/id_rsa.pub | sshpass -p $PASSWORD ssh -o "StrictHostKeyChecking no" $AZUREUSER@10.0.0.2$i 'cat >> .ssh/authorized_keys && echo "Key copied MySQL #$i"'
done

for i in `seq 0 $(($NUM_MONGO_SERVERS-1))`; do
  cat $HOMEDIR/.ssh/id_rsa.pub | sshpass -p $PASSWORD ssh -o "StrictHostKeyChecking no" $AZUREUSER@10.0.0.3$i 'cat >> .ssh/authorized_keys && echo "Key copied MongoDB #$i"'
done

#make sure premissions are correct
sudo chown -R $AZUREUSER:$AZUREUSER $HOMEDIR/.ssh/

###################################################
# Update Ubuntu and install prereqs
###################################################

time sudo apt-get -y update && sudo apt-get -y upgrade
time sudo apt-get install -y build-essential software-properties-common python-software-properties curl git-core libxml2-dev libxslt1-dev libfreetype6-dev python-pip python-apt python-dev libxmlsec1-dev swig
time sudo pip install --upgrade pip
time sudo pip install --upgrade virtualenv

###################################################
# Pin specific version of Open edX (named-release/cypress for now)
###################################################
export OPENEDX_RELEASE='named-release/cypress'
cat >/tmp/extra_vars.yml <<EOL
---
edx_platform_version: "$OPENEDX_RELEASE"
certs_version: "$OPENEDX_RELEASE"
forum_version: "$OPENEDX_RELEASE"
xqueue_version: "$OPENEDX_RELEASE"
configuration_version: "appsembler/azureDeploy"
edx_ansible_source_repo: "https://github.com/appsembler/configuration"

EOL

###################################################
# Set database vars
###################################################
cat >/tmp/db_vars.yml <<EOL 
---
EDXAPP_MYSQL_USER_HOST: "%"
EDXAPP_MYSQL_HOST: "10.0.0.20"
EDXLOCAL_MYSQL_BIND_IP: "0.0.0.0"
XQUEUE_MYSQL_HOST: "10.0.0.20"
ORA_MYSQL_HOST: "10.0.0.20"
MONGO_BIND_IP: "0.0.0.0"
FORUM_MONGO_HOSTS: ["10.0.0.30"]
EDXAPP_MONGO_HOSTS: ["10.0.0.30"]
EDXAPP_MEMCACHE: ["10.0.0.20:11211"]
MEMCACHED_BIND_IP: "0.0.0.0"

EOL

###################################################
# Download configuration repo and start ansible
###################################################

cd /tmp
time git clone https://github.com/appsembler/configuration.git
cd configuration
time git checkout appsembler/azureDeploy
time sudo pip install -r requirements.txt
cd playbooks/appsemblerPlaybooks

#create inventory.ini file
echo "[mongo-server]" > inventory.ini
for i in `seq 0 $(($NUM_MONGO_SERVERS-1))`; do
  echo "10.0.0.3$i" >> inventory.ini
done
echo "" >> inventory.ini
echo "[mysql-master-server]" >> inventory.ini
echo "10.0.0.20" >> inventory.ini
if (( $NUM_MYSQL_SERVERS > 1 )); then
  echo "" >> inventory.ini
  echo "[mysql-slave-server]" >> inventory.ini
  echo "10.0.0.21" >> inventory.ini
fi
echo "" >> inventory.ini
echo "[edxapp-primary-server]" >> inventory.ini
echo "localhost" >> inventory.ini
echo "" >> inventory.ini
echo "[edxapp-additional-server]" >> inventory.ini
for i in `seq 1 $(($NUM_APP_SERVERS-1))`; do
  echo "10.0.0.1$i" >> inventory.ini
done

curl https://raw.githubusercontent.com/tkeemon/openedx-azure-scalable/master/server-vars.yml > /tmp/server-vars.yml

sudo ansible-playbook -i inventory.ini -u $AZUREUSER --private-key=$HOMEDIR/.ssh/id_rsa multiserver_deploy.yml -e@/tmp/server-vars.yml -e@/tmp/extra_vars.yml -e@/tmp/db_vars.yml

date
echo "Completed Open edX multiserver provision on pid $$"
