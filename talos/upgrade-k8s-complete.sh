#!/usr/bin/env bash
set -euo pipefail

# Complete Kubernetes Upgrade Workflow for Talos
# This script handles:
# 1. Regenerating Talos configs with new k8s version
# 2. Applying updated configs to the cluster
# 3. Upgrading Kubernetes control plane and nodes
# 4. Verifying the upgrade

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TALENV="${SCRIPT_DIR}/talenv.yaml"
ENDPOINT="192.168.10.254:6443"
CLUSTERCONFIG_DIR="${SCRIPT_DIR}/clusterconfig"

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

    for cmd in talosctl kubectl yq talhelper; do
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

# Step 1: Regenerate Talos configurations
regenerate_configs() {
    log_info "=== Step 1: Regenerating Talos Configurations ==="
    echo ""

    cd "$SCRIPT_DIR"

    log_info "Running talhelper genconfig..."
    if talhelper genconfig; then
        log_success "Talos configurations regenerated successfully"
        echo ""

        log_info "Generated configuration files:"
        ls -lh "${CLUSTERCONFIG_DIR}"/*.yaml | awk '{print "  " $9 " (" $5 ")"}'
        echo ""
    else
        log_error "Failed to regenerate Talos configurations"
        exit 1
    fi
}

# Step 2: Apply updated configurations
apply_configs() {
    log_info "=== Step 2: Applying Updated Configurations ==="
    echo ""

    log_warning "This will apply the new Kubernetes version configuration to all nodes"
    log_warning "No upgrade will happen yet - this just updates the configuration"
    echo ""

    read -p "Apply updated configurations? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_warning "Skipping configuration apply"
        return 0
    fi
    echo ""

    cd "$SCRIPT_DIR"

    # Apply configs to control plane nodes first
    log_info "Applying configurations to control plane nodes..."
    for config in "${CLUSTERCONFIG_DIR}"/kubernetes-k8s-cp-*.yaml; do
        if [ -f "$config" ]; then
            local node_name=$(basename "$config" .yaml | sed 's/kubernetes-//')
            log_info "Applying config for ${node_name}..."

            if talosctl apply-config --file "$config" 2>&1 | grep -q "applied"; then
                log_success "Configuration applied to ${node_name}"
            else
                log_warning "Configuration may have already been applied to ${node_name}"
            fi
        fi
    done
    echo ""

    # Apply configs to worker nodes
    log_info "Applying configurations to worker nodes..."
    for config in "${CLUSTERCONFIG_DIR}"/kubernetes-k8s-pi-*.yaml; do
        if [ -f "$config" ]; then
            local node_name=$(basename "$config" .yaml | sed 's/kubernetes-//')
            log_info "Applying config for ${node_name}..."

            if talosctl apply-config --file "$config" 2>&1 | grep -q "applied"; then
                log_success "Configuration applied to ${node_name}"
            else
                log_warning "Configuration may have already been applied to ${node_name}"
            fi
        fi
    done
    echo ""

    log_success "All configurations applied"
    echo ""
}

# Step 3: Upgrade Kubernetes
upgrade_kubernetes() {
    local target_version=$1

    log_info "=== Step 3: Upgrading Kubernetes ==="
    echo ""

    log_info "Target version: ${target_version}"
    log_warning "This will upgrade the Kubernetes control plane and all kubelets"
    log_warning "The upgrade will be performed one control plane node at a time"
    echo ""

    read -p "Proceed with Kubernetes upgrade? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_warning "Upgrade cancelled"
        exit 0
    fi
    echo ""

    log_info "Starting Kubernetes upgrade to ${target_version}..."
    echo ""

    # Use talosctl upgrade-k8s with endpoint
    if talosctl upgrade-k8s --to "${target_version}" --endpoint "${ENDPOINT}"; then
        log_success "Kubernetes upgrade initiated successfully"
        echo ""

        log_info "Waiting for upgrade to complete (this may take several minutes)..."
        sleep 10

        # Monitor the upgrade
        monitor_upgrade "$target_version"
    else
        log_error "Failed to initiate Kubernetes upgrade"
        exit 1
    fi
}

# Monitor upgrade progress
monitor_upgrade() {
    local target_version=$1
    local max_wait=900  # 15 minutes
    local elapsed=0
    local check_interval=15

    log_info "Monitoring upgrade progress..."
    echo ""

    while [ $elapsed -lt $max_wait ]; do
        # Check if all nodes are on the target version
        local nodes_total
        local nodes_upgraded
        local nodes_ready

        nodes_total=$(kubectl get nodes --no-headers 2>/dev/null | wc -l || echo "0")

        if [ "$nodes_total" -eq 0 ]; then
            log_warning "Cannot connect to cluster - waiting..."
            sleep "$check_interval"
            elapsed=$((elapsed + check_interval))
            continue
        fi

        nodes_upgraded=$(kubectl get nodes -o jsonpath='{.items[*].status.nodeInfo.kubeletVersion}' 2>/dev/null | tr ' ' '\n' | grep -c "${target_version}" || echo "0")
        nodes_ready=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " || echo "0")

        local timestamp=$(date +"%H:%M:%S")
        log_info "[${timestamp}] Progress: ${nodes_upgraded}/${nodes_total} nodes on ${target_version}, ${nodes_ready}/${nodes_total} ready"

        if [ "$nodes_upgraded" -eq "$nodes_total" ] && [ "$nodes_ready" -eq "$nodes_total" ] && [ "$nodes_total" -gt 0 ]; then
            echo ""
            log_success "All nodes upgraded to ${target_version} and ready!"
            return 0
        fi

        sleep "$check_interval"
        elapsed=$((elapsed + check_interval))
    done

    log_warning "Upgrade monitoring timed out after ${max_wait} seconds"
    log_info "Please check the cluster status manually"
}

# Step 4: Verify upgrade
verify_upgrade() {
    local expected_version=$1

    log_info "=== Step 4: Verifying Upgrade ==="
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

    # Check control plane pods
    log_info "Control plane component status:"
    kubectl get pods -n kube-system -l tier=control-plane -o wide
    echo ""

    # Final health check
    log_info "Running final cluster health check..."
    if talosctl health --wait-timeout 2m --endpoint "${ENDPOINT}"; then
        log_success "Cluster is healthy"
    else
        log_warning "Cluster health check reported warnings (check output above)"
    fi
    echo ""
}

# Pre-flight checks
preflight_checks() {
    log_info "=== Pre-flight Checks ==="
    echo ""

    # Check if all nodes are ready
    log_info "Checking node status..."
    if kubectl get nodes --no-headers 2>/dev/null | grep -v "Ready"; then
        log_error "Some nodes are not Ready. Please fix before upgrading."
        kubectl get nodes
        exit 1
    fi
    log_success "All nodes are Ready"
    echo ""

    # Check for pod disruption budgets
    log_info "Checking for PodDisruptionBudgets..."
    local pdbs
    pdbs=$(kubectl get pdb -A --no-headers 2>/dev/null | wc -l)
    if [ "$pdbs" -gt 0 ]; then
        log_warning "Found ${pdbs} PodDisruptionBudgets - some may affect upgrade process"
        echo ""
    fi

    # Check cluster health
    log_info "Checking cluster component health..."
    if talosctl health --wait-timeout 2m --endpoint "${ENDPOINT}" &>/dev/null; then
        log_success "Cluster is healthy"
    else
        log_warning "Cluster health check had warnings (this may be normal)"
    fi
    echo ""
}

# Main function
main() {
    log_info "=== Kubernetes Upgrade Workflow for Talos ==="
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
    log_info "Target Kubernetes version:  ${TARGET_VERSION}"
    echo ""

    # Check if already upgraded
    if [[ "$CURRENT_VERSION" == *"$TARGET_VERSION"* ]]; then
        log_success "Cluster is already running ${TARGET_VERSION}"
        exit 0
    fi

    # Show upgrade overview
    log_info "=== Upgrade Overview ==="
    echo ""
    echo "  1. Regenerate Talos configurations with new Kubernetes version"
    echo "  2. Apply updated configurations to all nodes"
    echo "  3. Perform Kubernetes upgrade (control plane first, then workers)"
    echo "  4. Verify upgrade completed successfully"
    echo ""

    read -p "Ready to start the upgrade process? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_warning "Upgrade cancelled"
        exit 0
    fi
    echo ""

    # Run pre-flight checks
    preflight_checks

    # Execute upgrade steps
    regenerate_configs
    apply_configs
    upgrade_kubernetes "$TARGET_VERSION"

    # Wait for things to stabilize
    log_info "Waiting for cluster to stabilize..."
    sleep 30
    echo ""

    # Verify upgrade
    verify_upgrade "$TARGET_VERSION"

    log_success "=== Kubernetes Upgrade Complete! 🎉 ==="
    echo ""
    log_info "Next steps:"
    echo "  1. Monitor your workloads for any issues"
    echo "  2. Check application logs for compatibility problems"
    echo "  3. Run your test suite if applicable"
    echo ""
    log_info "If everything looks good, commit the changes:"
    echo "  git add talos/"
    echo "  git commit -m 'feat: upgrade Kubernetes to ${TARGET_VERSION}'"
    echo ""
}

# Run main function
main "$@"
