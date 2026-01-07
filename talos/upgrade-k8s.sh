#!/usr/bin/env bash
set -euo pipefail

# Kubernetes Upgrade Script for Talos
# This script upgrades Kubernetes on a Talos cluster

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TALENV="${SCRIPT_DIR}/talenv.yaml"
ENDPOINT="192.168.10.254:6443"

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

    for cmd in talosctl kubectl yq; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        log_error "Missing required tools: ${missing[*]}"
        exit 1
    fi
}

# Get target Kubernetes version from talenv.yaml
get_target_k8s_version() {
    yq eval '.kubernetesVersion' "$TALENV"
}

# Get current cluster Kubernetes version
get_current_k8s_version() {
    kubectl version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion' 2>/dev/null || echo "unknown"
}

# Pre-flight checks
preflight_checks() {
    log_info "Running pre-flight checks..."
    echo ""

    # Check if all nodes are ready
    log_info "Checking node status..."
    if ! kubectl get nodes | grep -v "Ready" | grep -q "NotReady"; then
        log_success "All nodes are Ready"
    else
        log_error "Some nodes are not Ready. Please fix before upgrading."
        kubectl get nodes
        exit 1
    fi
    echo ""

    # Check for pod disruption budgets
    log_info "Checking for PodDisruptionBudgets that might block upgrades..."
    local pdbs
    pdbs=$(kubectl get pdb -A --no-headers 2>/dev/null | wc -l)
    if [ "$pdbs" -gt 0 ]; then
        log_warning "Found ${pdbs} PodDisruptionBudgets - some may affect upgrade process:"
        kubectl get pdb -A
        echo ""
    fi

    # Check cluster health
    log_info "Checking cluster component health..."
    if talosctl health --wait-timeout 2m &>/dev/null; then
        log_success "Cluster is healthy"
    else
        log_warning "Cluster health check had warnings (this may be normal)"
    fi
    echo ""
}

# Perform Kubernetes upgrade
upgrade_kubernetes() {
    local from_version=$1
    local to_version=$2

    log_info "=== Kubernetes Upgrade Plan ==="
    echo ""
    log_info "Current version: ${from_version}"
    log_info "Target version:  ${to_version}"
    echo ""

    log_warning "This will upgrade the Kubernetes control plane and all kubelets"
    log_warning "The upgrade will be performed one control plane node at a time"
    echo ""

    # Confirm before proceeding
    read -p "Proceed with Kubernetes upgrade? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_warning "Upgrade cancelled"
        exit 0
    fi
    echo ""

    log_info "Starting Kubernetes upgrade to ${to_version}..."
    echo ""

    # Use talosctl upgrade-k8s
    # This will upgrade control plane first, then worker nodes
    if talosctl upgrade-k8s --to "${to_version}" --endpoint "${ENDPOINT}"; then
        log_success "Kubernetes upgrade initiated successfully"
        echo ""

        log_info "Waiting for upgrade to complete (this may take several minutes)..."
        sleep 10

        # Monitor the upgrade
        monitor_upgrade "$to_version"
    else
        log_error "Failed to initiate Kubernetes upgrade"
        exit 1
    fi
}

# Monitor upgrade progress
monitor_upgrade() {
    local target_version=$1
    local max_wait=600  # 10 minutes
    local elapsed=0

    log_info "Monitoring upgrade progress..."
    echo ""

    while [ $elapsed -lt $max_wait ]; do
        # Check if all nodes are on the target version
        local nodes_total
        local nodes_upgraded

        nodes_total=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
        nodes_upgraded=$(kubectl get nodes -o jsonpath='{.items[*].status.nodeInfo.kubeletVersion}' 2>/dev/null | tr ' ' '\n' | grep -c "${target_version}" || echo "0")

        log_info "Progress: ${nodes_upgraded}/${nodes_total} nodes upgraded"

        if [ "$nodes_upgraded" -eq "$nodes_total" ] && [ "$nodes_total" -gt 0 ]; then
            log_success "All nodes upgraded to ${target_version}"
            return 0
        fi

        sleep 15
        elapsed=$((elapsed + 15))
    done

    log_warning "Upgrade monitoring timed out after ${max_wait} seconds"
    log_info "Please check the cluster status manually"
}

# Verify upgrade
verify_upgrade() {
    local expected_version=$1

    log_info "=== Verifying Upgrade ==="
    echo ""

    # Check API server version
    log_info "API Server version:"
    kubectl version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion'
    echo ""

    # Check all node versions
    log_info "Node kubelet versions:"
    kubectl get nodes -o custom-columns=NAME:.metadata.name,VERSION:.status.nodeInfo.kubeletVersion,STATUS:.status.conditions[-1].type
    echo ""

    # Check for any pods in bad state
    log_info "Checking for unhealthy pods..."
    local bad_pods
    bad_pods=$(kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded --no-headers 2>/dev/null | wc -l)

    if [ "$bad_pods" -eq 0 ]; then
        log_success "All pods are healthy"
    else
        log_warning "Found ${bad_pods} pods not in Running/Succeeded state:"
        kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
    fi
    echo ""

    # Final health check
    log_info "Running final cluster health check..."
    if talosctl health --wait-timeout 2m; then
        log_success "Cluster is healthy"
    else
        log_warning "Cluster health check reported warnings"
    fi
    echo ""
}

# Main function
main() {
    log_info "Kubernetes Upgrade Script for Talos"
    echo ""

    check_dependencies

    # Get versions
    TARGET_VERSION=$(get_target_k8s_version)
    CURRENT_VERSION=$(get_current_k8s_version)

    if [ "$CURRENT_VERSION" = "unknown" ]; then
        log_error "Could not determine current Kubernetes version"
        log_info "Make sure kubectl is configured and the cluster is accessible"
        exit 1
    fi

    log_info "Current Kubernetes version: ${CURRENT_VERSION}"
    log_info "Target Kubernetes version from talenv.yaml: ${TARGET_VERSION}"
    echo ""

    # Check if already upgraded
    if [[ "$CURRENT_VERSION" == *"$TARGET_VERSION"* ]]; then
        log_success "Cluster is already running ${TARGET_VERSION}"
        exit 0
    fi

    # Run pre-flight checks
    preflight_checks

    # Perform upgrade
    upgrade_kubernetes "$CURRENT_VERSION" "$TARGET_VERSION"

    # Wait a bit for things to settle
    log_info "Waiting for cluster to stabilize..."
    sleep 30
    echo ""

    # Verify upgrade
    verify_upgrade "$TARGET_VERSION"

    log_success "Kubernetes upgrade complete! 🎉"
    log_info "Please monitor your workloads and check for any issues"
}

# Run main function
main "$@"
