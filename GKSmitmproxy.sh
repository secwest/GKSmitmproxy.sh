#!/bin/bash

# DISCLAIMER: For authorized testing only. Grants extensive permissions.

# Check if Google Cloud SDK is installed, if not, install it
if ! command -v gcloud &> /dev/null; then
    echo "Google Cloud SDK not found. Installing..."
    
    # Add the Cloud SDK distribution URI as a package source
    echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] http://packages.cloud.google.com/apt cloud-sdk main" | sudo tee -a /etc/apt/sources.list.d/google-cloud-sdk.list

    # Import the Google Cloud public key
    curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key --keyring /usr/share/keyrings/cloud.google.gpg add -

    # Update and install the Cloud SDK
    sudo apt-get update && sudo apt-get install google-cloud-sdk -y

    echo "Google Cloud SDK installed."
else
    echo "Google Cloud SDK already installed."
fi

# Automatically determine Project ID, Cluster Name, and Cluster Location
PROJECT_ID=$(gcloud config get-value project)
CLUSTER_NAME=$(kubectl config current-context | cut -d'_' -f2)
CLUSTER_LOCATION=$(kubectl config current-context | cut -d'_' -f3)
SERVICE_ACCOUNT_NAME="mitmproxy-service-account"
NAMESPACE="mitmproxy"

# Check if the variables are set
if [[ -z "$PROJECT_ID" || -z "$CLUSTER_NAME" || -z "$CLUSTER_LOCATION" ]]; then
    echo "Error: Could not determine project ID, cluster name, or cluster location."
    exit 1
fi

echo "Using Project ID: $PROJECT_ID"
echo "Using Cluster Name: $CLUSTER_NAME"
echo "Using Cluster Location: $CLUSTER_LOCATION"

# Setup IAM roles for the service account
gcloud iam service-accounts create $SERVICE_ACCOUNT_NAME \
    --display-name "Service Account for Mitmproxy"

# Bind roles to the service account (e.g., roles/container.admin)
# WARNING: These roles provide extensive access. Use with caution.
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member "serviceAccount:$SERVICE_ACCOUNT_NAME@$PROJECT_ID.iam.gserviceaccount.com" \
    --role "roles/container.admin"

# Add more roles as needed...

# Get credentials for your GKE cluster
gcloud container clusters get-credentials $CLUSTER_NAME --zone $CLUSTER_LOCATION --project $PROJECT_ID

# Create a Kubernetes namespace
kubectl create ns $NAMESPACE

# Create RBAC roles and role bindings in the namespace
kubectl create rolebinding mitmproxy-admin-binding --clusterrole=admin --serviceaccount=$NAMESPACE:$SERVICE_ACCOUNT_NAME --namespace=$NAMESPACE

# Network Policies (if using Calico for network policies in GKE)
# The following is an example policy that allows all ingress and egress traffic in the namespace.
cat <<EOF | kubectl apply -n $NAMESPACE -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-all
spec:
  podSelector: {}
  ingress:
  - {}
  egress:
  - {}
EOF

echo "Setup complete. Service account, RBAC, and network policies configured."
