#!/bin/bash

# Configure IAM role for service account
echo "Configuring IAM role for service account for Grafana ..."

cat <<EOF > PermissionPolicyQuery.json
{
  "Version": "2012-10-17",
   "Statement": [
       {"Effect": "Allow",
        "Action": [
           "aps:QueryMetrics",
           "aps:GetSeries", 
           "aps:GetLabels",
           "aps:GetMetricMetadata"
        ], 
        "Resource": "*"
      }
   ]
}
EOF

aws iam create-policy --policy-name AMPQueryPolicy-${CLUSTER_NAME} \
  --policy-document file://PermissionPolicyQuery.json \
  --query 'Policy.Arn' --output text

eksctl create iamserviceaccount \
  --cluster ${CLUSTER_NAME} \
  --name grafana-sa \
  --namespace monitoring \
  --attach-policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/AMPQueryPolicy-${CLUSTER_NAME} \
  --override-existing-serviceaccounts \
  --approve

# 
echo "Deploying Grafana ..."

cat > grafana_values.yaml <<EOF
serviceAccount:
  create: false
  name: "grafana-sa"
grafana.ini:
  auth:
    sigv4_auth_enabled: true
service:
  enabled: true
  type: LoadBalancer
  loadBalancerClass: "service.k8s.aws/nlb"
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
EOF

helm repo add grafana https://grafana.github.io/helm-charts

helm upgrade --install grafana grafana/grafana \
  -n monitoring \
  -f ./grafana_values.yaml
  
kubectl -n monitoring wait --for=condition=Ready pod -l app.kubernetes.io/name=grafana

#echo "Visit your Grafana via the following URL:"
#kubectl get svc --namespace monitoring grafana -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

echo "Done"