#!/bin/bash

set -e

# Install Containerd
cat <<EOF | sudo tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

# Setup required sysctl params, these persist across reboots.
cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

# Apply sysctl params without reboot
sudo sysctl --system

# Add the repository to Apt sources:
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    | tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update

sudo apt-get install -y containerd.io

# Configure containerd
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's#sandbox_image = "registry.k8s.io/pause:3.8"#sandbox_image = "registry.k8s.io/pause:3.10"#g' /etc/containerd/config.toml
if grep -q "SystemdCgroup = true" "/etc/containerd/config.toml"; then
    echo "Config found, skip rewriting..."
else
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
fi

sudo systemctl restart containerd

# Modify kernel parameters for Kubernetes
cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
vm.overcommit_memory = 1
vm.panic_on_oom = 0
kernel.panic = 10
kernel.panic_on_oops = 1
kernel.keys.root_maxkeys = 1000000
kernel.keys.root_maxbytes = 25000000
net.ipv4.conf.*.rp_filter = 0
net.ipv4.tcp_fastopen=3
fs.inotify.max_user_watches=65536
fs.inotify.max_user_instances=8192
EOF
sysctl --system

# Install kubeadm
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
apt-get update
apt-get install -y kubeadm=1.32.1-1.1 kubectl=1.32.1-1.1 kubelet=1.32.1-1.1
apt-mark hold kubelet kubectl

# Disable swap
sudo swapoff -a

cat > /etc/crictl.yaml <<EOF
runtime-endpoint: unix:///var/run/containerd/containerd.sock
image-endpoint: unix:///var/run/containerd/containerd.sock
timeout: 10
EOF

# Pull images first
kubeadm config images pull

# install k9s
wget https://github.com/derailed/k9s/releases/download/v0.32.7/k9s_Linux_amd64.tar.gz -O - | tar -zxvf - k9s && sudo mv ./k9s /usr/local/bin/

# Initialize Kubernetes cluster
cat > "$HOME"/init_kubeadm.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
nodeRegistration:
  criSocket: "unix:///var/run/containerd/containerd.sock"
  kubeletExtraArgs:
    node-ip: "192.168.0.11"
localAPIEndpoint:
  advertiseAddress: "192.168.0.11"
  bindPort: 6443
skipPhases:
    - addon/kube-proxy
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
networking:
  podSubnet: "10.96.128.0/18"
  serviceSubnet: "10.96.64.0/18"
kubernetesVersion: "v1.32.1"
controlPlaneEndpoint: "192.168.0.11:6443"
controllerManager:
    extraArgs:
        bind-address: "0.0.0.0"
scheduler:
    extraArgs:
        bind-address: "0.0.0.0"
clusterName: "alcaris-cloud"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: "systemd"
protectKernelDefaults: true
EOF

# Install Kubernetes without kube-proxy
kubeadm init --config "$HOME"/init_kubeadm.yaml --skip-phases=addon/kube-proxy --ignore-preflight-errors=NumCPU,Mem

# Set up kubeconfig for the current user
mkdir -p "$HOME"/.kube
sudo cp -i /etc/kubernetes/admin.conf "$HOME"/.kube/config
sudo chown "$(id -u)":"$(id -g)" "$HOME"/.kube/config

kubectl taint nodes alcaris-k8s node-role.kubernetes.io/control-plane-

# Install Helm CLI
curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash

# Install Cilium Helm chart
helm repo add cilium https://helm.cilium.io/
helm install cilium cilium/cilium \
    --namespace kube-system \
    --set kubeProxyReplacement=true \
    --set k8sServiceHost=192.168.0.11 \
    --set k8sServicePort=6443 \
    --set bgpControlPlane.enabled=true
  
# Install ArgoCD Helm chart
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd \
    --version 5.36.10 \
    --create-namespace \
    --namespace argocd \
    --values https://raw.githubusercontent.com/AlcarisMinecraftServer/alcaris_infra/main/manifests/argocd-helm-chart-values.yaml
helm install argocd argo/argocd-apps \
    --version 0.0.1 \
    --namespace argocd \
    --values https://raw.githubusercontent.com/AlcarisMinecraftServer/alcaris_infra/main/manifests/argocd-apps-helm-chart-values.yaml

# Check the cluster status (nodes and pods)
kubectl get nodes
kubectl get pods --all-namespaces