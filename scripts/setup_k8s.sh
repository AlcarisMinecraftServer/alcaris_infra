#!/bin/bash

set -e

# Set global variables
KUBE_API_SERVER_VIP=192.168.0.100
VIP_INTERFACE=ens18
NODE_IPS=( 192.168.0.11 )
# NODE_IPS=( 192.168.0.11 192.168.0.12 )

case $1 in
    alcaris-k8s-cp-1)
        KEEPALIVED_STATE=MASTER
        KEEPALIVED_PRIORITY=101
        KEEPALIVED_UNICAST_SRC_IP=${NODE_IPS[0]}
        #KEEPALIVED_UNICAST_PEERS=( "${NODE_IPS[1]}" )
        KEEPALIVED_UNICAST_PEERS=( )
        ;;
    alcaris-k8s-cp-2)
        KEEPALIVED_STATE=BACKUP
        KEEPALIVED_PRIORITY=99
        KEEPALIVED_UNICAST_SRC_IP=${NODE_IPS[1]}
        KEEPALIVED_UNICAST_PEERS=( "${NODE_IPS[0]}" )
        ;;
    alcaris-k8s-wk-*)
        ;;
    *)
        exit 1
        ;;
esac

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
sudo sed -i.bak '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
sudo swapoff -a

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
    alcaris-k8s-cp-1|alcaris-k8s-cp-2)
        ;;
    *)
        exit 1
        ;;
esac

# Install HAProxy
apt-get install -y --no-install-recommends software-properties-common
add-apt-repository ppa:vbernat/haproxy-3.1 -y
sudo apt-get install -y haproxy=3.1.\*

cat > /etc/haproxy/haproxy.cfg <<EOF
global
    log /dev/log    local0
    log /dev/log    local1 notice
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin expose-fd listeners
    stats timeout 30s
    user haproxy
    group haproxy
    daemon
defaults
    log     global
    mode    http
    option  httplog
    option  dontlognull
    timeout connect 5000
    timeout client  50000
    timeout server  50000
    errorfile 400 /etc/haproxy/errors/400.http
    errorfile 403 /etc/haproxy/errors/403.http
    errorfile 408 /etc/haproxy/errors/408.http
    errorfile 500 /etc/haproxy/errors/500.http
    errorfile 502 /etc/haproxy/errors/502.http
    errorfile 503 /etc/haproxy/errors/503.http
    errorfile 504 /etc/haproxy/errors/504.http
frontend k8s-api
    bind ${KUBE_API_SERVER_VIP}:8443
    mode tcp
    option tcplog
    default_backend k8s-api
backend k8s-api
    mode tcp
    option tcplog
    option tcp-check
    balance roundrobin
    default-server inter 10s downinter 5s rise 2 fall 2 slowstart 60s maxconn 250 maxqueue 256 weight 100
    server k8s-api-1 ${NODE_IPS[0]}:6443 check
EOF

# server k8s-api-2 ${NODE_IPS[1]}:6443 check

# Install Keepalived
echo "net.ipv4.ip_nonlocal_bind = 1" >> /etc/sysctl.conf
sysctl -p
apt-get -y install keepalived

cat > /usr/local/bin/check_haproxy.sh <<'EOS'
#!/bin/bash
/usr/bin/nc -z -w1 127.0.0.1 8443
if [ $? -eq 0 ]; then
    exit 0
else
    exit 1
fi
EOS
chmod +x /usr/local/bin/check_haproxy.sh

cat > /etc/keepalived/keepalived.conf <<EOF
vrrp_script chk_haproxy {
    script "/usr/local/bin/check_haproxy.sh"
    interval 2
    weight 2
}

vrrp_instance LB_VIP {
    interface ${VIP_INTERFACE}
    state ${KEEPALIVED_STATE}
    priority ${KEEPALIVED_PRIORITY}
    virtual_router_id 51

    smtp_alert
    authentication {
        auth_type AH
        auth_pass zaq12wsx
    }

    unicast_src_ip ${KEEPALIVED_UNICAST_SRC_IP}
    unicast_peer {
$( for peer in "${KEEPALIVED_UNICAST_PEERS[@]}"; do
    echo "        $peer"
done )
    }

    virtual_ipaddress {
        ${KUBE_API_SERVER_VIP}
    }

    track_script {
        chk_haproxy
    }
}
EOF

# Create keepalived user
groupadd -r keepalived_script || true
useradd -r -s /sbin/nologin -g keepalived_script -M keepalived_script || true

echo "keepalived_script ALL=(ALL) NOPASSWD: /usr/bin/killall" >> /etc/sudoers

# Enable VIP services
systemctl enable keepalived --now
systemctl enable haproxy --now

# Reload VIP services
systemctl reload keepalived
systemctl reload haproxy

# Pull images first
kubeadm config images pull

# install k9s
wget https://github.com/derailed/k9s/releases/download/v0.32.7/k9s_Linux_amd64.tar.gz -O - | tar -zxvf - k9s && sudo mv ./k9s /usr/local/bin/

# Ends except first-control-plane
case $1 in
    alcaris-k8s-cp-1)
        ;;
    alcaris-k8s-cp-2)
        exit 0
        ;;
    *)
        exit 1
        ;;
esac

# Set kubeadm bootstrap token using openssl
KUBEADM_BOOTSTRAP_TOKEN=$(openssl rand -hex 3).$(openssl rand -hex 8)

# Initialize Kubernetes cluster
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
  podSubnet: "10.96.128.0/18"
  serviceSubnet: "10.96.64.0/18"
kubernetesVersion: "v1.32.1"
controlPlaneEndpoint: "192.168.0.100:8443"
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

kubectl taint nodes alcaris-k8s-cp-1 node-role.kubernetes.io/control-plane-

# Install Helm CLI
curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash

# Install Cilium Helm chart
helm repo add cilium https://helm.cilium.io/
helm install cilium cilium/cilium \
    --namespace kube-system \
    --set kubeProxyReplacement=true \
    --set k8sServiceHost=${KUBE_API_SERVER_VIP} \
    --set k8sServicePort=8443 \
    --set bgpControlPlane.enabled=true \
    --set ipam.mode=cluster-pool

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

# # Generate control plane certificate
# KUBEADM_UPLOADED_CERTS=$(kubeadm init phase upload-certs --upload-certs | tail -n 1)

# # clone repo
# git clone -b main https://github.com/AlcarisMinecraftServer/alcaris_infra.git "$HOME"/alcaris_infra

# # add join information to ansible hosts variable
# echo "kubeadm_bootstrap_token: $KUBEADM_BOOTSTRAP_TOKEN" >> "$HOME"/alcaris_infra/ansible/hosts/servers/group_vars/all.yaml
# echo "kubeadm_uploaded_certs: $KUBEADM_UPLOADED_CERTS" >> "$HOME"/alcaris_infra/ansible/hosts/servers/group_vars/all.yaml

# # install ansible
# sudo apt-get install -y ansible git sshpass

# # export ansible.cfg target
# export ANSIBLE_CONFIG="$HOME"/alcaris_infra/ansible/ansible.cfg

# # run ansible-playbook
# ansible-galaxy role install -r "$HOME"/alcaris_infra/ansible/roles/requirements.yaml
# ansible-galaxy collection install -r "$HOME"/alcaris_infra/ansible/roles/requirements.yaml
# ansible-playbook -i "$HOME"/alcaris_infra/ansible/hosts/servers/inventory "$HOME"/alcaris_infra/ansible/site.yaml
