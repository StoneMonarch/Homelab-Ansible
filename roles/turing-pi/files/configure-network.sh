#!/bin/bash

# Check if script is run as root
if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root" >&2
  exit 1
fi

# Check if required arguments are provided
if [ $# -lt 4 ]; then
  echo "Usage: $0 <main_ip_address> <vlan_ip_address> <gateway> <dns_server>"
  echo "Example: $0 10.10.30.124 10.10.40.124 10.10.30.1 10.10.30.1"
  exit 1
fi

IP_ADDRESS=$1
VLAN_IP=$2
GATEWAY=$3
DNS_SERVER=$4
NETMASK=${5:-"24"}
VLAN_ID=${6:-"40"}
INTERFACE=${7:-"eth0"}
MAX_PING_ATTEMPTS=10

echo "Disabling cloud-init network configuration..."
# Disable cloud-init's network configuration
mkdir -p /etc/cloud/cloud.cfg.d/
cat > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg << EOF
network: {config: disabled}
EOF

echo "Creating Netplan configuration..."
# Create the Netplan configuration file
cat > /etc/netplan/50-cloud-init.yaml << EOF
network:
  version: 2
  ethernets:
    ${INTERFACE}:
      dhcp4: false
      addresses:
        - ${IP_ADDRESS}/${NETMASK}
      routes:
        - to: default
          via: ${GATEWAY}
      nameservers:
        addresses: [${DNS_SERVER}]
  vlans:
    vlan${VLAN_ID}:
      id: ${VLAN_ID}
      link: ${INTERFACE}
      dhcp4: false
      addresses:
        - ${VLAN_IP}/${NETMASK}
EOF

echo "Applying Netplan configuration..."
# Apply the configuration
netplan apply

echo "Waiting for network to settle..."
sleep 5

# Check connectivity by pinging the gateway
echo "Testing network connectivity..."
PING_GATEWAY_SUCCESS=false
PING_VLAN_SUCCESS=false

for i in $(seq 1 $MAX_PING_ATTEMPTS); do
    echo "Ping attempt $i of $MAX_PING_ATTEMPTS to gateway ${GATEWAY}..."
    if ping -c 1 -W 2 $GATEWAY &> /dev/null; then
        PING_GATEWAY_SUCCESS=true
        echo "Successfully pinged gateway ${GATEWAY}"
        break
    fi
    sleep 2
done

# Try to ping VLAN gateway if the main gateway is reachable
if $PING_GATEWAY_SUCCESS; then
    VLAN_GATEWAY=$(echo $VLAN_IP | sed 's/\.[0-9]*$/.1/')
    echo "Testing VLAN connectivity to ${VLAN_GATEWAY}..."

    for i in $(seq 1 $MAX_PING_ATTEMPTS); do
        echo "Ping attempt $i of $MAX_PING_ATTEMPTS to VLAN gateway ${VLAN_GATEWAY}..."
        if ping -c 1 -W 2 $VLAN_GATEWAY &> /dev/null; then
            PING_VLAN_SUCCESS=true
            echo "Successfully pinged VLAN gateway ${VLAN_GATEWAY}"
            break
        fi
        sleep 2
    done
fi

# If pinging failed, revert to DHCP
if ! $PING_GATEWAY_SUCCESS; then
    echo "Could not reach gateway. Reverting to DHCP configuration..."

    # Create a simple DHCP configuration
    cat > /etc/netplan/50-cloud-init.yaml << EOF
network:
  version: 2
  ethernets:
    ${INTERFACE}:
      dhcp4: true
EOF

    echo "Applying fallback DHCP configuration..."
    netplan apply
    echo "Network configuration reverted to DHCP"
else
    if $PING_VLAN_SUCCESS; then
        echo "Network configuration completed successfully with VLAN connectivity"
    else
        echo "WARNING: Main network is working but VLAN connectivity could not be verified"
        echo "Configuration kept as is since main network is functional"
    fi
fi

# Display network status
echo "Current network configuration:"
ip addr show

echo "Routing table:"
ip route