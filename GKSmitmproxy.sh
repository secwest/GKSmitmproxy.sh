#!/bin/bash

# DISCLAIMER: This script is for authorized security testing and educational purposes only.

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

# Function to deploy Mitmproxy and the demo pod
deploy_mitmproxy_and_demo_pod() {
    echo "Deploying Mitmproxy in the $NAMESPACE namespace..."

    # Deploy Mitmproxy pod
    kubectl apply -n $NAMESPACE -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: mitmproxy
  labels:
    app: mitmproxy
spec:
  containers:
  - name: mitmproxy
    image: mitmproxy/mitmproxy
    command: ["mitmweb"]
    args: ["--web-host", "0.0.0.0"]
EOF

    # Deploy Mitmproxy service
    kubectl apply -n $NAMESPACE -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: mitmproxy-svc
spec:
  selector:
    app: mitmproxy
  ports:
    - protocol: TCP
      port: 8080
      targetPort: 8080
EOF

    echo "Mitmproxy deployed. Now deploying the demo pod for verification."

    # Export the mitmproxy-ca.pem certificate
    kubectl cp $NAMESPACE/mitmproxy:/root/.mitmproxy/mitmproxy-ca.pem ./mitmproxy-ca.pem

    # Create a secret from the mitmproxy-ca.pem certificate
    kubectl create secret generic mitmproxysecret --from-file=mitmproxy-ca.pem -n $NAMESPACE

    # Deploy a demo pod to validate the setup
    kubectl apply -n $NAMESPACE -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: mitm-demo-pod
spec:
  containers:
  - name: mitm-demo
    image: $PODIMAGE
    command:
    - sleep
    args:
    - 5000s
    lifecycle:
      postStart:
        exec:
          command:
          - bash
          - -c
          - cp /certs/mitmproxy-ca.pem /usr/local/share/ca-certificates/mitmproxy-ca.crt; update-ca-certificates --fresh
    env:
    - name: http_proxy
      value: "http://mitmproxy-svc.$NAMESPACE:8080/"
    - name: https_proxy
      value: "http://mitmproxy-svc.$NAMESPACE:8080/"
    volumeMounts:
    - mountPath: /certs
      name: mitmproxysecret
      readOnly: true
  volumes:
  - name: mitmproxysecret
    secret:
      secretName: mitmproxysecret
EOF

    echo "Demo pod deployed. Use the verification step to confirm setup."
}

# Function to detect which service mesh is being used
detect_service_mesh() {
    if kubectl get namespace -L istio-injection | grep -q 'enabled'; then
        echo "Istio"
    elif kubectl get namespace -L linkerd.io/inject | grep -q 'enabled'; then
        echo "Linkerd"
    else
        echo "None"
    fi
}

# Function to modify Istio policies
modify_istio_policies() {
    echo "Modifying Istio policies..."

    # Disable automatic sidecar injection for Mitmproxy pod
    kubectl label namespace $NAMESPACE istio-injection=disabled --overwrite

    # Apply Istio Gateway for external access
    # Note: Replace mitmproxy.example.com with your domain
    kubectl apply -n $NAMESPACE -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: mitmproxy-gateway
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 8080
      name: http
      protocol: HTTP
    hosts:
    - "mitmproxy.example.com"
EOF

    # Apply Istio VirtualService for routing
    kubectl apply -n $NAMESPACE -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: mitmproxy
spec:
  hosts:
  - "mitmproxy.example.com"
  gateways:
  - mitmproxy-gateway
  http:
  - match:
    - uri:
        prefix: /
    route:
    - destination:
        host: mitmproxy-svc
        port:
          number: 8080
EOF

    # Apply Istio AuthorizationPolicy (allow all for this example)
    kubectl apply -n $NAMESPACE -f - <<EOF
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: allow-all
spec:
  action: ALLOW
  rules:
  - {}
EOF
}

# Function to modify Linkerd policies
modify_linkerd_policies() {
    echo "Modifying Linkerd policies..."

    # Annotate the namespace to disable Linkerd proxy injection
    kubectl annotate namespace $NAMESPACE linkerd.io/inject=disabled --overwrite

    # Find the Mitmproxy deployment name
    MITMPROXY_DEPLOYMENT=$(kubectl get deployment -n $NAMESPACE -l app=mitmproxy -o jsonpath="{.items[0].metadata.name}")
    
    # Check if a deployment was found
    if [ -z "$MITMPROXY_DEPLOYMENT" ]; then
        echo "Mitmproxy deployment not found. Exiting."
        exit 1
    fi

    echo "Mitmproxy deployment found: $MITMPROXY_DEPLOYMENT"

    # Inject Linkerd proxy into the Mitmproxy deployment
    kubectl get deployment -n $NAMESPACE $MITMPROXY_DEPLOYMENT -o yaml | linkerd inject - | kubectl apply -f -

    # Additional Linkerd-specific configurations can be added here
    # For example, configuring traffic splits, service profiles, etc.
}

# Function to modify service mesh policies
modify_service_mesh_policies() {
    SERVICE_MESH=$(detect_service_mesh)

    case $SERVICE_MESH in
        Istio)
            modify_istio_policies
            ;;
        Linkerd)
            modify_linkerd_policies
            ;;
        None)
            echo "No service mesh detected. No additional modifications needed."
            ;;
        *)
            echo "Unknown service mesh. Exiting."
            exit 1
            ;;
    esac
}


# Main execution
echo "Starting the proxy..."
deploy_mitmproxy
modify_service_mesh_policies
echo "Proxy complete."

