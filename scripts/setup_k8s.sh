#!/bin/bash

set -eu

HOSTNAME=$1
CONTROL_PLANE_IP="192.168.0.11"
REPOSITORY_RAW_SOURCE_URL="https://raw.githubusercontent.com/AlcarisMinecraftServer/alcaris_infra/main"

# パッケージの共通インストール
apt update && apt install -y apt-transport-https ca-certificates curl gnupg software-properties-common

# Containerd のセットアップ
cat <<EOF | sudo tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
sudo sysctl --system

# Install Containerd
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
apt update && apt install -y containerd.io

# Configure containerd
mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sed -i -e "s/SystemdCgroup = false/SystemdCgroup = true/g" /etc/containerd/config.toml
systemctl restart containerd

# Install Kubernetes
curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
echo "deb https://apt.kubernetes.io/ kubernetes-xenial main" > /etc/apt/sources.list.d/kubernetes.list
apt update
apt install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

# Disable swap
swapoff -a

# CP / WK の判定
if [[ "$HOSTNAME" == alcaris-k8s-cp-* ]]; then
  echo "Setting up Kubernetes Control Plane on $HOSTNAME..."

  # Install HAProxy & Keepalived
  apt install -y haproxy keepalived

  # Install Helm
  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

  # kubeadm init
  kubeadm init --pod-network-cidr=192.168.0.0/16 --apiserver-advertise-address=$CONTROL_PLANE_IP
  mkdir -p $HOME/.kube
  cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  chown $(id -u):$(id -g) $HOME/.kube/config

  # Install Cilium
  helm repo add cilium https://helm.cilium.io/
  helm repo update
  helm install cilium cilium/cilium --namespace kube-system

  # Install ArgoCD
  helm repo add argo https://argoproj.github.io/argo-helm
  helm repo update
  helm install argocd argo/argo-cd --namespace argocd --create-namespace

  # Apply ArgoCD Configuration
  kubectl apply -f ${REPOSITORY_RAW_SOURCE_URL}/manifests/apps/root/apps.yaml
  kubectl apply -f ${REPOSITORY_RAW_SOURCE_URL}/manifests/apps/root/projects.yaml

elif [[ "$HOSTNAME" == alcaris-k8s-wk-* ]]; then
  echo "Joining Kubernetes Worker Node: $HOSTNAME"
  
  JOIN_COMMAND=$(ssh root@$CONTROL_PLANE_IP "kubeadm token create --print-join-command")
  $JOIN_COMMAND
fi

echo "Kubernetes setup complete for $HOSTNAME"
