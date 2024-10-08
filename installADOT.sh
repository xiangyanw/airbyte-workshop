#!/bin/bash

# Install cert manager
echo "Installing cert manager ..."

kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.15.3/cert-manager.yaml

kubectl wait --for=condition=Ready pod -l app=cert-manager -n cert-manager

# Install ADOT addon
echo "Installing ADOT EKS addon ..."

eksctl create addon \
  --name adot \
  --cluster $CLUSTER_NAME \
  --force \
  --wait

# Configure IAM role for service account
echo "Configuring IAM role for service account for ADOT collector ..."

cat <<EOF > PermissionPolicyIngest.json
{
  "Version": "2012-10-17",
   "Statement": [
       {"Effect": "Allow",
        "Action": [
           "aps:RemoteWrite", 
           "aps:GetSeries", 
           "aps:GetLabels",
           "aps:GetMetricMetadata"
        ], 
        "Resource": "*"
      }
   ]
}
EOF

aws iam create-policy --policy-name AMPIngestPolicy-${CLUSTER_NAME} \
  --policy-document file://PermissionPolicyIngest.json \
  --query 'Policy.Arn' --output text

eksctl create iamserviceaccount \
  --cluster $CLUSTER_NAME \
  --name oltp-collector \
  --namespace adot-collector \
  --attach-policy-arn arn:aws:iam::$ACCOUNT_ID:policy/AMPIngestPolicy-${CLUSTER_NAME} \
  --override-existing-serviceaccounts \
  --approve
  
# Install ADOT collector
echo "Installing ADOT collector ..."

if [[ -z ${AMP_WP_ID} ]]; then
  echo "Error: AMP workspace ID is empty. Please make sure that you have created an AMP workspace."
  exit 1
else
  echo "AMP workspace ID: ${AMP_WP_ID}"
fi

if [[ -z ${AWS_REGION} ]]; then
  echo "Error: AWS_REGION is empty."
  exit 1
fi

cat <<EOF > adot.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: adot-collector
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: oltp-collector
  namespace: adot-collector
---
apiVersion: opentelemetry.io/v1alpha1
kind: OpenTelemetryCollector
metadata:
  name: oltp
  namespace: adot-collector
spec:
  mode: deployment
  resources:
    requests:
      cpu: "1"
    limits:
      cpu: "1"
  serviceAccount: oltp-collector
  config: |
    extensions:
      sigv4auth:
        region: "${AWS_REGION}"
        service: "aps"
        
    receivers:
      otlp:
        protocols:
          grpc:
          http:

    processors:
      batch/metrics:
        timeout: 60s

    exporters:
      prometheusremotewrite:
        endpoint: "https://aps-workspaces.${AWS_REGION}.amazonaws.com/workspaces/${AMP_WP_ID}/api/v1/remote_write"
        auth:
          authenticator: sigv4auth
      logging:
        loglevel: debug

    service:
      extensions: [sigv4auth]
      pipelines:   
        metrics:
          receivers: [otlp]
          processors: [batch/metrics]
          exporters: [prometheusremotewrite, logging]
EOF

kubectl apply -f adot.yaml

kubectl -n adot-collector wait --for=condition=Ready pod -l app.kubernetes.io/name=oltp-collector

echo "Done"