#!/usr/bin/env bash

set -eu

function usage() {
    echo "usage> setup_k8s.sh [COMMAND]"
    echo "[COMMAND]:"
    echo "  help        show command usage"
    echo "  alcaris-k8s-cp-1    run setup script for alcaris-k8s-cp-1"
    echo "  alcaris-k8s-wk-*    run setup script for alcaris-k8s-wk-*"
}

case $1 in
    alcaris-k8s-cp-1|alcaris-k8s-wk-*)
        ;;
    help)
        usage
        exit 255
        ;;
    *)
        usage
        exit 255
        ;;
esac

KUBE_API_SERVER_VIP="192.168.0.11"
NODE_IP="$2"

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
swapoff -a

cat > /etc/crictl.yaml <<EOF
runtime-endpoint: unix:///var/run/containerd/containerd.sock
image-endpoint: unix:///var/run/containerd/containerd.sock
timeout: 10
EOF

# Ends except worker-plane
case $1 in
    alcaris-k8s-wk-*)
        exit 0
        ;;
    alcaris-k8s-cp-1)
        ;;
    *)
        exit 1
        ;;
esac

# Pull images first
kubeadm config images pull

# install k9s
wget https://github.com/derailed/k9s/releases/download/v0.32.7/k9s_Linux_amd64.tar.gz -O - | tar -zxvf - k9s && sudo mv ./k9s /usr/local/bin/

# Set kubeadm bootstrap token using openssl
KUBEADM_BOOTSTRAP_TOKEN=$(openssl rand -hex 3).$(openssl rand -hex 8)

# Set init configuration for the first control plane
cat > "$HOME"/init_kubeadm.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
bootstrapTokens:
  - token: "$KUBEADM_BOOTSTRAP_TOKEN"
    description: "kubeadm bootstrap token"
    ttl: "24h"
nodeRegistration:
    criSocket: "unix:///var/run/containerd/containerd.sock"
    kubeletExtraArgs:
      node-ip: "$NODE_IP"
localAPIEndpoint:
    advertiseAddress: "$NODE_IP"
    bindPort: 6443
skipPhases:
    - addon/kube-proxy
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
networking:
    serviceSubnet: "10.96.64.0/18"
    podSubnet: "10.96.128.0/18"
etcd:
    local:
    extraArgs:
kubernetesVersion: "v1.32.1"
controlPlaneEndpoint: "${KUBE_API_SERVER_VIP}:6443"
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
cp -i /etc/kubernetes/admin.conf "$HOME"/.kube/config
chown "$(id -u)":"$(id -g)" "$HOME"/.kube/config

# Install Helm CLI
curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash


# Install Cilium Helm chart
helm repo add cilium https://helm.cilium.io/
helm install cilium cilium/cilium \
    --namespace kube-system \
    --set kubeProxyReplacement=true \
    --set k8sServiceHost=$KUBE_API_SERVER_VIP \
    --set k8sServicePort=6443 \
    --set bgpControlPlane.enabled=true

# Install OpenEBS Helm chart
helm repo add openebs https://openebs.github.io/charts
helm install openebs openebs/openebs \
    --create-namespace \
    --namespace openebs

# Install ArgoCD Helm chart
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd \
    --version 5.36.10 \
    --create-namespace \
    --namespace argocd \
    --values https://raw.githubusercontent.com/AlcarisMinecraftServer/alcaris_infra/main/manifests/argocd-helm-chart-values.yaml
helm install argocd argo/argocd-apps \
    --version 0.0.1 \
    --values https://raw.githubusercontent.com/AlcarisMinecraftServer/alcaris_infra/main/manifests/argocd-apps-helm-chart-values.yaml

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: cluster-wide-apps
---
apiVersion: v1
kind: Secret
metadata:
  name: external-k8s-endpoint
  namespace: cluster-wide-apps
type: Opaque
stringData:
  fqdn: "$KUBE_API_SERVER_VIP"
  port: "6443"
EOF

# clone repo
git clone -b main https://github.com/AlcarisMinecraftServer/alcaris_infra.git "$HOME"/alcaris_infra

# add join information to ansible hosts variable
echo "kubeadm_bootstrap_token: $KUBEADM_BOOTSTRAP_TOKEN" >> "$HOME"/alcaris_infra/ansible/hosts/servers/group_vars/all.yaml

# install ansible
sudo apt-get install -y ansible git sshpass

# export ansible.cfg target
export ANSIBLE_CONFIG="$HOME"/alcaris_infra/ansible/ansible.cfg

# run ansible-playbook
ansible-galaxy role install -r "$HOME"/alcaris_infra/ansible/roles/requirements.yaml
ansible-galaxy collection install -r "$HOME"/alcaris_infra/ansible/roles/requirements.yaml
ansible-playbook -i "$HOME"/alcaris_infra/ansible/hosts/servers/inventory "$HOME"/alcaris_infra/ansible/site.yaml
