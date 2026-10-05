# kube-network-policies Helm chart

This chart installs the [kube-network-policies](https://github.com/kubernetes-sigs/kube-network-policies) agent as its own DaemonSet. It enforces Kubernetes NetworkPolicies without depending on the CNI.

It's built for private-node tenant clusters that use vCluster's built-in Flannel (`deploy.cni.flannel.enabled: true`). The built-in Flannel has no switch for NetworkPolicies, so this chart adds enforcement next to it. vCluster keeps managing Flannel: the pod CIDR, the `tailscale0` interface for node-to-node VPN, and the image registry rewrite.

## Why not the upstream chart

Upstream has a chart at `charts/kube-network-policies`, but it doesn't work well for this use:

- **It isn't published.** There's no Helm repo index, and the `registry.k8s.io/networking/charts` OCI path has no tags. The upstream README installs it from a local checkout.
- **It's at version 0.0.1.**
- **Its default AdminNetworkPolicy mode can't start.** `adminNetworkPolicy` defaults to `true` and adds `--admin-network-policy` and `--baseline-admin-network-policy` to the agent. Neither flag exists in v1.1.2: the shared flag set in `pkg/cmd/cmd.go` doesn't define them, and Go flag parsing exits on an unknown flag. Its ClusterRole also reads a different key (`baselineAdminNetworkPolicy`) that isn't in `values.yaml`.
- **Its docs are behind the agent.** The quick start says to apply the v0.1.5 AdminNetworkPolicy and BaselineAdminNetworkPolicy CRDs. Since v1.0.0, upstream builds that API (v1alpha1) as a separate `npa-v1alpha1` image, and no tag of it is published on `registry.k8s.io`. The published policy image is `-npa-v1alpha2`, which enforces the newer ClusterNetworkPolicy API instead.

This chart keeps the upstream container settings (v1.1.2, `/lib/modules` mounted, no NRI). It also makes the following changes:

- **`clusterNetworkPolicy.enabled` replaces the broken AdminNetworkPolicy option.** One flag switches to the `-npa-v1alpha2` image, adds the RBAC rules, and installs the CRD. It defaults to `false`.
- **The ClusterNetworkPolicy CRD ships with the chart.** It's the `network-policy-api` v0.2.0 standard-channel CRD, with `helm.sh/resource-policy: keep` set by default. Its schema matches the version agent v1.1.2 is built against, apart from the bundle-version annotation.
- `image.registry` is a separate value, so you can point it at a mirror or an air-gapped registry.
- The DaemonSet uses `priorityClassName: system-node-critical`, so the agent isn't evicted before the workloads it protects.
- The DaemonSet tolerates every taint, so it starts on nodes that are still `NotReady` while Flannel comes up.
- `logLevel`, `nfqueueId` and `extraArgs` are configurable.

## Values

| Key | Default | Notes |
| --- | --- | --- |
| `image.registry` | `registry.k8s.io` | Prepended to `image.repository`. |
| `image.repository` | `networking/kube-network-policies` | |
| `image.tag` | `""` (uses the chart's `appVersion`, `v1.1.2`) | |
| `imagePullSecrets` | `[]` | |
| `logLevel` | `2` | Passed to the agent as `--v`. |
| `nfqueueId` | `98` | Change it only if another component on the node uses queue 98. |
| `clusterNetworkPolicy.enabled` | `false` | Turns on ClusterNetworkPolicy (`policy.networking.k8s.io/v1alpha2`) enforcement. Appends `-npa-v1alpha2` to the image tag and adds RBAC for `nodes` and `clusternetworkpolicies`. |
| `crds.install` | `true` | Installs the ClusterNetworkPolicy CRD with the release. Only used when `clusterNetworkPolicy.enabled` is `true`. Set it to `false` if something else manages the CRD. |
| `crds.keep` | `true` | Adds `helm.sh/resource-policy: keep` to the CRD. |
| `extraArgs` | `[]` | Appended to the agent arguments. |
| `rbac.create` | `true` | |
| `daemonset.priorityClassName` | `system-node-critical` | |
| `daemonset.tolerations` | `[{operator: Exists}]` | |
| `daemonset.resources` | requests `100m` CPU, `50Mi` memory | |

## Using it from a vCluster Platform template

The chart is deployed through `experimental.deploy.vcluster.helm`. A boolean template parameter turns it on or off. Platform renders `boolean` parameters as real booleans, so a plain `if` works.

### Option A: publish to an OCI registry (recommended)

Publishing a GitHub release runs [.github/workflows/publish-chart.yaml](.github/workflows/publish-chart.yaml):

1. It lints the chart and renders it in three modes: the defaults, `clusterNetworkPolicy.enabled=true` with a registry override, and `clusterNetworkPolicy.enabled=true` with `crds.install=false`.
2. It packages the chart, using the release tag without the `v` as the chart version. Tag `v0.2.0` produces chart `0.2.0`.
3. It pushes the package to `oci://ghcr.io/<repo owner>/charts/kube-network-policies`.

`appVersion` isn't overridden. It stays at the upstream agent version because it's the default image tag.

GHCR creates new packages as private. Make the package public, or set `username` and `password` under `chart` in the template.

To publish by hand instead:

```sh
helm package kube-network-policies
helm push kube-network-policies-0.2.0.tgz oci://ghcr.io/<org>/charts
```

```yaml
# VirtualClusterTemplate spec
parameters:
  - variable: networkPolicies
    label: Enforce NetworkPolicies
    type: boolean
    defaultValue: "false"
template:
  helmRelease:
    values: |-
      privateNodes:
        enabled: true
      {{- if .Values.networkPolicies }}
      experimental:
        deploy:
          vcluster:
            helm:
              - chart:
                  name: kube-network-policies
                  repo: oci://ghcr.io/<org>/charts
                  version: 0.2.0
                release:
                  name: kube-network-policies
                  namespace: kube-system
                # Add to enforce ClusterNetworkPolicies too:
                # values: |-
                #   clusterNetworkPolicy:
                #     enabled: true
      {{- end }}
```

For a private registry, add `username` and `password` under `chart`.

### Option B: inline bundle (no registry pull)

`bundle` takes the packaged chart as base64. The packaged chart is about 9.6 KB (most of it the ClusterNetworkPolicy CRD), which is about 12.8 KB as base64. The tenant cluster reads the chart from its config, so nothing is pulled over the network. That's useful for air-gapped installs, but the base64 string has to be regenerated and pasted into the template on every chart change.

```sh
helm package kube-network-policies
base64 -i kube-network-policies-0.2.0.tgz | tr -d '\n'
```

```yaml
helm:
  - chart:
      name: kube-network-policies
      version: 0.2.0
    bundle: <base64 output>
    release:
      name: kube-network-policies
      namespace: kube-system
```

## Startup timing

- **Helm charts install after raw manifests.** The tenant cluster applies `experimental.deploy.vcluster.manifests` while its controllers start. Helm charts install afterwards in a background loop, which retries every 10 seconds if an install fails.
- **Option A also waits on the registry pull.**
- **Raw manifests are a little faster, at the cost of a bulkier template.** If you need the fastest startup, use the raw-manifest version of this chart (`helm template` output).
- **When it matters:** usually only when nodes join quickly. On Metal3 bare metal, node provisioning takes several minutes and hides the difference.

## ClusterNetworkPolicy CRD lifecycle

The CRD lives in `templates/`, not in Helm's `crds/` folder, so it can be turned on or off with `clusterNetworkPolicy.enabled`. Helm installs and upgrades templated CRDs like any other object. A CRD in `crds/` is installed once and never upgraded.

By default, `crds.keep` adds `helm.sh/resource-policy: keep`, and Helm then never deletes the CRD:

- **Uninstall:** uninstalling the release, or switching the template parameter off, leaves the CRD in place.
- **Turning ClusterNetworkPolicy off:** setting `clusterNetworkPolicy.enabled` to `false` also leaves the CRD in place.
- **Why that's the default:** deleting a CRD deletes every ClusterNetworkPolicy object in the cluster.
- **Cleanup is manual:** with the default, remove the CRD with `kubectl delete crd clusternetworkpolicies.policy.networking.k8s.io` when you no longer need it.
- **Taking over an existing CRD:** if another tool already installed the CRD, Helm refuses to adopt it. Set `crds.install: false`, or add the Helm ownership labels and annotations to the existing CRD.

## Turning it off

If the parameter is set back to `false`, the chart drops out of `experimental.deploy.vcluster.helm`. The tenant cluster records every release it installs in a status ConfigMap. On the next deploy run, it uninstalls any recorded release that's no longer in the config, so the DaemonSet and RBAC are removed. This comes from reading the deployer code (`pkg/controllers/deploy/deploy.go`) and hasn't been tested on a cluster yet.

## Known gaps

- **Brief window with no enforcement on new nodes.** A pod can start on a freshly joined node before the agent runs there, and its traffic isn't filtered until the agent is up. Flannel's own netpol sidecar has the same gap.
- **Existing tenant clusters need a template sync.** A newly added template parameter renders empty on existing tenant clusters until each gets a per-tenant template sync. `defaultValue: "false"` keeps that harmless.
- **`controlPlane.advanced.defaultImageRegistry` doesn't rewrite this chart's image.** Set `image.registry` instead. With `clusterNetworkPolicy.enabled`, mirror the `-npa-v1alpha2` tag too.
- **The agent may log CRD errors briefly on first install.** The CRD and the DaemonSet are created in the same release, so the agent can start before the API server serves `clusternetworkpolicies`. It should settle once the CRD is established, but that hasn't been tested on a cluster.
- **No AdminNetworkPolicy support.** See "Why not the upstream chart".

## Verify in a lab

1. Create a private-node tenant cluster with `networkPolicies: true`.
2. Check that the agent runs on every node: `kubectl -n kube-system get ds kube-network-policies`.
3. Apply a default-deny policy in a test namespace and confirm that pod-to-pod traffic is blocked:

   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: default-deny
   spec:
     podSelector: {}
     policyTypes: [Ingress]
   ```

4. With `clusterNetworkPolicy.enabled: true`:
   - Confirm `kubectl get crd clusternetworkpolicies.policy.networking.k8s.io` shows the CRD.
   - Confirm the DaemonSet image ends in `-npa-v1alpha2`.
   - Apply a ClusterNetworkPolicy that denies a namespace, and confirm it overrides a namespace NetworkPolicy that allows the same traffic.
5. Set the parameter to `false`, sync the tenant cluster, and confirm the release and DaemonSet are removed and the CRD stays.

Local checks done so far:

- `helm lint` passes.
- `helm template` renders correctly in five modes: the defaults, ClusterNetworkPolicy on, ClusterNetworkPolicy on without the CRD, ClusterNetworkPolicy on without `keep`, and an explicit `-npa-v1alpha2` tag.
- The rendered CRD spec matches the upstream file exactly.

The chart hasn't been installed on a cluster yet.
