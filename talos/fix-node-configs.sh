#!/usr/bin/env bash
set -euo pipefail

# Script to fix misconfigured Talos nodes after botched upgrade
# This script will attempt to apply the correct configuration to each node

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTERCONFIG_DIR="${SCRIPT_DIR}/clusterconfig"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Node configuration mapping: IP -> config file
declare -A NODE_CONFIGS=(
    ["192.168.10.33"]="kubernetes-k8s-cp-1.yaml"
    ["192.168.10.44"]="kubernetes-k8s-cp-2.yaml"
    ["192.168.10.4"]="kubernetes-k8s-cp-3.yaml"
    ["192.168.10.71"]="kubernetes-k8s-pi-1.yaml"
    ["192.168.10.72"]="kubernetes-k8s-pi-2.yaml"
    ["192.168.10.73"]="kubernetes-k8s-pi-3.yaml"
    ["192.168.10.74"]="kubernetes-k8s-pi-4.yaml"
    ["192.168.10.75"]="kubernetes-k8s-pi-5.yaml"
    ["192.168.10.76"]="kubernetes-k8s-pi-6.yaml"
    ["192.168.10.77"]="kubernetes-k8s-pi-7.yaml"
    ["192.168.10.78"]="kubernetes-k8s-pi-8.yaml"
)

# Try to apply config to a node
apply_config_to_node() {
    local ip=$1
    local config_file=$2
    local config_path="${CLUSTERCONFIG_DIR}/${config_file}"

    log_info "Applying ${config_file} to ${ip}..."

    # Try normal mode first
    if talosctl apply-config --nodes "$ip" --file "$config_path" --mode=reboot 2>&1; then
        log_success "Config applied to ${ip} successfully"
        return 0
    fi

    # Try insecure mode
    log_warning "Normal mode failed, trying insecure mode..."
    if talosctl apply-config --nodes "$ip" --file "$config_path" --mode=reboot --insecure 2>&1; then
        log_success "Config applied to ${ip} successfully (insecure mode)"
        return 0
    fi

    log_error "Failed to apply config to ${ip}"
    return 1
}

# Main
log_info "=== Talos Node Configuration Recovery ==="
echo ""

log_warning "This script will attempt to apply the correct configuration to each node"
log_warning "Nodes will be rebooted after configuration is applied"
echo ""

read -p "Continue? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log_info "Aborted"
    exit 0
fi

echo ""

# Try to fix each node
for ip in "${!NODE_CONFIGS[@]}"; do
    config_file="${NODE_CONFIGS[$ip]}"

    echo "=== Processing ${ip} (${config_file}) ==="

    # Check if node is pingable
    if ! ping -c 1 -W 2 "$ip" &>/dev/null; then
        log_error "${ip} is not reachable (ping failed)"
        echo ""
        continue
    fi

    apply_config_to_node "$ip" "$config_file"
    echo ""
done

log_info "Configuration application complete"
log_info "Nodes should be rebooting with correct configurations"
log_info "Wait 2-3 minutes for nodes to come back online"
