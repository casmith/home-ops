#!/usr/bin/env bash
set -euo pipefail

# Talos Node Upgrade Script
# This script automatically upgrades all Talos nodes using the configuration
# from talconfig.yaml and talenv.yaml

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TALCONFIG="${SCRIPT_DIR}/talconfig.yaml"
TALENV="${SCRIPT_DIR}/talenv.yaml"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check required tools
check_dependencies() {
    local missing=()

    for cmd in talosctl yq; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        log_error "Missing required tools: ${missing[*]}"
        log_info "Install yq: brew install yq (or see https://github.com/mikefarah/yq)"
        exit 1
    fi
}

# Get Talos version from talenv.yaml
get_talos_version() {
    yq eval '.talosVersion' "$TALENV"
}

# Get list of nodes with their details from talconfig.yaml
get_nodes() {
    yq eval '.nodes[] | .hostname + "|" + .ipAddress + "|" + .talosImageURL + "|" + (.controlPlane // false | tostring)' "$TALCONFIG"
}

# Extract schematic ID from factory URL
extract_schematic() {
    local url=$1
    echo "$url" | sed -E 's|factory\.talos\.dev/installer/([^:]+).*|\1|'
}

# Upgrade a single node
upgrade_node() {
    local hostname=$1
    local ip=$2
    local schematic=$3
    local version=$4
    local is_control_plane=$5

    local image="factory.talos.dev/installer/${schematic}:${version}"

    log_info "Upgrading ${hostname} (${ip}) to ${version} with schematic ${schematic:0:12}..."

    if [ "$is_control_plane" = "true" ]; then
        log_warning "${hostname} is a control plane node - upgrade will be performed carefully"
    fi

    if talosctl upgrade --nodes "$ip" --image "$image" --wait; then
        log_success "${hostname} upgraded successfully"
        return 0
    else
        log_error "${hostname} upgrade failed"
        return 1
    fi
}

# Verify node version after upgrade
verify_node_version() {
    local hostname=$1
    local ip=$2
    local expected_version=$3

    log_info "Verifying ${hostname} version..."

    local actual_version
    actual_version=$(talosctl version --nodes "$ip" --short 2>&1 | grep "Tag:" | awk '{print $2}' | head -1)

    if [ "$actual_version" = "$expected_version" ]; then
        log_success "${hostname} is running ${actual_version}"
        return 0
    else
        log_error "${hostname} version mismatch: expected ${expected_version}, got ${actual_version}"
        return 1
    fi
}

# Get extensions for a node
show_extensions() {
    local hostname=$1
    local ip=$2

    log_info "Extensions on ${hostname}:"
    talosctl get extensions --nodes "$ip" | grep -v "^NODE" || log_warning "No extensions installed"
}

# Main upgrade function
main() {
    log_info "Starting Talos upgrade process"
    echo ""

    check_dependencies

    # Get target version
    TALOS_VERSION=$(get_talos_version)
    log_info "Target Talos version: ${TALOS_VERSION}"
    echo ""

    # Parse nodes into arrays
    declare -a worker_hostnames worker_ips worker_schematics
    declare -a cp_hostnames cp_ips cp_schematics

    while IFS='|' read -r hostname ip image_url is_cp; do
        schematic=$(extract_schematic "$image_url")

        if [ "$is_cp" = "true" ]; then
            cp_hostnames+=("$hostname")
            cp_ips+=("$ip")
            cp_schematics+=("$schematic")
        else
            worker_hostnames+=("$hostname")
            worker_ips+=("$ip")
            worker_schematics+=("$schematic")
        fi
    done < <(get_nodes)

    log_info "Found ${#worker_hostnames[@]} worker nodes and ${#cp_hostnames[@]} control plane nodes"
    echo ""

    # Show upgrade plan
    log_info "=== Upgrade Plan ==="
    echo ""
    log_info "Workers:"
    for i in "${!worker_hostnames[@]}"; do
        echo "  ${worker_hostnames[$i]} (${worker_ips[$i]}) - schematic: ${worker_schematics[$i]:0:12}..."
    done
    echo ""
    log_info "Control Plane:"
    for i in "${!cp_hostnames[@]}"; do
        echo "  ${cp_hostnames[$i]} (${cp_ips[$i]}) - schematic: ${cp_schematics[$i]:0:12}..."
    done
    echo ""

    # Confirm before proceeding
    read -p "Proceed with upgrade? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_warning "Upgrade cancelled"
        exit 0
    fi
    echo ""

    # Upgrade workers first
    if [ ${#worker_hostnames[@]} -gt 0 ]; then
        log_info "=== Upgrading Worker Nodes ==="
        echo ""

        for i in "${!worker_hostnames[@]}"; do
            upgrade_node "${worker_hostnames[$i]}" "${worker_ips[$i]}" "${worker_schematics[$i]}" "$TALOS_VERSION" "false"
            echo ""
        done

        log_success "All worker nodes upgraded"
        echo ""
    fi

    # Upgrade control plane nodes one at a time
    if [ ${#cp_hostnames[@]} -gt 0 ]; then
        log_info "=== Upgrading Control Plane Nodes ==="
        log_warning "Control plane nodes will be upgraded one at a time"
        echo ""

        for i in "${!cp_hostnames[@]}"; do
            upgrade_node "${cp_hostnames[$i]}" "${cp_ips[$i]}" "${cp_schematics[$i]}" "$TALOS_VERSION" "true"

            # Wait a bit between control plane upgrades
            if [ $i -lt $((${#cp_hostnames[@]} - 1)) ]; then
                log_info "Waiting 30 seconds before next control plane upgrade..."
                sleep 30
            fi
            echo ""
        done

        log_success "All control plane nodes upgraded"
        echo ""
    fi

    # Verify all nodes
    log_info "=== Verifying Upgrades ==="
    echo ""

    all_success=true

    for i in "${!worker_hostnames[@]}"; do
        if ! verify_node_version "${worker_hostnames[$i]}" "${worker_ips[$i]}" "$TALOS_VERSION"; then
            all_success=false
        fi
    done

    for i in "${!cp_hostnames[@]}"; do
        if ! verify_node_version "${cp_hostnames[$i]}" "${cp_ips[$i]}" "$TALOS_VERSION"; then
            all_success=false
        fi
    done

    echo ""

    if $all_success; then
        log_success "All nodes successfully upgraded to ${TALOS_VERSION}"
        echo ""

        # Show extensions summary
        log_info "=== Extension Summary ==="
        echo ""

        for i in "${!worker_hostnames[@]}"; do
            show_extensions "${worker_hostnames[$i]}" "${worker_ips[$i]}"
            echo ""
        done

        for i in "${!cp_hostnames[@]}"; do
            show_extensions "${cp_hostnames[$i]}" "${cp_ips[$i]}"
            echo ""
        done

        log_success "Upgrade complete! 🎉"
    else
        log_error "Some nodes failed to upgrade. Please check the output above."
        exit 1
    fi
}

# Run main function
main "$@"
