#!/usr/bin/env bash
set -eu

HOSTNAME="$1"
NODE_IP="$2"
REPOSITORY_RAW_SOURCE_URL="https://raw.githubusercontent.com/AlcarisMinecraftServer/alcaris_infra/main"

echo "Setting up Kubernetes node: $HOSTNAME ($NODE_IP)..."

# Determine node role based on hostname
if [[ $HOSTNAME == alcaris-k8s-cp-* ]]; then
    NODE_ROLE="control-plane"
elif [[ $HOSTNAME == alcaris-k8s-wk-* ]]; then
    NODE_ROLE="worker"
else
    echo "Unknown node type: $HOSTNAME"
    exit 1
fi

apt update && apt install -y apt-transport-https ca-certificates curl gnupg software-properties-common

# Load kernel modules and set sysctl parameters
cat <<EOF | tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

cat <<EOF | tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
sysctl --system

# Install and configure containerd
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt update && apt install -y containerd.io

mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
systemctl restart containerd

# Install Kubernetes components
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /' \
    | tee /etc/apt/sources.list.d/kubernetes.list
apt update && apt install -y kubeadm kubectl kubelet
apt-mark hold kubelet kubectl

swapoff -a

# Create crictl configuration file
cat > /etc/crictl.yaml <<EOF
runtime-endpoint: unix:///var/run/containerd/containerd.sock
image-endpoint: unix:///var/run/containerd/containerd.sock
timeout: 10
EOF

if [[ $NODE_ROLE == "control-plane" ]]; then
    echo "Setting up Control Plane: $HOSTNAME"

    # Install helm if not present
    if ! command -v helm &> /dev/null; then
      echo "helm not found, installing..."
      curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    fi

    kubeadm config images pull

    # Initialize the control plane
    kubeadm init --pod-network-cidr=192.168.0.0/16 \
                 --apiserver-advertise-address="${NODE_IP}" \
                 --control-plane-endpoint="${NODE_IP}:6443"

    mkdir -p $HOME/.kube
    cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
    chown $(id -u):$(id -g) $HOME/.kube/config

    # Install Cilium and ArgoCD via Helm
    helm repo add cilium https://helm.cilium.io/
    helm repo update
    helm install cilium cilium/cilium --namespace kube-system

    helm repo add argo https://argoproj.github.io/argo-helm
    helm repo update
    helm install argocd argo/argo-cd --namespace argocd --create-namespace

    # Apply additional manifests from the repository
    kubectl apply -f ${REPOSITORY_RAW_SOURCE_URL}/manifests/apps/root/apps.yaml
    kubectl apply -f ${REPOSITORY_RAW_SOURCE_URL}/manifests/apps/root/projects.yaml

    # Generate join configuration for worker nodes
    cat > /root/join_kubeadm_wk.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: JoinConfiguration
nodeRegistration:
  criSocket: "unix:///var/run/containerd/containerd.sock"
discovery:
  bootstrapToken:
    apiServerEndpoint: "${NODE_IP}:6443"
    token: "$(kubeadm token create)"
    unsafeSkipCAVerification: true
EOF
    chmod 600 /root/join_kubeadm_wk.yaml

elif [[ $NODE_ROLE == "worker" ]]; then
    echo "Setting up Worker Node: $HOSTNAME"

    # Wait for the join configuration file to be available (max 5 minutes)
    TIMEOUT=300
    ELAPSED=0
    while [[ ! -f /root/join_kubeadm_wk.yaml && ${ELAPSED} -lt ${TIMEOUT} ]]; do
        sleep 5
        ELAPSED=$((ELAPSED+5))
        echo "Waiting for join configuration... (${ELAPSED}/${TIMEOUT} seconds)"
        curl -s -o /root/join_kubeadm_wk.yaml ${REPOSITORY_RAW_SOURCE_URL}/join_kubeadm_wk.yaml || true
    done
    if [[ ! -f /root/join_kubeadm_wk.yaml ]]; then
        echo "Timeout waiting for join configuration."
        exit 1
    fi

    chmod 600 /root/join_kubeadm_wk.yaml
    kubeadm join --config /root/join_kubeadm_wk.yaml
fi

echo "Kubernetes setup complete for $HOSTNAME!"
