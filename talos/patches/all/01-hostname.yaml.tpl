# Use the host name from topf.yaml rather than a generated talos-xxx-xxx one.
apiVersion: v1alpha1
kind: HostnameConfig
auto: "off"
hostname: {{ .Node.Host }}
