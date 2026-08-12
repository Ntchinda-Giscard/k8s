# Observability — one Helm release

`lgtm-stack/` is an umbrella chart: Loki, Tempo, Grafana, kube-state-metrics and
Alloy as dependencies, plus Mimir in monolithic mode as local templates. One
command deploys the lot into one namespace.

```
                     ┌──────────────┐
    pod stdout ─────▶│              │───▶ Loki   (logs)
kubelet/cAdvisor ───▶│    Alloy     │───▶ Mimir  (metrics)
   OTLP 4317/4318 ──▶│  (DaemonSet) │───▶ Tempo  (traces)
                     └──────────────┘           ▲
                                                │
                                     Grafana ───┘ queries all three
```

Alloy replaces Promtail (end-of-life), node-exporter and a standalone Prometheus
server at once. Every backend runs in its single-process form — Loki
`SingleBinary`, Mimir `-target=all`, Tempo single-binary — because the
distributed topologies carry cross-node pod anti-affinity that one node cannot
satisfy.

## Prerequisite: a default StorageClass

Check first. Without one, every PVC sits `Pending` and nothing starts:

```
kubectl get storageclass
```

If the list is empty, install Rancher's local-path provisioner and mark it default:

```
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.31/deploy/local-path-storage.yaml

kubectl patch storageclass local-path -p "{\"metadata\":{\"annotations\":{\"storageclass.kubernetes.io/is-default-class\":\"true\"}}}"
```

Alternatively, set `storageClassName` explicitly in each block of `values.yaml`.

## Install

```
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

cd k8s/observability
helm dependency update ./lgtm-stack

helm upgrade --install lgtm ./lgtm-stack -n lgtm --create-namespace
```

`helm dependency update` downloads the subcharts into `lgtm-stack/charts/` — run
it again whenever `Chart.yaml` changes. If a version range fails to resolve, see
what exists with `helm search repo grafana/loki --versions` and adjust.

Watch it come up:

```
kubectl -n lgtm get pods -w
```

## Verify

Alloy's own UI is the fastest diagnosis — anything red here explains everything
downstream:

```
kubectl -n lgtm port-forward daemonset/alloy 12345:12345
# http://localhost:12345/graph — every component should be green
```

Then confirm each signal lands, in Grafana → Explore:

| Signal | Datasource | Query | Expect |
|---|---|---|---|
| Logs | Loki | `{app="wazalink"}` | Pipeline lines every 60s |
| Metrics | Mimir | `up` | One series per scrape job |
| Metrics | Mimir | `container_memory_working_set_bytes{pod=~"wazalink.*"}` | Usage vs the 512Mi limit |
| Metrics | Mimir | `kubelet_volume_stats_available_bytes` | Free space per PVC |
| Traces | Tempo | search | **Empty — expected**, see below |

## Reaching Grafana

MetalLB is installed on this cluster, so Grafana is a `LoadBalancer` and gets a
routable IP — no port-forward:

```
kubectl -n lgtm get svc grafana
kubectl -n lgtm get secret grafana -o jsonpath="{.data.admin-password}" | base64 -d
```

If the `EXTERNAL-IP` stays `<pending>`, the MetalLB pool in
`config/metallb-config.yaml` is exhausted or doesn't cover this network. Switch
`grafana.service.type` back to `ClusterIP` and port-forward instead.

## Uninstall

```
helm -n lgtm uninstall lgtm
kubectl delete namespace lgtm
```

The namespace delete is what removes the PVCs — `helm uninstall` leaves
StatefulSet volumes behind on purpose.

## Known gaps

**Alerting is not in this chart yet.** `../grafana-alerting-values.yaml` has six
Loki-based rules, but its top-level `alerting:` and `grafana.ini:` keys must be
nested one level under `grafana:` to work as umbrella values. Until that's done,
the rules are not deployed.

**Traces will be empty.** Alloy's OTLP receiver is listening, but nothing sends
to it: the app uses Sentry (`src/main.py:15-23`) and has no OpenTelemetry
dependency. To close it, add `opentelemetry-instrumentation-fastapi` and point
`OTEL_EXPORTER_OTLP_ENDPOINT` at `http://alloy.lgtm.svc.cluster.local:4318`.

**No application metrics.** The `kubernetes-pods` scrape job is annotation-driven
and currently matches nothing. Add `prometheus-fastapi-instrumentator`, then
annotate the pod template with `prometheus.io/scrape: "true"` and
`prometheus.io/port: "7636"`. A counter around `Pipeline.run` is what turns "an
error was logged" into "the pipeline succeeded 0 of its last 10 runs".

**Single node is assumed.** Alloy is a DaemonSet, so the cluster-wide scrape jobs
would duplicate across nodes. See the `⚠️ SINGLE NODE` note in `values.yaml`.

## Superseded files

`loki-values.yaml`, `tempo-values.yaml`, `alloy-values.yaml` and `mimir.yaml` in
this directory are the standalone per-component versions. Everything in them now
lives in `lgtm-stack/values.yaml`. They are kept only for reference and can be
deleted.
