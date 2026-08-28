#!/usr/bin/env bash
set -Eeuo pipefail

# Render Talos machine configuration.
#
# This replaces talhelper, which was abandoned upstream and whose hand-written
# schema had fallen behind Talos releases. Nothing here carries a schema of its
# own -- talosctl generates and validates the config, so a new Talos release
# cannot strand us the same way.
#
# The contract, end to end:
#
#   talsecret.sops.yaml ──sops──┐
#                               ├── talosctl gen config ──┐
#   talenv.yaml ────────────────┘                         │
#                                                         ├── machineconfig patch ──> stdout
#   patches/{cluster,global,controller,storage}/ ─────────┤
#   nodes/<role>/<node>.yaml ─────────────────────────────┘
#
# Invoke it with `bash render.sh ...`, as the Taskfiles and workflows do -- the
# repo's scripts are run through an explicit interpreter rather than relying on
# the executable bit.
#
# Usage:
#   render.sh config <hostname>    machine config for one node, on stdout
#   render.sh image <hostname>     the factory installer image for one node
#   render.sh talosconfig          client config with all control plane endpoints
#   render.sh nodes [role]         hostnames, optionally limited to a role
#   render.sh ip <hostname>        the node's address

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# The cluster name and endpoint used to live at the top of talconfig.yaml. They
# are positional arguments to `talosctl gen config`, so they live here now.
readonly CLUSTER_NAME="kubernetes"
readonly CLUSTER_ENDPOINT="https://192.168.10.254:6443"
readonly FACTORY_URL="https://factory.talos.dev"

# Appended to the API server certificate, on top of the SANs gen config derives
# from the endpoint. This is a flag rather than a patch because a strategic
# merge replaces that derived list instead of adding to it. The machine half of
# the same list lives in patches/cluster.yaml.
readonly ADDITIONAL_SANS="127.0.0.1,192.168.10.254"

# Nodes that hold Longhorn replicas and therefore need the rshared bind mounts
# in patches/storage/machine-longhorn-mounts.yaml -- read that file for why.
# The 4GB Pis (pi-1..4) are deliberately absent: they run longhorn-manager and
# an instance-manager, but replicas are kept off them via allowScheduling on
# the nodes.longhorn.io objects, so nothing there needs the mounts.
readonly LONGHORN_REPLICA_NODES=(
    k8s-cp-1 k8s-cp-2 k8s-cp-3
    k8s-pi-5 k8s-pi-6 k8s-pi-7 k8s-pi-8
)

# Everything decrypted or generated lands here and is removed on exit. Secrets
# reach the filesystem because `gen config --with-secrets` and `machineconfig
# patch --patch @file` both want paths, not stdin. mktemp -d is already 0700;
# the umask on each write keeps the files inside it 0600 too.
TMP_DIR="$(mktemp -d)"
readonly TMP_DIR

# Guarded on the PID so a die() inside a command substitution cannot tear the
# directory down while the parent is still rendering. Bash does not run EXIT
# traps in subshells, but the guard makes that independent of bash version.
cleanup() {
    [[ "${BASHPID}" == "$$" ]] && rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

die() {
    echo "render.sh: $*" >&2
    exit 1
}

# --- node lookup -------------------------------------------------------------
#
# A node's directory is its role: nodes/controlplane/ or nodes/workers/. That is
# the only place the role is written down -- `talosctl gen config -t` takes it
# from here, so there is no controlPlane flag to keep in sync.

# Schematic files live alongside the node files; they describe an image, not a
# node, so every listing has to skip them.
is_node_file() {
    local file="$1" name
    name="$(basename "${file}")"
    [[ -f "${file}" && "${name}" != *.schematic.yaml && "${name}" != "schematic.yaml" ]]
}

node_file() {
    local hostname="$1" file
    for file in "${SCRIPT_DIR}"/nodes/*/"${hostname}".yaml; do
        if is_node_file "${file}"; then
            echo "${file}"
            return
        fi
    done
    die "no node file for '${hostname}' under ${SCRIPT_DIR}/nodes"
}

# These assign node_file's result before using it. die() inside a command
# substitution only exits that subshell, so an inlined "$(node_file ...)" would
# leave the caller running on with an empty path and a confusing later error.
node_role() {
    local file
    file="$(node_file "$1")"
    basename "$(dirname "${file}")"
}

node_ip() {
    local file
    file="$(node_file "$1")"
    yq eval -r -e '.machine.network.interfaces[0].addresses[0] | split("/") | .[0]' "${file}"
}

list_nodes() {
    local role="${1:-}" file
    # An empty role means every role. Both branches glob deliberately.
    if [[ -n "${role}" ]]; then
        set -- "${SCRIPT_DIR}/nodes/${role}"/*.yaml
    else
        set -- "${SCRIPT_DIR}"/nodes/*/*.yaml
    fi

    # An `if` rather than `is_node_file ... && basename ...`: the last entry in
    # nodes/workers/ sorts as schematic.yaml, so the && form would leave the
    # loop -- and the whole script -- with a non-zero status despite having
    # printed every node correctly.
    for file in "$@"; do
        if is_node_file "${file}"; then
            basename "${file}" .yaml
        fi
    done
}

# `gen config` names the worker type in the singular; the directory is plural
# so it reads as a collection of nodes.
output_type() {
    local role
    role="$(node_role "$1")"
    case "${role}" in
        controlplane) echo controlplane ;;
        workers) echo worker ;;
        *) die "'$1' is in role directory '${role}'; expected controlplane or workers" ;;
    esac
}

# --- image factory -----------------------------------------------------------
#
# Schematics are declared as YAML and resolved to an ID by the Image Factory,
# which hashes the content -- the same file always yields the same ID. This
# replaces three opaque hashes that used to be pasted into talconfig.yaml with
# a hand-maintained table in UPGRADE.md explaining what each one contained.
#
# Lookup order, most specific first:
#   nodes/<role>/<hostname>.schematic.yaml   one node diverges from its role
#   nodes/<role>/schematic.yaml              a whole role diverges (the Pis)
#   schematic.yaml                           the fleet default

schematic_file() {
    local hostname="$1" role candidate
    role="$(node_role "${hostname}")"

    for candidate in \
        "${SCRIPT_DIR}/nodes/${role}/${hostname}.schematic.yaml" \
        "${SCRIPT_DIR}/nodes/${role}/schematic.yaml" \
        "${SCRIPT_DIR}/schematic.yaml"; do
        if [[ -f "${candidate}" ]]; then
            echo "${candidate}"
            return
        fi
    done

    die "no schematic for '${hostname}' and no ${SCRIPT_DIR}/schematic.yaml"
}

schematic_id() {
    local hostname="$1" file response id
    file="$(schematic_file "${hostname}")"

    # Retry hard: this runs from runners that are pods in the cluster being
    # upgraded, so DNS can blip underneath it while a node reboots.
    response="$(curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors \
        -X POST --data-binary "@${file}" "${FACTORY_URL}/schematics")" \
        || die "could not resolve the schematic in ${file} against ${FACTORY_URL}"

    id="$(jq -r -e '.id' <<<"${response}")" \
        || die "unexpected response from ${FACTORY_URL}: ${response}"

    # The ID is a SHA256 of the canonicalised schematic. Checking the shape
    # here means a surprising response cannot reach machine.install.image.
    [[ "${id}" =~ ^[0-9a-f]{64}$ ]] \
        || die "schematic ID '${id}' from ${FACTORY_URL} is not a sha256"

    echo "${id}"
}

machine_image() {
    local id version

    # Assigned, not inlined: die() inside a command substitution exits only that
    # subshell, so the inline form would happily emit "installer/:v1.13.9" and
    # return success after a failed factory lookup.
    id="$(schematic_id "$1")"
    version="$(talos_version)"

    echo "factory.talos.dev/installer/${id}:${version}"
}

# --- versions ----------------------------------------------------------------
#
# talenv.yaml stays the single source of truth, carrying the Renovate
# annotations that open the version-bump PRs.

talos_version() {
    yq eval -r -e '.talosVersion' "${SCRIPT_DIR}/talenv.yaml"
}

kubernetes_version() {
    # talosctl wants a bare semver here; talenv.yaml carries the leading v so
    # Renovate's docker datasource matches the ghcr.io/siderolabs/kubelet tags.
    local version
    version="$(yq eval -r -e '.kubernetesVersion' "${SCRIPT_DIR}/talenv.yaml")"
    echo "${version#v}"
}

# --- rendering ---------------------------------------------------------------

secrets_file() {
    local file="${TMP_DIR}/talsecret.yaml"

    if [[ ! -f "${file}" ]]; then
        (umask 077 && sops --decrypt "${SCRIPT_DIR}/talsecret.sops.yaml" >"${file}")
    fi

    echo "${file}"
}

# Patches are plain strategic-merge YAML. Encrypted ones are decrypted to the
# temp dir first -- talhelper used to do that implicitly, which is why sops is
# now a required tool wherever this script runs.
resolve_patch() {
    local patch="$1" decrypted

    if [[ "${patch}" == *.sops.yaml ]]; then
        decrypted="${TMP_DIR}/patch-$(basename "${patch}" .sops.yaml).yaml"
        (umask 077 && sops --decrypt "${patch}" >"${decrypted}")
        echo "${decrypted}"
    else
        echo "${patch}"
    fi
}

# Later patches win. Cluster-wide first, then the role, then the node.
patch_list() {
    local hostname="$1" patch role

    echo "${SCRIPT_DIR}/patches/cluster.yaml"

    for patch in "${SCRIPT_DIR}"/patches/global/*.yaml; do
        echo "${patch}"
    done

    role="$(node_role "${hostname}")"
    if [[ "${role}" == "controlplane" ]]; then
        for patch in "${SCRIPT_DIR}"/patches/controller/*.yaml; do
            echo "${patch}"
        done
    fi

    for patch in "${LONGHORN_REPLICA_NODES[@]}"; do
        if [[ "${patch}" == "${hostname}" ]]; then
            echo "${SCRIPT_DIR}/patches/storage/machine-longhorn-mounts.yaml"
            break
        fi
    done

    node_file "${hostname}"
}

render_config() {
    local hostname="$1" base args=() patch
    local secrets type image talos k8s

    base="${TMP_DIR}/${hostname}-base.yaml"

    # Resolved into variables first so a failure here fails this function with
    # the die() message already on stderr. Inline command substitution would
    # instead hand talosctl an empty flag value and fail further downstream.
    secrets="$(secrets_file)"
    type="$(output_type "${hostname}")"
    image="$(machine_image "${hostname}")"
    talos="$(talos_version)"
    k8s="$(kubernetes_version)"

    # gen config emits the whole config from the secrets bundle: PKI, tokens,
    # the kubelet and static pod images for the target Kubernetes version, and
    # the machine type. --with-docs/--with-examples off keeps the apply-config
    # dry-run diffs readable.
    (umask 077 && talosctl gen config "${CLUSTER_NAME}" "${CLUSTER_ENDPOINT}" \
        --with-secrets "${secrets}" \
        --talos-version "${talos}" \
        --kubernetes-version "${k8s}" \
        --install-image "${image}" \
        --additional-sans "${ADDITIONAL_SANS}" \
        --with-docs=false \
        --with-examples=false \
        --output-types "${type}" \
        --output - >"${base}")

    while read -r patch; do
        args+=(--patch "@$(resolve_patch "${patch}")")
    done < <(patch_list "${hostname}")

    # machineconfig patch writes the result to stdout when no --output is given.
    talosctl machineconfig patch "${base}" "${args[@]}"
}

render_talosconfig() {
    local file="${TMP_DIR}/talosconfig" hostname endpoints=()
    local secrets talos

    secrets="$(secrets_file)"
    talos="$(talos_version)"

    (umask 077 && talosctl gen config "${CLUSTER_NAME}" "${CLUSTER_ENDPOINT}" \
        --with-secrets "${secrets}" \
        --talos-version "${talos}" \
        --output-types talosconfig \
        --output - >"${file}")

    # gen config leaves the endpoint list empty. Point the client at every
    # control plane member, as talhelper did.
    while read -r hostname; do
        endpoints+=("$(node_ip "${hostname}")")
    done < <(list_nodes controlplane)

    talosctl --talosconfig "${file}" config endpoint "${endpoints[@]}"
    cat "${file}"
}

main() {
    local command="${1:-}"
    shift || true

    case "${command}" in
        config)
            [[ $# -eq 1 ]] || die "usage: render.sh config <hostname>"
            render_config "$1"
            ;;
        image)
            [[ $# -eq 1 ]] || die "usage: render.sh image <hostname>"
            machine_image "$1"
            ;;
        talosconfig)
            render_talosconfig
            ;;
        nodes)
            list_nodes "${1:-}"
            ;;
        ip)
            [[ $# -eq 1 ]] || die "usage: render.sh ip <hostname>"
            node_ip "$1"
            ;;
        *)
            die "usage: render.sh {config|image|talosconfig|nodes|ip} [args]"
            ;;
    esac
}

main "$@"
