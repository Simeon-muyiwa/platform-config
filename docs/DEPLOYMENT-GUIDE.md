# Microservices Platform Deployment Guide

This guide covers deploying the microservices platform, accessing services, and debugging common issues.

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Cluster Setup](#cluster-setup)
3. [Operator Deployment](#operator-deployment)
4. [Service Deployment](#service-deployment)
5. [Kafka Infrastructure](#kafka-infrastructure)
6. [Accessing Services](#accessing-services)
7. [Debugging Commands](#debugging-commands)
8. [Common Issues & Solutions](#common-issues--solutions)

---

## Prerequisites

- **Minikube** installed and running
- **kubectl** configured
- **Docker** for building images
- **Make** for build automation

### Start Minikube

```bash
# Start minikube with sufficient resources
minikube start --cpus=4 --memory=8192 --driver=docker

# Verify cluster is running
kubectl cluster-info
kubectl get nodes
```

### Configure Docker Environment

```bash
# Point Docker to Minikube's daemon (required for local images)
eval $(minikube docker-env)
```

---

## Cluster Setup

### 1. Create Required Namespaces

```bash
kubectl create namespace kafka
kubectl create namespace webapp-operator-system
```

### 2. Verify Namespaces

```bash
kubectl get namespaces
```

---

## Operator Deployment

### 1. Build the Operator

```bash
cd /Users/simeon/Desktop/IAC/Pulumi_project/microservices-platform/operator

# Build operator image
make docker-build IMG=webapp-operator:v1.0.8

# Verify image exists
docker images | grep webapp-operator
```

### 2. Deploy the Operator

```bash
# Install CRDs
make install

# Deploy the operator
make deploy IMG=webapp-operator:v1.0.8

# Verify operator is running
kubectl get pods -n webapp-operator-system
kubectl logs -f deployment/webapp-operator-controller-manager -n webapp-operator-system
```

### 3. Restart Operator (if needed)

```bash
kubectl rollout restart deployment/webapp-operator-controller-manager -n webapp-operator-system
kubectl rollout status deployment/webapp-operator-controller-manager -n webapp-operator-system
```

---

## Service Deployment

### 1. Build Service Images

```bash
cd /Users/simeon/Desktop/IAC/Pulumi_project/microservices-platform/services

# Build each service
docker build -t identity-service:v1.0.0 ./identity-service
docker build -t user-service:v1.0.0 ./user-service
docker build -t blog-service:v1.0.5 ./blog-service
docker build -t frontend:v1.0.2 ./frontend

# Verify images
docker images | grep -E "identity|user|blog|frontend"
```

### 2. Apply Custom Resources

```bash
cd /Users/simeon/Desktop/IAC/Pulumi_project/microservices-platform/operator

# Apply service CRs
kubectl apply -f config/samples/apps_v1alpha1_identityservice.yaml
kubectl apply -f config/samples/apps_v1alpha1_userservice.yaml
kubectl apply -f config/samples/apps_v1alpha1_blogservice.yaml
kubectl apply -f config/samples/apps_v1alpha1_frontend.yaml

# Verify CRs created
kubectl get identityservice,userservice,blogservice,frontend -n default
```

### 3. Verify Deployments

```bash
# Check all pods
kubectl get pods -n default

# Check all services
kubectl get svc -n default

# Check deployments
kubectl get deployments -n default
```

---

## Kafka Infrastructure

### 1. Deploy Strimzi Operator

```bash
# Apply Strimzi operator
kubectl apply -f 'https://strimzi.io/install/latest?namespace=kafka' -n kafka

# Wait for operator to be ready
kubectl wait --for=condition=ready pod -l name=strimzi-cluster-operator -n kafka --timeout=300s

# Verify Strimzi is running
kubectl get pods -n kafka
```

### 2. Deploy KafkaCluster CR

```bash
# Apply KafkaCluster CR
kubectl apply -f config/samples/apps_v1alpha1_kafkacluster.yaml

# Check KafkaCluster status
kubectl get kafkacluster -n default
kubectl describe kafkacluster my-kafka-cluster -n default
```

### 3. Verify Kafka is Ready

```bash
# Check Kafka resources in kafka namespace
kubectl get kafka,kafkanodepool,kafkatopic -n kafka

# Check Kafka pod status
kubectl get pods -n kafka

# Verify Kafka cluster is ready
kubectl get kafka my-cluster -n kafka -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
```

---

## Accessing Services

### Option 1: Port-Forward (Recommended)

```bash
# Kill any existing port-forwards
pkill -f "port-forward"

# Frontend (Next.js)
kubectl port-forward svc/auth-frontend 3000:3000 -n default &

# Identity Service
kubectl port-forward svc/identity-service 3001:3000 -n default &

# Auth Service
kubectl port-forward svc/auth-service 3002:3000 -n default &
```

**Access URLs:**
- Frontend: http://localhost:3000
- Identity Service: http://localhost:3001
- Auth Service: http://localhost:3002

### Option 2: Minikube Service URL

```bash
# Get service URL (opens tunnel)
minikube service auth-frontend --url

# List all service URLs
minikube service list
```

### Verify Connectivity

```bash
# Test frontend
curl -v http://localhost:3000 2>&1 | head -20

# Test identity service health
curl http://localhost:3001/health

# Check HTTP status
curl -s -o /dev/null -w "%{http_code}" http://localhost:3000
```

---

## Debugging Commands

### Pod Status & Logs

```bash
# List all pods with status
kubectl get pods -n default -o wide

# Get pod details
kubectl describe pod <pod-name> -n default

# View pod logs
kubectl logs <pod-name> -n default

# Follow logs in real-time
kubectl logs -f <pod-name> -n default

# View logs from deployment
kubectl logs deployment/<deployment-name> -n default --tail=100

# View previous container logs (after crash)
kubectl logs <pod-name> -n default --previous
```

### Service Debugging

```bash
# List services with endpoints
kubectl get svc -n default -o wide

# Check service endpoints
kubectl get endpoints -n default

# Describe service
kubectl describe svc <service-name> -n default
```

### Operator Debugging

```bash
# Check operator logs
kubectl logs -f deployment/webapp-operator-controller-manager -n webapp-operator-system

# Check operator RBAC
kubectl get clusterrole webapp-operator-manager-role -o yaml
kubectl get clusterrolebinding -l app.kubernetes.io/name=webapp-operator

# Check CRD status
kubectl get crd | grep apps.example.com
```

### Kafka Debugging

```bash
# Check Strimzi operator logs
kubectl logs deployment/strimzi-cluster-operator -n kafka --tail=100

# Check Kafka broker logs
kubectl logs -l strimzi.io/name=my-cluster-kafka -n kafka --tail=50

# List Kafka topics
kubectl get kafkatopic -n kafka

# Describe Kafka cluster
kubectl describe kafka my-cluster -n kafka

# Check KafkaNodePool
kubectl get kafkanodepool -n kafka
kubectl describe kafkanodepool dual-role -n kafka
```

### Resource Inspection

```bash
# Get CR status
kubectl get identityservice -n default -o yaml
kubectl get kafkacluster -n default -o yaml

# Check events
kubectl get events -n default --sort-by='.lastTimestamp' | tail -20
kubectl get events -n kafka --sort-by='.lastTimestamp' | tail -20

# Check resource usage
kubectl top pods -n default
kubectl top pods -n kafka
```

### Network Debugging

```bash
# Check what's using a port
lsof -i :3000

# Kill process on a port
lsof -ti :3000 | xargs kill -9

# Test DNS resolution from pod
kubectl exec -it <pod-name> -n default -- nslookup identity-service

# Test connectivity between pods
kubectl exec -it <pod-name> -n default -- curl http://identity-service:3000/health
```

### Image Issues

```bash
# Check image pull status
kubectl describe pod <pod-name> -n default | grep -A5 "Events"

# Verify image exists in Minikube
eval $(minikube docker-env)
docker images | grep <image-name>

# Force pull latest image
kubectl rollout restart deployment/<deployment-name> -n default
```

---

## Common Issues & Solutions

### 1. Port Already in Use

**Symptom:** `Error listen tcp4 127.0.0.1:3000: bind: address already in use`

**Solution:**
```bash
# Find and kill process
lsof -ti :3000 | xargs kill -9

# Restart port-forward
kubectl port-forward svc/auth-frontend 3000:3000 -n default &
```

### 2. ImagePullBackOff

**Symptom:** Pod stuck in `ImagePullBackOff` state

**Solution:**
```bash
# Ensure Docker points to Minikube
eval $(minikube docker-env)

# Rebuild image
docker build -t <image>:<tag> .

# Verify image exists
docker images | grep <image>

# Restart deployment
kubectl rollout restart deployment/<name> -n default
```

### 3. CrashLoopBackOff

**Symptom:** Pod keeps restarting

**Solution:**
```bash
# Check logs
kubectl logs <pod-name> -n default --previous

# Check resource limits
kubectl describe pod <pod-name> -n default | grep -A10 "Resources"

# Increase memory if OOM
kubectl patch deployment <name> -n default --type='json' \
  -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/resources/limits/memory", "value": "1024Mi"}]'
```

### 4. Kafka Connection Issues

**Symptom:** Services can't connect to Kafka

**Solution:**
```bash
# Verify Kafka is ready
kubectl get kafka my-cluster -n kafka

# Check Kafka bootstrap service
kubectl get svc -n kafka | grep bootstrap

# Verify service can resolve Kafka DNS
kubectl exec -it <service-pod> -n default -- nslookup my-cluster-kafka-bootstrap.kafka.svc.cluster.local
```

### 5. Operator Not Reconciling

**Symptom:** CR changes not reflected in deployments

**Solution:**
```bash
# Check operator logs for errors
kubectl logs deployment/webapp-operator-controller-manager -n webapp-operator-system --tail=100

# Restart operator
kubectl rollout restart deployment/webapp-operator-controller-manager -n webapp-operator-system

# Verify RBAC permissions
kubectl auth can-i create deployments --as=system:serviceaccount:webapp-operator-system:webapp-operator-controller-manager
```

### 6. Strimzi Kafka Version Error

**Symptom:** `Unsupported Kafka.spec.kafka.version`

**Solution:**
```bash
# Check supported versions
kubectl logs deployment/strimzi-cluster-operator -n kafka | grep "supported versions"

# Update KafkaCluster CR to use Kafka 4.0.0
kubectl patch kafkacluster my-kafka-cluster -n default --type='merge' \
  -p '{"spec":{"kafka":{"version":"4.0.0"}}}'
```

---

## Quick Start Summary

```bash
# 1. Start cluster
minikube start --cpus=4 --memory=8192
eval $(minikube docker-env)

# 2. Create namespaces
kubectl create namespace kafka
kubectl create namespace webapp-operator-system

# 3. Deploy operator
cd /Users/simeon/Desktop/IAC/Pulumi_project/microservices-platform/operator
make docker-build IMG=webapp-operator:v1.0.8
make install
make deploy IMG=webapp-operator:v1.0.8

# 4. Deploy services
kubectl apply -f config/samples/

# 5. Deploy Kafka
kubectl apply -f 'https://strimzi.io/install/latest?namespace=kafka' -n kafka

# 6. Access frontend
pkill -f "port-forward" 2>/dev/null
kubectl port-forward svc/auth-frontend 3000:3000 -n default &

# 7. Open browser
open http://localhost:3000
```

---

## Health Check Script

Create a quick health check:

```bash
#!/bin/bash
echo "=== Cluster Health Check ==="

echo -e "\n--- Namespaces ---"
kubectl get ns | grep -E "default|kafka|webapp"

echo -e "\n--- Operator ---"
kubectl get pods -n webapp-operator-system

echo -e "\n--- Services ---"
kubectl get pods -n default

echo -e "\n--- Kafka ---"
kubectl get kafka,kafkanodepool -n kafka

echo -e "\n--- Port Forwards ---"
pgrep -f "port-forward" && echo "Port forwards active" || echo "No port forwards"

echo -e "\n--- Frontend Test ---"
curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" http://localhost:3000 2>/dev/null || echo "Frontend not accessible"
```

---

*Last Updated: December 31, 2025*
