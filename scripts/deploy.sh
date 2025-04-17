#!/bin/bash

TEMPLATE_VMID=9000
TEMPLATE_STORAGE=nfs-share
CLOUDINIT_IMAGE_TARGET_VOLUME=nfs-share
TEMPLATE_BOOT_IMAGE_TARGET_VOLUME=nfs-share
BOOT_IMAGE_TARGET_VOLUME=local-lvm
SNIPPET_TARGET_VOLUME=local
LOCAL_SNIPPET_DIR=/var/lib/vz/snippets
REPOSITORY_RAW_SOURCE_URL="https://raw.githubusercontent.com/AlcarisMinecraftServer/alcaris_infra/main"

VM_LIST=(
  #vmid #vmname          #cpu #mem   #vmsrvip      #targetip      #targethost
  "1001 alcaris-k8s-cp-1 4    8192   192.168.0.11  192.168.0.110  nmkmn-srv-prox01"
  "1002 alcaris-k8s-cp-2 4    8192   192.168.0.12  192.168.0.111  nmkmn-srv-prox02"
  "1101 alcaris-k8s-wk-1 4    24576  192.168.0.21  192.168.0.110  nmkmn-srv-prox01"
  "1102 alcaris-k8s-wk-2 4    24576  192.168.0.22  192.168.0.111  nmkmn-srv-prox02"
)

echo "Creating Cloud-Init template..."

# Download Ubuntu 24.04 Cloud Image
wget -O /tmp/noble-server-cloudimg-amd64.img https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img

# Install qemu-guest-agent into the image
apt-get update && apt-get install -y libguestfs-tools
virt-customize -a /tmp/noble-server-cloudimg-amd64.img --install liburing2 --install qemu-guest-agent

# Create a new VM and attach a network adapter (vmbr0)
qm create $TEMPLATE_VMID --cores 2 --memory 4096 --net0 virtio,bridge=vmbr0 --name alcaris-k8s-template

# Import disk and extract actual disk ID
DISK_IMPORT_OUTPUT=$(qm importdisk $TEMPLATE_VMID /tmp/noble-server-cloudimg-amd64.img $TEMPLATE_BOOT_IMAGE_TARGET_VOLUME)
IMPORTED_DISK=$(echo "$DISK_IMPORT_OUTPUT" | grep -oP "(?<=successfully imported disk ')[^']+")

# finally attach the new disk to the VM as scsi drive
qm set $TEMPLATE_VMID --scsihw virtio-scsi-pci --scsi0 "$IMPORTED_DISK"

# add Cloud-Init CD-ROM drive
qm set $TEMPLATE_VMID --ide2 $CLOUDINIT_IMAGE_TARGET_VOLUME:cloudinit

# set the bootdisk parameter to scsi0
qm set $TEMPLATE_VMID --boot c --bootdisk scsi0

# set serial console
qm set $TEMPLATE_VMID --serial0 socket --vga serial0

# Convert the VM to a template and clean up
qm template $TEMPLATE_VMID

# Cleanup
rm /tmp/noble-server-cloudimg-amd64.img

echo "Deploying VMs..."
for VM in "${VM_LIST[@]}"; do
  echo "${VM}" | while read -r VMID VMNAME CPU MEM VMSRVIP TARGET_IP TARGET_HOST; do
    # Clone the template for each VM
    qm clone "${TEMPLATE_VMID}" "${VMID}" --name "${VMNAME}" --full true --target "${TARGET_HOST}"
    
    # Set compute resources on the target host
    ssh -n "${TARGET_IP}" qm set "${VMID}" --cores "${CPU}" --memory "${MEM}"
    
    # move vm-disk to local
    ssh -n "${TARGET_IP}" qm move-disk "${VMID}" scsi0 "${BOOT_IMAGE_TARGET_VOLUME}" --delete true

    # Resize the VM disk after cloning (due to cloning time)
    ssh -n "${TARGET_IP}" qm resize "${VMID}" scsi0 30G
    
    # Create Cloud-Init user configuration snippet
    mkdir -p /tmp/snippets
    cat > /tmp/snippets/"$VMNAME"-user.yaml << EOF
#cloud-config
hostname: ${VMNAME}
timezone: Asia/Tokyo
manage_etc_hosts: true
chpasswd:
  expire: False
users:
  - default
  - name: cloudinit
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    # mkpasswd --method=SHA-512 --rounds=4096
    # password is zaq12wsx
    passwd: \$6\$rounds=4096\$Xlyxul70asLm\$9tKm.0po4ZE7vgqc.grptZzUU9906z/.vjwcqz/WYVtTwc5i2DWfjVpXb8HBtoVfvSY61rvrs/iwHxREKl3f20
ssh_pwauth: true
ssh_authorized_keys: []
package_upgrade: true
runcmd:
  - su - cloudinit -c "mkdir -p ~/.ssh && chmod 700 ~/.ssh"
  - su - cloudinit -c "curl -sS https://github.com/namakemono-san.keys >> ~/.ssh/authorized_keys"
  - su - cloudinit -c "chmod 600 ~/.ssh/authorized_keys"
  - su - cloudinit -c "for h in 192.168.0.11 192.168.0.12 192.168.0.21 192.168.0.22; do ssh-keyscan -H \$h >> ~/.ssh/known_hosts; done"
  - su - cloudinit -c "curl -s ${REPOSITORY_RAW_SOURCE_URL}/scripts/setup_k8s.sh > ~/setup_k8s.sh"
  - su - cloudinit -c "sudo bash ~/setup_k8s.sh ${VMNAME} ${VMSRVIP}"
  - chsh -s \$(which bash) cloudinit
EOF

    # Create Cloud-Init network configuration snippet
    cat > /tmp/snippets/"$VMNAME"-network.yaml << EOF
version: 1
config:
  - type: physical
    name: ens18
    subnets:
    - type: static
      address: '${VMSRVIP}'
      gateway: '192.168.0.254'
      netmask: '255.255.255.0'
  - type: nameserver
    address:
    - '1.1.1.1'
    - '1.0.0.1'
    search:
    - 'local'
EOF

    # Transfer snippets to target host
    scp /tmp/snippets/"$VMNAME"-user.yaml "${TARGET_IP}:${LOCAL_SNIPPET_DIR}/"
    scp /tmp/snippets/"$VMNAME"-network.yaml "${TARGET_IP}:${LOCAL_SNIPPET_DIR}/"

    # Attach the Cloud-Init snippets to the VM
    ssh -n "${TARGET_IP}" qm set "${VMID}" --cicustom "user=${SNIPPET_TARGET_VOLUME}:snippets/${VMNAME}-user.yaml,network=${SNIPPET_TARGET_VOLUME}:snippets/${VMNAME}-network.yaml"
  done
done

echo "Starting VMs..."
for VM in "${VM_LIST[@]}"; do
  read -r VMID VMNAME CPU MEM VMSRVIP TARGET_IP TARGET_HOST <<< "$VM"
  ssh -n "${TARGET_IP}" qm start "${VMID}"
done

echo "Deployment complete!"
