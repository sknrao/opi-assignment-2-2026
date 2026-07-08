#!/usr/bin/env bash
# Bootstrap a local KinD cluster with KubeVirt, Multus and the OVS CNI,
# ready for the VM-on-OVS datapath exercise in this submission.
#
# Written and tested on an Apple-silicon Mac (Docker Desktop, arm64).
# Notes on the environment-specific choices, all discovered the hard way:
#   - No KVM inside Docker Desktop, so KubeVirt runs with useEmulation (TCG).
#   - libvirt refuses cpu mode host-passthrough under TCG on aarch64, while
#     KubeVirt's arm64 webhook refuses anything else, so the Sidecar feature
#     gate is enabled and a hook (shipped in manifests.yaml) rewrites the
#     domain XML to cpu mode "maximum".
#   - The upstream ovs-cni manifest template pins nodeSelector arch=amd64 and
#     leaves the marker's -healthcheck-interval unset (which crashes the
#     marker); the manifest applied here is the corrected render.
#   - Open vSwitch runs inside the KinD node itself; the ovs-cni plugin talks
#     to it over the node's /var/run/openvswitch socket.

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-opi-ovs}"
KUBEVIRT_VERSION="${KUBEVIRT_VERSION:-v1.8.4}"
OVS_CNI_VERSION="${OVS_CNI_VERSION:-v0.39.0}"
OVS_BRIDGE="${OVS_BRIDGE:-br1}"
CIRROS_VERSION="0.6.3"
ARCH="$(uname -m)"   # arm64 on Apple silicon

need() { command -v "$1" >/dev/null || { echo "missing required tool: $1" >&2; exit 1; }; }
need docker; need kind; need kubectl; need curl

echo "==> 1/7 KinD cluster '${CLUSTER_NAME}'"
if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
    echo "    cluster already exists, reusing"
else
    kind create cluster --name "${CLUSTER_NAME}"
fi
NODE="${CLUSTER_NAME}-control-plane"

echo "==> 2/7 Multus CNI (thick plugin)"
kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemonset-thick.yml

echo "==> 3/7 KubeVirt ${KUBEVIRT_VERSION} with emulation and the Sidecar feature gate"
kubectl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml"
kubectl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-cr.yaml"
kubectl -n kubevirt patch kubevirt kubevirt --type merge \
    -p '{"spec":{"configuration":{"developerConfiguration":{"useEmulation":true,"featureGates":["Sidecar"]}}}}'

echo "==> 4/7 Open vSwitch inside the KinD node, bridge ${OVS_BRIDGE}"
docker exec "${NODE}" bash -c "
    command -v ovs-vsctl >/dev/null || {
        apt-get update -qq >/dev/null && apt-get install -y -qq openvswitch-switch >/dev/null
    }
    service openvswitch-switch start >/dev/null 2>&1 || true
    ovs-vsctl --may-exist add-br ${OVS_BRIDGE}
    ovs-vsctl show"

echo "==> 5/7 ovs-cni ${OVS_CNI_VERSION} (corrected manifest)"
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ovs-cni-marker
  namespace: kube-system
---
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: ovs-cni-marker-cr
rules:
- apiGroups: [""]
  resources: ["nodes", "nodes/status"]
  verbs: ["get", "update", "patch"]
---
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: ovs-cni-marker-crb
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ovs-cni-marker-cr
subjects:
- kind: ServiceAccount
  name: ovs-cni-marker
  namespace: kube-system
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: ovs-cni
  namespace: kube-system
  labels:
    tier: node
    app: ovs-cni
spec:
  selector:
    matchLabels:
      app: ovs-cni
  template:
    metadata:
      labels:
        tier: node
        app: ovs-cni
    spec:
      serviceAccountName: ovs-cni-marker
      hostNetwork: true
      nodeSelector:
        kubernetes.io/os: linux
      tolerations:
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
        effect: NoSchedule
      initContainers:
      - name: ovs-cni-plugin
        image: ghcr.io/k8snetworkplumbingwg/ovs-cni-plugin:${OVS_CNI_VERSION}
        command: ["/bin/sh","-c"]
        args:
          - cp /ovs /host/opt/cni/bin/ovs
        imagePullPolicy: IfNotPresent
        securityContext:
          privileged: true
        volumeMounts:
        - name: cnibin
          mountPath: /host/opt/cni/bin
      priorityClassName: system-node-critical
      containers:
      - name: ovs-cni-marker
        image: ghcr.io/k8snetworkplumbingwg/ovs-cni-plugin:${OVS_CNI_VERSION}
        imagePullPolicy: IfNotPresent
        securityContext:
          privileged: true
        command: ["/marker"]
        args:
        - -v
        - "3"
        - -logtostderr
        - -node-name
        - \$(NODE_NAME)
        - -ovs-socket
        - unix:/host/var/run/openvswitch/db.sock
        - -healthcheck-interval=60
        env:
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        volumeMounts:
        - name: ovs-var-run
          mountPath: /host/var/run/openvswitch
        terminationMessagePolicy: FallbackToLogsOnError
      volumes:
        - name: cnibin
          hostPath:
            path: /opt/cni/bin
        - name: ovs-var-run
          hostPath:
            path: /var/run/openvswitch
EOF

echo "==> 6/7 CirrOS ${CIRROS_VERSION} container disk for this architecture"
if [ "${ARCH}" = "arm64" ] || [ "${ARCH}" = "aarch64" ]; then
    CIRROS_ARCH="aarch64"
else
    CIRROS_ARCH="x86_64"
fi
WORKDIR="$(mktemp -d)"
curl -sL "https://download.cirros-cloud.net/${CIRROS_VERSION}/cirros-${CIRROS_VERSION}-${CIRROS_ARCH}-disk.img" \
    -o "${WORKDIR}/cirros.img"
printf 'FROM scratch\nADD cirros.img /disk/cirros.img\n' > "${WORKDIR}/Dockerfile"
docker build -q -t "cirros-${ARCH}-containerdisk:${CIRROS_VERSION}" "${WORKDIR}"
kind load docker-image "cirros-${ARCH}-containerdisk:${CIRROS_VERSION}" --name "${CLUSTER_NAME}"
rm -rf "${WORKDIR}"

echo "==> 7/7 waiting for everything to come up"
kubectl -n kubevirt wait kubevirt kubevirt --for=jsonpath='{.status.phase}'=Deployed --timeout=15m
kubectl -n kube-system rollout status ds/ovs-cni --timeout=10m
kubectl -n kube-system rollout status ds/kube-multus-ds --timeout=10m

echo
echo "Done. The node should now advertise the OVS bridge as a resource:"
kubectl get node "${NODE}" -o jsonpath='{.status.capacity}' | tr ',' '\n' | grep -i ovs || true
echo
echo "Next: kubectl apply -f manifests.yaml"
