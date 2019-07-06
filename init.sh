#!/bin/bash

ME=$(basename "$0")
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

instance_id=$(curl -s 169.254.169.254/latest/meta-data/instance-id)
region=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r .region)

readonly SUPPORTED_OS='bionic'
readonly NET_CONF_FILE_PATH='/etc/netplan/51-eth1.yaml'

logOut() {
  echo "$(date -I'seconds')|${ME}|info| ${1}"
}

failErrOut() {
  echo "$(date -I'seconds')|${ME}|error| ${1}" >&2
  exit 1
}

init_check() {
  [[ "$(lsb_release -c -s)" = "${SUPPORTED_OS}" ]] || failErrOut "'${SUPPORTED_OS}' is not supported"
}

get_local_ip() {
  echo $(hostname -I | awk '{print $1}')
}

init_check
DYNAMIC_IP=$(get_local_ip)
logOut "DYNAMIC_IP: ${DYNAMIC_IP}"

# TODO: implement a loop instead
sleep 10
STATIC_IP=$(aws --region $region ec2 describe-instances \
    --instance-ids $instance_id \
    | jq -r --arg local_ip "${DYNAMIC_IP}" \
    '.Reservations[0].Instances[0].NetworkInterfaces[] | select(.PrivateIpAddress!=$local_ip).PrivateIpAddress')
logOut "STATIC_IP: ${STATIC_IP}"

SUBNET_ID=$(aws --region $region ec2 describe-instances \
    --instance-ids $instance_id \
    | jq -r '.Reservations[0].Instances[0].SubnetId')
logOut "SUBNET_ID: ${SUBNET_ID}"

SUBNET_CIDR_BLOCK=$(aws --region $region ec2 describe-subnets --subnet-ids $SUBNET_ID | jq -r '.Subnets[0].CidrBlock')
logOut "SUBNET_CIDR_BLOCK: ${SUBNET_CIDR_BLOCK}"

SUBNET_WITHOUT_MASK=$(echo $SUBNET_CIDR_BLOCK | awk -F'/' '{print $1}')

if [[ "$(echo $SUBNET_WITHOUT_MASK | awk -F'.' '{print  $4}')" != "0" ]]; then
  failErrOut "'${SUBNET_WITHOUT_MASK}' is wrong"
  exit 1
fi

SUBNET_MASK=$(echo $SUBNET_CIDR_BLOCK | awk -F'/' '{print $2}')
SUBNET_GW=$(echo $SUBNET_WITHOUT_MASK | sed 's/0$/1/')

# TODO check if SUBNET_GW is reachable
#ping -c 1 $SUBNET_GW ; echo $?

cat <<EOF > $NET_CONF_FILE_PATH
network:
  version: 2
  renderer: networkd
  ethernets:
    eth1:
      addresses:
       - ${STATIC_IP}/${SUBNET_MASK}
      dhcp4: no
      routes:
       - to: 0.0.0.0/0
         via: ${SUBNET_GW} # Default gateway
         table: 1000
       - to: ${STATIC_IP}
         via: 0.0.0.0
         scope: link
         table: 1000
      routing-policy:
        - from: ${STATIC_IP}
          table: 1000
EOF

logOut "'${NET_CONF_FILE_PATH}' file generated"
logOut "Running 'netplan --debug apply'"
netplan --debug apply

MOUNT_DIR='/data'

make_mount () {
  /bin/mkdir -p $MOUNT_DIR
}

mount_volume() { /bin/mount /dev/xvdz $MOUNT_DIR; }

check_for_filesystem() {
    eval "$(blkid -o udev /dev/xvdz)"
    if [[ ${ID_FS_TYPE} == "ext4" ]]; then
        logOut "Mounting volume as FS already exists and is ext4"
        make_mount
        mount_volume
    else
        logOut "Need to format volume and then mount it"
        make_mount
        mkfs.ext4 /dev/xvdz
        mount_volume
    fi
    logOut "'${MOUNT_DIR} mounted'"
}

confirm_attachment() {
    logOut "Confirming attachment"
    count=0
    while [[ $count -lt 10 ]]; do
        test -b /dev/xvdz && break
        ((count++))
        if [[ $count -eq 10 ]];then
            logOut "Unable to confirm device /dev/xvdz is available, issue with attaching?"
            exit 200
        fi
        sleep 2
    done
}

confirm_attachment
check_for_filesystem

echo "TEST: ${STATIC_IP}" >> /data/test
