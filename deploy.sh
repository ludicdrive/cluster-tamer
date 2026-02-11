#!/bin/bash

# --- CONFIGURATION ---
RELEASE_NAME=${1:-"my-stack"}
NAMESPACE=${2:-"monitoring"}
CHART_PATH="."

# --- CLEANUP LOGIC ---
if [[ "$3" == "--cleanup" ]]; then
    echo "⚠️  WARNING: Deleting all resources in namespace: $NAMESPACE"
    # Delete the Helm release
    helm uninstall "$RELEASE_NAME" -n "$NAMESPACE"
    # Delete PVCs (Helm doesn't delete them automatically to protect data)
    kubectl delete pvc -n "$NAMESPACE" -l "app.kubernetes.io/instance=$RELEASE_NAME"
    echo "✅ Cleanup complete."
    echo "If there were errors, try delete the namespace."
    exit 0
fi

echo "🚀 Starting deployment: $RELEASE_NAME in namespace: $NAMESPACE"
kubectl create namespace $NAMESPACE > /dev/null 2>&1

# Slack Webhook
if ! kubectl get secret slack-config -n "$NAMESPACE" > /dev/null 2>&1; then
    read -p "Enter Slack Webhook URL: " SLACK_URL
    kubectl create secret generic slack-config --from-literal=slackWebhookUrl="$SLACK_URL" -n "$NAMESPACE"
fi

SLACK_WEBHOOK_URL=$(kubectl get secret slack-config -n "$NAMESPACE" -o jsonpath='{.data.url}' | base64 -d)

# Update Dependencies
echo "📦 Checking Helm dependencies..."
helm dependency list $CHART_PATH || { echo "❌ Dependency list failed"; exit 1; }

# Construct Helm Arguments
HELM_OPTS=(
  --namespace "$NAMESPACE"
  --create-namespace

  # Dynamic URLs for k8s-monitoring destinations
  # Destination 0: Prometheus
  --set "k8s-monitoring.destinations[0].name=prometheus"
  --set "k8s-monitoring.destinations[0].type=prometheus"
  --set "k8s-monitoring.destinations[0].url=http://$RELEASE_NAME-kube-prometheus-stack-prometheus:9090/api/v1/write"

  # Destination 1: Loki
  --set "k8s-monitoring.destinations[1].name=loki"
  --set "k8s-monitoring.destinations[1].type=loki"
  --set "k8s-monitoring.destinations[1].url=http://$RELEASE_NAME-loki-gateway/loki/api/v1/push"

  # Destination 2: Tempo
  --set "k8s-monitoring.destinations[2].name=tempo"
  --set "k8s-monitoring.destinations[2].type=otlp"
  --set "k8s-monitoring.destinations[2].url=http://$RELEASE_NAME-tempo:4317"
  --set "k8s-monitoring.destinations[2].traces.enabled=true"

  # Destination 3: Pyroscope
  --set "k8s-monitoring.destinations[3].name=pyroscope"
  --set "k8s-monitoring.destinations[3].type=pyroscope"
  --set "k8s-monitoring.destinations[3].url=http://$RELEASE_NAME-pyroscope:4040"

  # Alerting
  --set "k8s-monitoring.alerting.alertmanager.host=http://$RELEASE_NAME-kube-prometheus-stack-alertmanager:9093"

  # tempo 
  --set "tempo.tempo.metricsGenerator.remoteWriteUrl=http://$RELEASE_NAME-kube-prometheus-stack-prometheus:9090/api/v1/write"

  # opencost
  --set "k8s-monitoring.clusterMetrics.opencost.opencost.prometheus.external.url=http://$RELEASE_NAME-kube-prometheus-stack-prometheus:9090"
  --set "k8s-monitoring.clusterMetrics.opencost.service.labels.release=$RELEASE_NAME"
  --set "k8s-monitoring.clusterMetrics.opencost.opencost.metrics.serviceMonitor.additionalLabels.release=$RELEASE_NAME"
)

# Execution
echo "⚙️  Running Helm upgrade..."
helm upgrade --install "$RELEASE_NAME" "$CHART_PATH" "${HELM_OPTS[@]}"

# Wait for Health (Wait command for Deployments & StatefulSets)
echo "⏳ Waiting for core components..."
CORE_DEPS=("$RELEASE_NAME-loki-gateway" "$RELEASE_NAME-kube-prometheus-stack-operator" "$RELEASE_NAME-grafana" "$RELEASE_NAME-opencost" "$RELEASE_NAME-alloy-operator" )

for DEP in "${CORE_DEPS[@]}"; do
  kubectl wait --for=condition=available --timeout=300s "deployment/$DEP" -n "$NAMESPACE" || exit 1
done

echo "✅ Deployment successful!"
