#!/bin/bash

#####
# Get the latest version number
# https://storage.googleapis.com/kubernetes-release/release/stable.txt
#####
KVERSION=1.23.0-00
NETWORK=10.244.0.0/16
###NETWORK=10.244.0.0/16
# kworker 10.14.0.0 is lxc ips,
# 10.200 is the kube network

echo "Started" > /root/bootstrap.log
date >> /root/bootstrap.log

# This script has been tested on Ubuntu 20.04
# For other versions of Ubuntu, you might need some tweaking
# echo "[TASK 0] Proxy Setup" | tee -a /root/bootstrap.log
# . /etc/environment
# . /etc/profile

echo "[TASK 1] Install containerd runtime" | tee -a /root/bootstrap.log
apt update -qq >> /root/bootstrap.log 2>&1
####apt install -qq -y  firewalld >> /root/bootstrap.log 2>&1
#####systemctl restart firewalld >> /root/bootstrap.log 2>&1
apt install -qq -y containerd apt-transport-https >> /root/bootstrap.log 2>&1
mkdir /etc/containerd
containerd config default > /etc/containerd/config.toml
systemctl enable containerd >> /root/bootstrap.log 2>&1
systemctl restart containerd >> /root/bootstrap.log 2>&1

echo "[TASK 2] Add apt repo for kubernetes" | tee -a /root/bootstrap.log
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add - >> /root/bootstrap.log 2>&1
apt-add-repository "deb http://apt.kubernetes.io/ kubernetes-xenial main" >> /root/bootstrap.log 2>&1

echo "[TASK 3] Install Kubernetes components (kubeadm, kubelet and kubectl)" | tee -a /root/bootstrap.log
apt install -qq -y kubeadm=$KVERSION kubelet=$KVERSION kubectl=$KVERSION >> /root/bootstrap.log 2>&1
echo 'KUBELET_EXTRA_ARGS="--fail-swap-on=false"' > /etc/default/kubelet
systemctl restart kubelet

echo "[TASK 4] Enable ssh password authentication" | tee -a /root/bootstrap.log
sed -i 's/^PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config
echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
systemctl reload sshd

echo "[TASK 5] Set root password" | tee -a /root/bootstrap.log
echo -e "kubeadmin\nkubeadmin" | passwd root >> /root/bootstrap.log 2>&1
echo "export TERM=xterm" >> /etc/bash.bashrc

echo "[TASK 6] Install additional packages" | tee -a /root/bootstrap.log
apt install -qq -y net-tools >> /root/bootstrap.log 2>&1
#apt install -qq -y docker.io >> /root/bootstrap.log 2>&1

# Hack required to provision K8s v1.15+ in LXC containers
if [ ! -e /dev/kmsg ]; then
  mknod /dev/kmsg c 1 11
  echo 'mknod /dev/kmsg c 1 11' >> /etc/rc.local
  chmod +x /etc/rc.local
fi

#######################################
# To be executed only on master nodes #
#######################################

if [[ $(hostname) =~ .*master.* ]]
then

  echo "[TASK 7] Pull required containers" | tee -a /root/bootstrap.log
  kubeadm config images pull >> /root/bootstrap.log 2>&1
  # Stop containerd so the pull will not use the socket
  ##systemctl stop containerd >> /root/bootstrap.log 2>&1
  #kubeadm config images list >> /root/bootstrap.log 2>&1
  #kubeadm config images pull >> /root/bootstrap.log 2>&1
  # Start containerd
  ##systemctl start containerd >> /root/bootstrap.log 2>&1

  echo "[TASK 8] Initialize Kubernetes Cluster" | tee -a /root/bootstrap.log
  echo "kubeadm init >>>>>>" >> /root/bootstrap.log
  kubeadm init --pod-network-cidr=$NETWORK --ignore-preflight-errors=all >> /root/bootstrap.log 2>&1
  echo "<<<<<<<<<<<<<<<<<<<" >> /root/bootstrap.log

  echo "[TASK 9] Copy kube admin config to root user .kube directory" | tee -a /root/bootstrap.log
  mkdir /root/.kube
  cp /etc/kubernetes/admin.conf /root/.kube/config

  # Fix kube-proxy failure to start when can't write to /proc entries
  sleep 10
  kubectl -n kube-system get configmap/kube-proxy -o yaml  | sed "s/maxPerCore: null/maxPerCore: 0/g" | kubectl replace -f - >> /root/bootstrap.log 2>&1
  systemctl restart kubelet
  sleep 10

  echo "[TASK 10] Deploy Flannel network" | tee -a /root/bootstrap.log
  kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml >> /root/bootstrap.log 2>&1

  echo "[TASK 11] Generate and save cluster join command to /joincluster.sh" | tee -a /root/bootstrap.log
  joinCommand=$(kubeadm token create --print-join-command 2>> /root/bootstrap.log)
  echo "$joinCommand --ignore-preflight-errors=all" > /joincluster.sh

fi

###
### To see the conents
### echo "cat /joincluster.sh" | lxc exec kmaster bash
###

#######################################
# To be executed only on worker nodes #
#######################################

if [[ $(hostname) =~ .*worker.* ]]
then
  echo "[TASK 7] Join node to Kubernetes Cluster" | tee -a /root/bootstrap.log
  apt install -qq -y sshpass >> /root/bootstrap.log 2>&1
  sshpass -p "kubeadmin" scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no kmaster.lxd:/joincluster.sh /joincluster.sh 2>/tmp/joincluster.log
  bash /joincluster.sh >> /tmp/joincluster.log 2>&1
fi
