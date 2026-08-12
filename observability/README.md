# Observability — LGTM with Alloy as the single collector

Alloy runs as a DaemonSet in `monitoring` and is the **only** thing that writes
to the backends. The backends all live in `lgtm`.

```
                    ┌──────────────┐
   pod stdout ─────▶│              │───▶ Loki   (logs)
   kubelet/cAdvisor▶│    Alloy     │───▶ Mimir  (metrics)
   OTLP :4317/4318▶│  (DaemonSet)  │───▶ Tempo  (traces)
                    └──────────────┘           ▲
                                               │
                                    Grafana ───┘ queries all three
```

One collector instead of Promtail + node-exporter + a Prometheus server. Every
backend runs in its single-node form — Loki `SingleBinary`, Mimir `-target=all`,
Tempo single-binary — because the distributed charts carry cross-node pod
anti-affinity that cannot be satisfied here.

## Install order

Backends first: Alloy crash-loops on a missing remote_write endpoint.

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# 1. Logs
helm upgrade --install loki grafana/loki \
  -n lgtm --create-namespace -f loki-values.yaml

# 2. Metrics
kubectl apply -f mimir.yaml

# 3. Traces — SKIP if `kubectl -n lgtm get svc tempo` already returns something
helm upgrade --install tempo grafana/tempo -n lgtm -f tempo-values.yaml

# 4. Object-state metrics (pod restarts, deployment status)
helm upgrade --install kube-state-metrics \
  prometheus-community/kube-state-metrics -n monitoring --create-namespace

# 5. The collector
helm upgrade --install alloy grafana/alloy \
  -n monitoring --create-namespace -f alloy-values.yaml

# 6. Grafana, with datasources and alert rules
helm upgrade --install grafana grafana/grafana -n lgtm \
  -f ../grafana-values.yaml -f ../grafana-alerting-values.yaml
```

Wait for Mimir before Alloy:

```bash
kubectl -n lgtm rollout status statefulset/mimir --timeout=300s
```

## Verify

Alloy's own UI is the fastest way to see whether components are healthy —
anything red here explains everything downstream:

```bash
kubectl -n monitoring port-forward daemonset/alloy 12345:12345
# http://localhost:12345/graph — every component should be green
```

Then confirm each signal is landing, in Grafana → Explore:

| Signal | Datasource | Query | Expect |
|---|---|---|---|
| Logs | Loki | `{app="wazalink"}` | Pipeline lines every 60s |
| Metrics | Mimir | `up` | One series per scrape job |
| Metrics | Mimir | `container_memory_working_set_bytes{pod=~"wazalink.*"}` | Usage vs the 512Mi limit |
| Metrics | Mimir | `kubelet_volume_stats_available_bytes` | Free space per PVC |
| Traces | Tempo | search | **Empty — expected**, see below |

## Viewing Grafana

Grafana is ClusterIP, so from the server:

```bash
kubectl -n lgtm port-forward svc/grafana 3000:80
kubectl -n lgtm get secret grafana -o jsonpath="{.data.admin-password}" | base64 -d
```

Reaching it from a workstation needs `--address 0.0.0.0` plus a firewall rule,
or an Ingress.

## Known gaps

**Traces will be empty.** Alloy's OTLP receiver is listening, but nothing sends
to it: the app uses Sentry (`src/main.py:15-23`) and has no OpenTelemetry
dependency. To close it, add `opentelemetry-instrumentation-fastapi` and point
`OTEL_EXPORTER_OTLP_ENDPOINT` at
`http://alloy.monitoring.svc.cluster.local:4318`. No cluster change needed.

**No application metrics.** The `kubernetes-pods` scrape job is annotation-
driven and currently matches nothing. Add
`prometheus-fastapi-instrumentator`, then annotate the pod template with
`prometheus.io/scrape: "true"` and `prometheus.io/port: "7636"`. A counter
around `Pipeline.run` is what turns "an error was logged" into "the pipeline
succeeded 0 of its last 10 runs" — a far better alert than any log grep.

**Alerting is log-based only.** The six rules in `../grafana-alerting-values.yaml`
predate Mimir and all query Loki. Once metrics flow, the pod-restart and
memory-pressure rules that logs cannot express are worth adding.

**Single node is assumed.** Alloy is a DaemonSet, so cluster-wide scrape jobs
(kube-state-metrics, kubelet, the annotation job) would duplicate across nodes.
The jobs are marked `⚠️ MULTI-NODE` in `alloy-values.yaml`; splitting them into
a second Alloy running as a Deployment is the fix if a node is ever added.
