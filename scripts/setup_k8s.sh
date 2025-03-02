#!/bin/bash

CONTROL_PLANE_IP="192.168.0.111"
VM_LIST=()

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --vm-list) VM_LIST=($2); shift ;;
        *) echo "Unknown parameter: $1"; exit 1 ;;
    esac
    shift
done

echo "Setting up Kubernetes Control Plane on $CONTROL_PLANE_IP..."

ssh root@$CONTROL_PLANE_IP << EOF
  apt update && apt install -y apt-transport-https ca-certificates curl gnupg
  curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
  echo "deb https://apt.kubernetes.io/ kubernetes-xenial main" > /etc/apt/sources.list.d/kubernetes.list
  apt install -y kubelet kubeadm kubectl

  echo "Installing HAProxy and Keepalived..."
  apt install -y haproxy keepalived

  echo "Installing Helm..."
  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

  echo "Initializing Kubernetes Cluster..."
  kubeadm init --pod-network-cidr=192.168.0.0/16
  mkdir -p \$HOME/.kube
  cp -i /etc/kubernetes/admin.conf \$HOME/.kube/config
  chown \$(id -u):\$(id -g) \$HOME/.kube/config

  echo "Installing Cilium as CNI..."
  helm repo add cilium https://helm.cilium.io/
  helm repo update
  helm install cilium cilium/cilium --namespace kube-system

  echo "Installing ArgoCD..."
  helm repo add argo https://argoproj.github.io/argo-helm
  helm repo update
  helm install argocd argo/argo-cd --namespace argocd --create-namespace

  echo "Applying ArgoCD Application and Project Configuration..."
  kubectl apply -f https://raw.githubusercontent.com/AlcarisMinecraftServer/alcaris_infra/master/manifests/apps/root/apps.yaml
  kubectl apply -f https://raw.githubusercontent.com/AlcarisMinecraftServer/alcaris_infra/master/manifests/apps/root/projects.yaml
EOF

JOIN_COMMAND=$(ssh root@$CONTROL_PLANE_IP "kubeadm token create --print-join-command")

echo "Joining Worker Nodes..."

for VM in "${VM_LIST[@]}"; do
    read -r VMID VMNAME CPU MEM VMSRVIP TARGET_IP <<< "$VM"
    if [[ "$VMNAME" == alcaris-k8s-wk-* ]]; then
        echo "Joining Worker: $VMNAME ($TARGET_IP)"
        ssh root@$TARGET_IP << EOF
          apt update && apt install -y apt-transport-https ca-certificates curl gnupg
          curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
          echo "deb https://apt.kubernetes.io/ kubernetes-xenial main" > /etc/apt/sources.list.d/kubernetes.list
          apt install -y kubelet kubeadm kubectl
          $JOIN_COMMAND
EOF
    fi
done

echo "ArgoCD and Kubernetes setup complete. Minecraft server will be managed via ArgoCD."
