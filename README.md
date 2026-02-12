# 📊 Cluster Tamer

Cluster-Tamer is a monitoring and observability stack for Kubernetes, bundling open-source tools into an integrated umbrella Helm chart for metrics, logs, traces, and costs within a single source of truth (Grafana). Key components include Kube-Prometheus-Stack for core monitoring, Grafana Loki for log aggregation, Grafana Tempo for distributed tracing, OpenCost for cost analysis, and Alertsnitch for alert history. Features include an Alert-History Dashboard correlating alerts with Flux deployment events, GitOps correlation showing reconciliations in alert timelines, trace-to-metrics for service graphs, SSL monitoring, and cost-aware alerting. Installation requires Kubernetes, Helm 3.x, and optionally Flux CD.

## 🏗 Architecture & Components

The stack is designed as a **Collector-Backend Architecture**. Telemetry data is gathered by **Grafana Alloy** and pushed to specialized backends using S3 for long-term storage.

| Component | Function | Backend Storage |
| :--- | :--- | :--- |
| **K8s Monitoring** | Alloy Central Collector (Logs/OTLP/Faro) & Opencost | Stateless |
| **Kube Prometheus Stack** | Grafana & Prometheus Metrics | PV / S3 Bucket (14-day retention) |
| **Loki** | Log Aggregation & Search | PV / S3 Bucket (14-day retention) |
| **Tempo** | Distributed Tracing | PV / S3 Bucket (14-day retention) |
| **Pyroscope** | Continuous Profiling | PV / S3 Bucket (14-day retention) |
| **Blackbox Exporter** | Prometheus HTTP Prober | PV / S3 Bucket (14-day retention) |
| **Alertsnitch** | Archive Alerts to Loki, with Grafana Dashboard | PV / S3 Bucket (14-day retention) |

## 🚀 Deployment Guide

Deployment is managed via FluxCD or the `deploy.sh` script to handle dynamic service linking and secret injection which Helm's static `values.yaml` cannot do natively. It will ask for a slack webhook URL.

```bash
# Make script executable
chmod +x deploy.sh

# Update helm charts
helm dependency update

# Run deployment
# Usage: ./deploy.sh [RELEASE_NAME] [NAMESPACE]
./deploy.sh my-stack monitoring

```

**Automated Logic in `deploy.sh`:**

Slack Integration: Interactively requests your Slack Webhook URL on the first run and stores it in a K8s Secret.
Dynamic Linking: Injects the correct internal DNS URLs for all backends into the collector (Alloy) and Grafana Data Sources based on your $RELEASE_NAME.
Readiness Check: Block-waits until core deployments reach the Available state.

## ⚙️ Key Configurations

### 🕒 Data Retention

All backends are configured with a strict 14-day (336h) retention policy.  
Cleanup: Background jobs automatically purge data after the 14-day window.

### 🌐 Ingress & Access

Grafana UI: Accessible via the configured host (default: monitoring.example.com).
Data Receivers:
Faro (Frontend Monitoring): Port 12347
OTLP (Traces/Metrics): Ports 4317 (gRPC) / 4318 (HTTP)

### 💾 Persistence & S3

Databases: PostgreSQL and Redis use PersistentVolumeClaims to store configuration and alert schedules.
Telemetry: Logs, Metrics, and Traces are stored in S3-compatible buckets (FluxCD) or local default storage (deploy.sh). Buckets must be pre-created (e.g., loki-chunks, prometheus-data).

## 🔐 Security

The setup avoids clear-text passwords in values.yaml:
Secrets: Used for S3 Credentials (optional), Slack Webhooks, and API Tokens.
Service Accounts: Automated provisioning of Admin-scoped accounts for internal component communication.

### 🧹 Maintenance & Cleanup

To remove the entire stack including Persistent Volume Claims (which Helm usually leaves behind) and Secrets:

```bash
# With deploy.sh
./deploy.sh --cleanup [RELEASE_NAME] [NAMESPACE]
# Or kubectl
kubectl delete namespace [NAMESPACE]
```

## FluxCD

Recommended approach, using GitOps principles (does not need `deploy.sh`).

### Secret for Slack

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: slack-config
  namespace: monitoring
stringData:
  slackWebhookUrl: "https://hooks.slack.com/services/TOKEN_THIS/TOKEN_THAT"
```

### Secret for object storage (optional)

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: cluster-tamer-s3-creds
  namespace: monitoring
stringData:
  access-key: "ABC"
  secret-key: "Secret"
```

### Gitrepo

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: cluster-tamer
  namespace: flux-system
spec:
  interval: 48h
  url: https://github.com/ludicdrive/cluster-tamer
  ref:
    branch: main
```

### Helmrelease

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2beta1
kind: HelmRelease
metadata:
  name: ct  # use a short name, otherwise kube-prom-stack will shorten service names
  namespace: monitoring
spec:
  interval: 10m
  chart:
    spec:
      chart: ./
      sourceRef:
        kind: GitRepository
        name: cluster-tamer
        namespace: flux-system

  valuesFrom:
    - kind: Secret
      name: cluster-tamer-s3-creds
      valuesKey: access-key
      targetPath: loki.loki.storage.s3.access_key
    - kind: Secret
      name: cluster-tamer-s3-creds
      valuesKey: access-key
      targetPath: tempo.tempo.storage.trace.s3.access_key
    - kind: Secret
      name: cluster-tamer-s3-creds
      valuesKey: access-key
      targetPath: pyroscope.pyroscope.config.storage.s3.access_key
    - kind: Secret
      name: cluster-tamer-s3-creds
      valuesKey: secret-key
      targetPath: loki.loki.storage.s3.secret_key
    - kind: Secret
      name: cluster-tamer-s3-creds
      valuesKey: secret-key
      targetPath: tempo.tempo.storage.trace.s3.secret_key
    - kind: Secret
      name: cluster-tamer-s3-creds
      valuesKey: secret-key
      targetPath: pyroscope.pyroscope.config.storage.s3.secret_key
  values:
    global:
      s3:
        endpoint: s3.amazonaws.com
        region: eu-central-1
        bucket: my-cluster-tamer-storage
    k8s-monitoring:
      cluster:
        name: flux-cluster
      opencost:
        opencost:
          exporter:
            defaultClusterId: flux-cluster
          prometheus:
            external:
              enabled: true
              url: http://${release_name}-kube-prom-stack-prometheus:9090

    loki:
      loki:
        storage:
          type: s3
          s3:
            s3: s3://my-cluster-tamer-storage/loki
            region: eu-central-1

    tempo:
      tempo:
        storage:
          trace:
            backend: s3
            s3:
              bucket: my-cluster-tamer-storage
              prefix: tempo
              endpoint: s3.amazonaws.com

    pyroscope:
      pyroscope:
        config:
          storage:
            backend: s3
            s3:
              bucket: my-cluster-tamer-storage
              prefix: pyroscope
              endpoint: s3.amazonaws.com
            
    kube-prom-stack:
      alertmanager:
        config:
          global:
            resolve_timeout: 5m
            slack_api_url_file: '/etc/secrets/slackWebhookUrl'
          route:
            group_by: ['alertname', 'cluster', 'namespace']
            group_wait: 30s
            group_interval: 5m
            repeat_interval: 4h
            receiver: 'slack-default'

            routes:
              - match:
                  severity: critical
                receiver: 'slack-critical'
                group_wait: 10s  # Faster delivery for critical alerts
              - match:
                  team: platform
                receiver: 'slack-platform'

          receivers:
            - name: 'slack-default'
              slack_configs:
                - channel: '#alerts'
                  send_resolved: true
                  title: '{{ .CommonLabels.alertname }}: {{ .Status }}'
                  text: |
                    *Alert:* {{ .CommonLabels.alertname }}
                    *Status:* {{ .Status }}
                    *Cluster:* {{ .CommonLabels.cluster }}
                    *Namespace:* {{ .CommonLabels.namespace }}
                    *Details:* {{ .CommonAnnotations.description }}

            - name: 'slack-critical'
              slack_configs:
                - channel: '#critical-alerts'
                  send_resolved: true
                  icon_emoji: ':rotating_light:'
                  title: '*CRITICAL: {{ .CommonLabels.alertname }}*'
                  text: '{{ .CommonAnnotations.summary }}'

            - name: 'slack-platform'
              slack_configs:
                - channel: '#platform-team'
                  send_resolved: true

          inhibit_rules:
            - source_match:
                severity: 'critical'
              target_match:
                severity: 'warning'
              equal: ['alertname', 'cluster', 'namespace']
    
    blackboxProbeTargets:
      - https://my-url-to-probe.example.com
      - https://another.url-to-probe.example.com
```

### Flux Alert

When a failure occurs in your GitOps pipeline (e.g., a broken Helm chart, an expired Git token, or a failing health check), the following Alert Chain is triggered automatically:

1. Detection (Flux Controllers)
The specific Flux controller (Source, Helm, or Kustomize) detects the error.
Example: The HelmController fails to install your monitoring stack because of a YAML syntax error.
Status: The HelmRelease resource switches to Ready: False with a detailed error message.
2. Emission (Notification Controller)
The Flux Notification Controller watches for these events. Since you defined an Alert resource targeting all HelmReleases with severity: error, it catches this specific event.
It packages the error (e.g., "failed to upgrade release: validation failed") into a standardized payload. Flux Notification Controller Documentation.
3. Transmission (Alertmanager Provider)
Flux uses the Provider you configured to send a POST request to the Alertmanager service within your cluster.
Target: http://$RELEASE_NAME-kube-prom-stack-alertmanager:9093. (Replace `$RELEASE_NAME` with your release name.)
4. Processing (Alertmanager)
The Alertmanager receives the alert. It performs three critical tasks:
Deduplication: If Flux sends the same error 10 times in a minute, Alertmanager merges them into one notification.
Grouping: If 5 different HelmReleases fail at once, it groups them into a single message to avoid "alert fatigue."
Routing: It checks the routes in your values.yaml to decide where to send the data (e.g., Slack).

#### PrometheusRule for Flux Alerts (optional)

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: flux-reconciliation-alerts
  namespace: monitoring
  labels:
    app: flux
    team: platform
    release: ct
spec:
  groups:
    - name: flux-alerts
      rules:
        - alert: FluxReconciliationFailed
          expr: |
            sum by (namespace, name, kind) (
              rate(gotk_reconcile_duration_seconds_count{success="false"}[5m]) > 0
            )
          for: 10m
          labels:
            severity: critical
          annotations:
            summary: "Flux reconciliation failed for {{ $labels.kind }} {{ $labels.namespace }}/{{ $labels.name }}"
            description: "The Flux controller has failed to reconcile this resource repeatedly over the last 10 minutes. Check Git connection, manifests, or cluster state."

        - alert: FluxReconciliationDegraded
          expr: |
            avg_over_time(gotk_reconcile_condition{type="Ready",status="False"}[15m]) == 1
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "{{ $labels.kind }} {{ $labels.namespace }}/{{ $labels.name }} is not ready"
            description: "This Flux-managed resource has been in a non-ready state for more than 5 minutes."
```

#### Flux Provider and Alert

```yaml
apiVersion: notification.toolkit.fluxcd.io/v1beta3
kind: Provider
metadata:
  name: grafana-alertmanager
  namespace: flux-system
spec:
  type: alertmanager
  address: http://$RELEASE_NAME-kube-prom-stack-alertmanager:9093
  channel: flux
---
apiVersion: notification.toolkit.fluxcd.io/v1beta3
kind: Alert
metadata:
  name: flux-system-alerts
  namespace: flux-system
spec:
  providerRef:
    name: grafana-alertmanager
  eventSeverity: error
  eventSources:
    - kind: GitRepository
      name: '*'
    - kind: Kustomization
      name: '*'
    - kind: HelmRelease
      name: '*'
```
