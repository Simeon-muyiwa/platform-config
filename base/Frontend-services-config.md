
Ran terminal command:  cd /Users/simeon/Desktop/IAC/Pulumi_project && source venv/bin/activate && make deploy-irsa-with-letsencrypt

## End‑to‑end platform workflow

This document describes the full workflow for building, deploying, and operating the Healthxcape platform, including the converged **API gateway + relative paths** solution for the frontend.

***

## 1. Build and publish images

- Source code lives in `microservices-platform/services/<service>`.
- Each service is built into a Docker image with a versioned tag: `healthxcape/<service>:v1.0.x`.
- Images are pushed to ECR and, in air‑gapped/manual scenarios, mirrored onto cluster nodes (e.g. via `nerdctl`).

Example (high‑level):

- Build locally.
- Tag as `v1.0.x` (and optionally `latest`).
- Push to ECR.
- Ensure cluster nodes have the image available if they cannot pull directly from ECR.

> Note: the legacy name `auth-frontend` has been standardised to `frontend` in manifests and documentation.

***

## 2. GitOps with ArgoCD (App‑of‑Apps)

- GitOps configuration lives in the `platform-config` repo:
  - Repo: `https://github.com/Simeon-muyiwa/platform-config.git`
  - Branch: `main`
  - Root ArgoCD app: `platform-apps` (App‑of‑Apps)
  - Path for child apps: `apps/` (each file here is an `Application` CR).

- Each microservice or component is represented as a CR in:
  - `platform-config/base/<service>/<cr>.yaml`

**Flow:**

1. Update the image tag or reference in the appropriate CR (for example, `platform-config/base/frontend/frontend.yaml`).
2. Commit and push to `main`.
3. ArgoCD (via `platform-apps`) scans `apps/`, picks up changed child Applications, syncs them, and the operator reconciles the CRs into `Deployment`/`StatefulSet` (or other) resources.
4. If needed, trigger a hard refresh of `platform-apps` to force re‑sync:
   - Patch the `Application` with `argocd.argoproj.io/refresh: hard` and then check application and pod status.

***

## 3. Frontend, NEXT_PUBLIC issue, and converged API gateway solution

### 3.1 Root cause (what went wrong)

- The Next.js frontend uses `NEXT_PUBLIC_*` variables, which are **baked into the JS bundle at build time**, not read at runtime.
- Example from the built bundle:

  ```js
  let n=a.env.NEXT_PUBLIC_USER_SERVICE_URL||"http://localhost:3001";
  ```

- Because `NEXT_PUBLIC_USER_SERVICE_URL` was undefined at build time, it defaulted to `http://localhost:3001`.
- The browser then tries to call `http://localhost:3001/...`, which:
  - Is not reachable from users’ machines.
  - Or was configured to use internal Kubernetes names (e.g. `identity-service:3000`), which the browser cannot resolve.

**Conclusion:** the frontend was using internal service names / localhost in the JS bundle, but the browser must go via external URLs. The fix is to route through an HTTP API gateway and use **relative paths** from the frontend.

We initially considered a **Dockerfile‑based fix** (injecting `NEXT_PUBLIC_*` via `--build-arg`) because it quickly stops `localhost:300x` leaks, but it couples the image to every backend URL. The converged solution below avoids that and does **not** require build‑time URL injection.

***

## 4. Converged solution: API gateway (Ingress) + relative paths

### 4.1 Design in one sentence

- The frontend always calls **relative URLs** like `/api/identity`, `/api/user`, `/api/blog`.
- NGINX Ingress acts as an **API gateway**, routing those paths to internal Kubernetes services `identity-service`, `user-service`, and `blog-service` in the cluster. [kubernetes.github](https://kubernetes.github.io/ingress-nginx/examples/rewrite/)

No browser ever calls `identity-service:3000` or `localhost:3001` directly.

***

### 4.2 Ingress: API gateway on `healthxcape.com`

Create a single ingress that serves both the frontend and APIs, using regex + rewrite:

`platform-config/base/frontend/frontend-ingress.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: frontend-ingress
  namespace: default
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/proxy-body-size: "10m"
    nginx.ingress.kubernetes.io/use-regex: "true"
    nginx.ingress.kubernetes.io/rewrite-target: /$2
    cert-manager.io/cluster-issuer: "letsencrypt-dns-prod"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - healthxcape.com
        - www.healthxcape.com
      secretName: frontend-tls-prod
  rules:
    - host: healthxcape.com
      http:
        paths:
          # Frontend app
          - path: /
            pathType: Prefix
            backend:
              service:
                name: frontend
                port:
                  number: 3000

          # API routes
          - path: /api/identity(/|$)(.*)
            pathType: Prefix
            backend:
              service:
                name: identity-service
                port:
                  number: 3000
          - path: /api/user(/|$)(.*)
            pathType: Prefix
            backend:
              service:
                name: user-service
                port:
                  number: 3001
          - path: /api/blog(/|$)(.*)
            pathType: Prefix
            backend:
              service:
                name: blog-service
                port:
                  number: 3002

    - host: www.healthxcape.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: frontend
                port:
                  number: 3000
          - path: /api/identity(/|$)(.*)
            pathType: Prefix
            backend:
              service:
                name: identity-service
                port:
                  number: 3000
          - path: /api/user(/|$)(.*)
            pathType: Prefix
            backend:
              service:
                name: user-service
                port:
                  number: 3001
          - path: /api/blog(/|$)(.*)
            pathType: Prefix
            backend:
              service:
                name: blog-service
                port:
                  number: 3002
```

- `nginx.ingress.kubernetes.io/use-regex: "true"` and `nginx.ingress.kubernetes.io/rewrite-target: /$2` implement a standard NGINX Ingress rewrite pattern: `/api/user/xyz` is routed to the `user-service` without the `/api/user` prefix. [reddit](https://www.reddit.com/r/kubernetes/comments/oc6mc6/nginx_ingress_rewritetarget/)
- This Ingress manifest is the **single source of truth** for all external API paths and backend mappings and lives in `platform-config` for GitOps.

***

### 4.3 Frontend config: relative URLs only

The frontend must never use internal K8s DNS names (`identity-service:3000`) or `localhost:300x` in client‑side code. Instead, it uses `/api/...`.

`platform-config/base/frontend/frontend-config.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: frontend-config
  namespace: default
data:
  IDENTITY_API_URL: /api/identity
  USER_API_URL: /api/user
  BLOG_API_URL: /api/blog
```

Conceptual usage in frontend code:

```ts
const IDENTITY_API_URL = process.env.IDENTITY_API_URL ?? '/api/identity';
const USER_API_URL     = process.env.USER_API_URL     ?? '/api/user';
const BLOG_API_URL     = process.env.BLOG_API_URL     ?? '/api/blog';

// Browser calls like:
fetch(`${USER_API_URL}/profiles/identity/...`);
```

You can either:

- Inject these values as environment variables from the ConfigMap into the frontend container; or
- Hard‑code `/api/...` in code and keep the ConfigMap for future flexibility.

The key rule: **browser/frontend calls only `/api/...`**, never in‑cluster hostnames. [stackoverflow](https://stackoverflow.com/questions/76995053/how-to-use-relative-path-fetch-in-nextjs-app-router)

***

### 4.4 GitOps + Kustomize integration

Instead of applying YAML from a bastion, define everything declaratively in `platform-config`.

`platform-config/base/frontend/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - frontend-deployment.yaml
  - frontend-service.yaml
  - frontend-ingress.yaml
  - frontend-config.yaml

configMapGenerator:
  - name: frontend-config
    behavior: merge
    literals:
      - IDENTITY_API_URL=/api/identity
      - USER_API_URL=/api/user
      - BLOG_API_URL=/api/blog
```

- `configMapGenerator` generates a ConfigMap with a hash in its name (e.g. `frontend-config-<hash>`).  
- Because the `Deployment` references this generated ConfigMap, any change to the literals produces a new name, which updates the Pod template and triggers an automatic rolling update when ArgoCD syncs. [kubernetes](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/)

**Overlays** (`platform-config/overlays/dev`, `staging`, `prod`) can override:

- Hostnames.
- TLS secrets.
- Paths (if needed).

But the **frontend still calls `/api/...` in all environments**.

***

### 4.5 No Docker build dependency for URLs

In this converged solution:

- You do **not** depend on Docker `--build-arg` to fix URL issues.
- You can deploy a generic frontend image that:
  - Uses relative URLs (`/api/...`) directly, or
  - Reads simple envs like `IDENTITY_API_URL=/api/identity` injected at runtime.
- Changes to:
  - API routing,
  - Backend mapping,
  - Feature toggles  
  are all handled by **Ingress + ConfigMap + Kustomize + ArgoCD**, without rebuilding the image. [devopscube](https://devopscube.com/kuztomize-configmap-generators/)

***

## 5. DNS and TLS / cert‑manager / IRSA

### 5.1 DNS mismatch

Example issue observed:

- Local DNS resolved `healthxcape.com` to `13.135.8.254`, but the current public IP for the cluster ingress/Load Balancer was `13.41.15.144` (later changed to `13.135.181.208`).

**Fix if necessary:**

- Update Route53 A records for:
  - `healthxcape.com`
  - `www.healthxcape.com`
- Example command:

  ```bash
  aws route53 change-resource-record-sets \
    --hosted-zone-id Z046419436MKL77O00IAV \
    --change-batch '...'
  ```

- Ensure the IPs match the **current inventory** (the latest public IP of our ingress).

Additionally, ensure:

- cert‑manager is configured with the correct IAM Role via IRSA.
- Certificates for `healthxcape.com` and `www.healthxcape.com` are issued and in `Ready` state.

***

## 6. Node image tags and deployment image references

In air‑gapped or partially air‑gapped environments:

- Tag images as `latest` on both master and worker nodes using `nerdctl`:
  - For each of: `frontend`, `blog-service`, `user-service`, `identity-service`.
  - Tag `v1.0.0` as `latest` on worker node(s) and master.

Verify:

- Pod status:

  ```bash
  kubectl get pods -n default -o wide
  ```

- Which images Deployments reference:

  ```bash
  kubectl get deployment <service>-deployment -o yaml | grep 'image:' | head -N
  ```

This ensures Deployments reference images that actually exist on nodes, which is critical when they cannot pull directly from ECR at runtime.

***

## 7. PostgreSQL, storage, and local‑path provisioner

### 7.1 Problem: Postgres pods in `Pending`

- Services (`blog-service`, `user-service`) depend on PostgreSQL.
- Postgres pods were stuck in `Pending` because their PVCs could not be bound (no usable `StorageClass`).

### 7.2 Temporary fix: local‑path provisioner

Short‑term approach until AWS EBS CSI driver is deployed:

- Install Rancher `local-path` provisioner for dynamic hostPath storage.  
- This should eventually be codified via Ansible or similar automation, not run manually.

**Steps:**

1. Install `local-path` provisioner (dev only):

   ```bash
   kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.26/deploy/local-path-storage.yaml
   ```

2. Make it the default `StorageClass`:

   ```bash
   kubectl patch storageclass local-path \
     -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
   kubectl get storageclass
   ```

3. Recreate Postgres PVCs and StatefulSets:

   ```bash
   kubectl delete pvc postgres-data-blog-service-postgres-0 postgres-data-user-service-postgres-0 -n default --force
   kubectl delete statefulset blog-service-postgres user-service-postgres -n default --force
   ```

4. Confirm local‑path provisioner pod is running:

   ```bash
   kubectl get pods -n local-path-storage
   ```

Once Postgres pods are running:

- Restart dependent services so they reconnect:

  ```bash
  kubectl delete pods -l app=blog-service -n default --force
  kubectl delete pods -l app=user-service -n default --force
  ```

- Wait and check:

  ```bash
  kubectl get pods -n default
  kubectl logs -l app=blog-service --tail=5
  kubectl logs -l app=user-service --tail=5
  ```

***

## 8. Ready for future Consul integration

Later, when Consul is introduced:

- Keep the **external contract** exactly the same:
  - Browser → `https://healthxcape.com` → `/api/...`.
- Point the ingress/API gateway’s backend resolution to services registered in Consul:
  - Either via Consul API Gateway.
  - Or via another gateway that uses Consul for service discovery.

This allows you to add:

- Cross‑cluster and hybrid discovery.
- Health‑aware routing.
- mTLS and traffic policies.

Without changing:

- Frontend code,
- Dockerfile,
- or the `/api/...` pattern.

***

## 9. Checklist someone can follow

1. **Build & push images**
   - Build service images.
   - Tag with versions (optionally also `latest`).
   - Push to ECR and mirror onto nodes if required.

2. **Update GitOps config**
   - Edit `platform-config/base/<service>/<cr>.yaml` to use the new image tag.
   - Commit and push to `main`.

3. **ArgoCD sync**
   - Ensure `platform-apps` (App‑of‑Apps) points to `apps/` in `platform-config`.
   - Trigger a hard refresh if necessary.
   - Confirm child Applications and pods sync.

4. **Frontend env and API gateway**
   - Ensure frontend calls only **relative URLs** (`/api/identity`, `/api/user`, `/api/blog`), not `localhost` or internal `.svc.cluster.local` names.
   - Keep the `frontend-ingress` manifest in `platform-config/base/frontend/` as the source of truth for API routes and CORS.
   - Ensure the `frontend-config` ConfigMap (or equivalent) uses `/api/...` values if env vars are used.

5. **DNS and certificates**
   - Update Route53 A records for `healthxcape.com` and `www.healthxcape.com` to the current ingress/Load Balancer IP.
   - Verify cert‑manager IRSA works and certificates are issued.
   - Run `kubectl get certificates -A` and confirm they are `Ready`.

6. **Storage and databases**
   - For dev: ensure `local-path` is installed and set as default `StorageClass` until AWS EBS CSI driver is in place.
   - Recreate PVCs/StatefulSets for Postgres if needed.
   - Restart `blog-service` and `user-service` pods so they reconnect to databases.

7. **Final validation**
   - Check all pods are `Running` and `Ready`.
   - Test the frontend over HTTPS using the correct domain.
   - Verify API calls go through the gateway and successfully reach `identity-service`, `user-service`, and `blog-service`.