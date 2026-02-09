# Kafka Event-Driven DDD Microservices Implementation Guide

## Table of Contents
1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Prerequisites](#prerequisites)
4. [Part 1: Strimzi Kafka Installation](#part-1-strimzi-kafka-installation)
5. [Part 2: Kafka Topics Configuration](#part-2-kafka-topics-configuration)
6. [Part 3: Shared Kafka Library (@platform/kafka)](#part-3-shared-kafka-library-platformkafka)
7. [Part 4: NestJS Service Integration](#part-4-nestjs-service-integration)
8. [Part 5: Docker Build Configuration](#part-5-docker-build-configuration)
9. [Part 6: Kubernetes Operator Updates](#part-6-kubernetes-operator-updates)
10. [Part 7: Testing the Event Flow](#part-7-testing-the-event-flow)
11. [Part 8: Frontend Integration](#part-8-frontend-integration)
12. [Troubleshooting Guide](#troubleshooting-guide)
13. [Lessons Learned](#lessons-learned)

---

## Overview

This document details the complete implementation of an event-driven microservices platform using:
- **Strimzi Kafka** (KRaft mode - no ZooKeeper) on Kubernetes/Minikube
- **Domain-Driven Design (DDD)** with bounded contexts
- **NestJS** microservices with shared Kafka library
- **Ansible Kubernetes Operator** for declarative deployments
- **Next.js** frontend with authentication integration

### The Event Flow

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│ Identity Service│     │      Kafka      │     │  User Service   │
│   (Auth BC)     │     │  (Strimzi)      │     │  (Profile BC)   │
├─────────────────┤     ├─────────────────┤     ├─────────────────┤
│ POST /sign-up   │────▶│ identity.events │────▶│ CreateProfile   │
│                 │     │    topic        │     │    UseCase      │
│ Publishes:      │     │                 │     │                 │
│ identity.created│     │                 │     │ Auto-creates    │
│                 │     │                 │     │ user profile    │
└─────────────────┘     └─────────────────┘     └─────────────────┘
```

### Services Deployed

| Service | Port | Bounded Context | Description |
|---------|------|-----------------|-------------|
| identity-service | 3000 | Authentication | Sign-up, sign-in, JWT tokens |
| user-service | 3001 | User Profile | Profile management, preferences |
| blog-service | 3002 | Content | Blog posts, publishing |
| Frontend (Next.js) | 3003 | - | React SPA with auth |

---

## Architecture

### Directory Structure

```
microservices-platform/
├── libs/
│   └── kafka/                    # Shared Kafka library
│       ├── src/
│       │   ├── kafka.module.ts   # NestJS dynamic module
│       │   ├── config/           # Kafka configuration
│       │   ├── producer/         # Producer service
│       │   ├── consumer/         # Consumer service & routing
│       │   └── events/           # Event types & constants
│       ├── dist/                 # Compiled output
│       └── package.json          # @platform/kafka package
├── services/
│   ├── identity-service/         # Auth bounded context
│   │   ├── src/
│   │   │   ├── domain/           # Entities, value objects
│   │   │   ├── application/      # Use cases, DTOs
│   │   │   └── infrastructure/   # Controllers, events, DB
│   │   └── Dockerfile
│   ├── user-service/             # Profile bounded context
│   └── blog-service/             # Content bounded context
├── operator/
│   ├── config/
│   │   ├── crd/                  # Custom Resource Definitions
│   │   └── rbac/                 # RBAC permissions
│   ├── roles/
│   │   ├── identityservice/      # Ansible role for identity
│   │   ├── userservice/          # Ansible role for user
│   │   └── blogservice/          # Ansible role for blog
│   └── watches.yaml              # CR to role mappings
└── docs/
    └── kafka-ddd-event-driven-implementation.md  # This file
```

---

## Prerequisites

- Minikube or Kubernetes cluster running
- kubectl configured
- Docker installed
- Node.js 18+

```bash
# Verify minikube is running
minikube status

# Set docker to use minikube's docker daemon
eval $(minikube docker-env)
```

---

## Part 1: Strimzi Kafka Installation

### Step 1.1: Create Kafka Namespace

```bash
kubectl create namespace kafka
```

### Step 1.2: Install Strimzi Operator

Strimzi is a CNCF project that provides Kubernetes operators for running Apache Kafka.

```bash
# Install the latest Strimzi operator (v0.44+)
kubectl apply -f 'https://strimzi.io/install/latest?namespace=kafka' -n kafka

# Wait for the operator to be ready
kubectl wait deployment/strimzi-cluster-operator -n kafka --for=condition=Available --timeout=300s
```

### Step 1.3: Deploy Kafka Cluster (KRaft Mode)

We use KRaft mode (Kafka Raft) which eliminates the need for ZooKeeper. This is the recommended approach for Kafka 3.5+.

Create the Kafka cluster manifest:

```yaml
# kafka-cluster.yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  name: dual-role
  namespace: kafka
  labels:
    strimzi.io/cluster: my-cluster
spec:
  replicas: 1
  roles:
    - controller
    - broker
  storage:
    type: ephemeral  # Use persistent for production
---
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: my-cluster
  namespace: kafka
  annotations:
    strimzi.io/node-pools: enabled
    strimzi.io/kraft: enabled
spec:
  kafka:
    version: 3.8.0
    metadataVersion: "3.8"
    listeners:
      - name: plain
        port: 9092
        type: internal
        tls: false
      - name: tls
        port: 9093
        type: internal
        tls: true
    config:
      offsets.topic.replication.factor: 1
      transaction.state.log.replication.factor: 1
      transaction.state.log.min.isr: 1
      default.replication.factor: 1
      min.insync.replicas: 1
  entityOperator:
    topicOperator: {}
    userOperator: {}
```

Apply it:

```bash
kubectl apply -f kafka-cluster.yaml

# Wait for Kafka to be ready (this takes 2-3 minutes)
kubectl wait kafka/my-cluster -n kafka --for=condition=Ready --timeout=300s
```

### Step 1.4: Verify Kafka Installation

```bash
# Check all Kafka resources
kubectl get kafka,kafkanodepool,pods -n kafka

# Expected output:
# NAME                              READY
# kafka.kafka.strimzi.io/my-cluster  True
#
# NAME                                           DESIRED   ROLES
# kafkanodepool.kafka.strimzi.io/dual-role       1         ["controller","broker"]
#
# PODS:
# my-cluster-dual-role-0        1/1  Running
# my-cluster-entity-operator-*  2/2  Running
# strimzi-cluster-operator-*    1/1  Running
```

**Kafka Bootstrap Server:** `my-cluster-kafka-bootstrap.kafka:9092`

---

## Part 2: Kafka Topics Configuration

### Step 2.1: Create Event Topics

Create topics for each bounded context:

```yaml
# kafka-topics.yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: identity-events
  namespace: kafka
  labels:
    strimzi.io/cluster: my-cluster
spec:
  topicName: identity.events
  partitions: 3
  replicas: 1
  config:
    retention.ms: "604800000"  # 7 days
---
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: user-events
  namespace: kafka
  labels:
    strimzi.io/cluster: my-cluster
spec:
  topicName: user.events
  partitions: 3
  replicas: 1
---
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: blog-events
  namespace: kafka
  labels:
    strimzi.io/cluster: my-cluster
spec:
  topicName: blog.events
  partitions: 3
  replicas: 1
---
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: platform-dlq
  namespace: kafka
  labels:
    strimzi.io/cluster: my-cluster
spec:
  topicName: platform-dlq
  partitions: 1
  replicas: 1
  config:
    retention.ms: "2592000000"  # 30 days for DLQ
```

Apply topics:

```bash
kubectl apply -f kafka-topics.yaml

# Verify topics
kubectl get kafkatopics -n kafka
```

---

## Part 3: Shared Kafka Library (@platform/kafka)

### Step 3.1: Library Structure

The `libs/kafka` directory contains a shared NestJS library for Kafka integration:

```
libs/kafka/
├── src/
│   ├── index.ts                    # Public exports
│   ├── kafka.module.ts             # NestJS dynamic module
│   ├── config/
│   │   └── kafka.config.ts         # Configuration service
│   ├── events/
│   │   └── event-types.ts          # Event constants & interfaces
│   ├── producer/
│   │   └── kafka-producer.service.ts
│   └── consumer/
│       ├── kafka-consumer.service.ts
│       ├── event-routing.config.ts  # Config-driven routing
│       └── event-use-case.registry.ts
├── package.json
└── tsconfig.json
```

### Step 3.2: Key Constants

**libs/kafka/src/events/event-types.ts:**

```typescript
// Topic names
export const TOPICS = {
  IDENTITY_EVENTS: 'identity.events',
  USER_EVENTS: 'user.events',
  BLOG_EVENTS: 'blog.events',
  DLQ: 'platform-dlq',
};

// Event type constants
export const IDENTITY_EVENTS = {
  CREATED: 'identity.created',
  UPDATED: 'identity.updated',
  SIGNED_IN: 'identity.signed_in',
  DEACTIVATED: 'identity.deactivated',
};

export const USER_EVENTS = {
  PROFILE_CREATED: 'profile.created',
  PROFILE_UPDATED: 'profile.updated',
};
```

### Step 3.3: Event Envelope Interface

```typescript
export interface EventEnvelope<T = unknown> {
  eventId: string;
  eventType: string;
  occurredAt: string;
  version: number;
  source: string;
  correlationId?: string;
  payload: T;
}
```

### Step 3.4: Building the Library

```bash
cd libs/kafka
npm install
npm run build  # Outputs to dist/
```

**Important:** The compiled `dist/` folder is copied into service Docker images.

---

## Part 4: NestJS Service Integration

### Step 4.1: Identity Service - Event Publisher

The identity-service publishes events when users sign up:

**services/identity-service/src/infrastructure/events/identity-events.publisher.ts:**

```typescript
@Injectable()
export class IdentityEventsPublisher implements OnModuleInit, OnModuleDestroy {
  private kafka: Kafka | null = null;
  private producer: Producer | null = null;
  private readonly kafkaEnabled: boolean;
  private readonly brokers: string[];
  private readonly topic: string;

  constructor(
    private readonly configService: ConfigService,
    @Optional() private readonly eventEmitter?: EventEmitter2,
  ) {
    this.kafkaEnabled = configService.get<string>('KAFKA_ENABLED', 'false') === 'true';
    this.brokers = configService.get<string>('KAFKA_BROKERS', 'localhost:9092').split(',');
    this.topic = configService.get<string>('KAFKA_TOPIC_IDENTITY_EVENTS', 'identity.events');
  }

  async emitIdentityCreated(payload: IdentityCreatedPayload): Promise<void> {
    const envelope = createEventEnvelope(
      IDENTITY_EVENTS.CREATED,
      'identity-service',
      payload,
    );

    // Emit locally via EventEmitter2
    if (this.eventEmitter) {
      this.eventEmitter.emit(IDENTITY_EVENTS.CREATED, envelope);
      this.logger.debug(`Emitted local event: ${IDENTITY_EVENTS.CREATED}`);
    }

    // Publish to Kafka
    if (this.kafkaEnabled && this.producer) {
      await this.producer.send({
        topic: this.topic,
        messages: [{
          key: payload.identityId,
          value: JSON.stringify(envelope),
          headers: {
            eventType: IDENTITY_EVENTS.CREATED,
            eventId: envelope.eventId,
          },
        }],
      });
      this.logger.debug(`Published to Kafka: ${IDENTITY_EVENTS.CREATED}`);
    }
  }
}
```

### Step 4.2: User Service - Event Consumer

The user-service consumes `identity.created` events:

**services/user-service/src/infrastructure/events/handlers/identity-created.handler.ts:**

```typescript
@Injectable()
export class IdentityCreatedHandler implements EventUseCase<KafkaIdentityCreatedPayload> {
  constructor(private readonly createProfileUseCase: CreateProfileUseCase) {}

  /**
   * Handle events via Kafka (implements EventUseCase interface)
   */
  async execute(payload: KafkaIdentityCreatedPayload, metadata?: EventMetadata): Promise<void> {
    this.logger.log(`[Kafka] Received identity.created event [${metadata?.eventId}]`);
    
    const { identityId, email } = payload;
    await this.createProfile(identityId, email);
  }

  /**
   * Handle events via EventEmitter2 (for local dev/testing)
   */
  @OnEvent(IDENTITY_EVENTS.CREATED, { async: true })
  async handle(event: IdentityCreatedEventPayload): Promise<void> {
    this.logger.log(`[EventEmitter] Received identity.created event`);
    await this.createProfile(event.payload.identityId, event.payload.email);
  }

  private async createProfile(identityId: string, email: string): Promise<void> {
    const displayName = email.split('@')[0];
    const profile = await this.createProfileUseCase.execute({
      identityId,
      displayName,
    });
    this.logger.log(`Profile created: ${profile.id}`);
  }
}
```

### Step 4.3: Events Module Registration

**services/user-service/src/infrastructure/events/events.module.ts:**

```typescript
@Module({
  imports: [
    EventEmitterModule.forRoot({ wildcard: false, delimiter: '.' }),
    KafkaModule.forConsumer(),
    PersistenceModule,
  ],
  providers: [
    IdentityCreatedHandler,
    CreateProfileUseCase,
  ],
})
export class EventsModule implements OnModuleInit {
  constructor(
    private readonly registry: EventUseCaseRegistry,
    private readonly identityCreatedHandler: IdentityCreatedHandler,
  ) {}

  onModuleInit(): void {
    // Register handler with registry (must match KAFKA_EVENT_HANDLERS config)
    this.registry.register('CreateProfileUseCase', this.identityCreatedHandler);
  }
}
```

---

## Part 5: Docker Build Configuration

### Step 5.1: The Challenge

Services depend on `@platform/kafka` via `file:../../libs/kafka` in package.json. This creates challenges:
1. Build context must include the libs folder
2. Module resolution needs NODE_PATH configuration
3. Different services have different tsconfig output paths

### Step 5.2: Dockerfile Pattern (Identity Service)

```dockerfile
# Build from microservices-platform root:
# docker build -f services/identity-service/Dockerfile -t identity-service:v1.0.0 .

FROM node:18-alpine AS builder

WORKDIR /workspace

# Copy the shared kafka library (dist + package.json only)
COPY libs/kafka/package.json ./libs/kafka/
COPY libs/kafka/dist ./libs/kafka/dist

# Copy service package files
COPY services/identity-service/package*.json ./services/identity-service/

# Install dependencies
WORKDIR /workspace/services/identity-service
RUN npm install --legacy-peer-deps

# Copy source and build
COPY services/identity-service/. .
RUN npm run build

# Production stage
FROM node:18-alpine AS production

WORKDIR /workspace

# Copy kafka library
COPY libs/kafka/package.json ./libs/kafka/
COPY libs/kafka/dist ./libs/kafka/dist

# Copy service files
COPY services/identity-service/package*.json ./services/identity-service/

WORKDIR /workspace/services/identity-service
RUN npm install --omit=dev --legacy-peer-deps

# Copy built files
COPY --from=builder /workspace/services/identity-service/dist ./dist

# CRITICAL: NODE_PATH allows runtime module resolution for @platform/kafka
ENV NODE_ENV=production
ENV PORT=3000
ENV NODE_PATH=/workspace/services/identity-service/node_modules

EXPOSE 3000

# NOTE: identity-service outputs to dist/src/main.js (check tsconfig!)
CMD ["node", "dist/src/main.js"]
```

### Step 5.3: Key Differences Between Services

| Service | tsconfig outDir | CMD Path |
|---------|-----------------|----------|
| identity-service | dist/src | `node dist/src/main.js` |
| user-service | dist | `node dist/main.js` |
| blog-service | dist | `node dist/main.js` |

**Lesson Learned:** Always check `tsconfig.json` to determine the correct main.js path!

### Step 5.4: Building Images

```bash
cd /path/to/microservices-platform

# IMPORTANT: Use minikube's docker daemon
eval $(minikube docker-env)

# Build all services (from microservices-platform root!)
docker build -f services/identity-service/Dockerfile -t identity-service:v1.0.5 .
docker build -f services/user-service/Dockerfile -t user-service:v1.0.4 .
docker build -f services/blog-service/Dockerfile -t blog-service:v1.0.5 .
```

---

## Part 6: Kubernetes Operator Updates

### Step 6.1: RBAC Permissions

The operator needs permissions for the new CRDs and Strimzi resources:

**operator/config/rbac/role.yaml (additions):**

```yaml
  ##
  ## Rules for apps.example.com/v1alpha1, Kind: IdentityService
  ##
  - apiGroups:
      - apps.example.com
    resources:
      - identityservices
      - identityservices/status
      - identityservices/finalizers
    verbs:
      - create
      - delete
      - get
      - list
      - patch
      - update
      - watch
  ##
  ## Rules for apps.example.com/v1alpha1, Kind: UserService
  ##
  - apiGroups:
      - apps.example.com
    resources:
      - userservices
      - userservices/status
      - userservices/finalizers
    verbs:
      - create
      - delete
      - get
      - list
      - patch
      - update
      - watch
  ##
  ## Rules for apps.example.com/v1alpha1, Kind: BlogService
  ##
  - apiGroups:
      - apps.example.com
    resources:
      - blogservices
      - blogservices/status
      - blogservices/finalizers
    verbs:
      - create
      - delete
      - get
      - list
      - patch
      - update
      - watch
  ##
  ## Rules for Strimzi Kafka resources
  ##
  - apiGroups:
      - kafka.strimzi.io
    resources:
      - kafkas
      - kafkatopics
      - kafkausers
      - kafkaconnects
      - kafkanodepools
    verbs:
      - create
      - delete
      - get
      - list
      - patch
      - update
      - watch
```

### Step 6.2: ConfigMap Templates with Kafka

**operator/roles/userservice/templates/user-configmap.yml.j2:**

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: "{{ serviceName }}-config"
  namespace: "{{ ansible_operator_meta.namespace }}"
data:
  NODE_ENV: "{{ nodeEnv | default('development') }}"
  PORT: "{{ port | default(3001) | string }}"
  DATABASE_HOST: "{{ serviceName }}-postgres"
  DATABASE_PORT: "5432"
  DATABASE_NAME: "{{ postgres.database | default('userprofile') }}"
  DATABASE_USER: "{{ postgres.user | default('userprofile') }}"
  DATABASE_PASSWORD: "{{ postgres.password | default('userprofile123') }}"
{% if kafka is defined and kafka.enabled | default(false) %}
  KAFKA_ENABLED: "true"
  KAFKA_BROKERS: "{{ kafka.brokers | join(',') }}"
  KAFKA_CLIENT_ID: "{{ kafka.clientId | default('user-service') }}"
  KAFKA_CONSUMER_GROUP_ID: "{{ kafka.consumerGroupId | default('user-consumer-group') }}"
{% if kafka.topics is defined %}
  KAFKA_TOPIC_IDENTITY_EVENTS: "{{ kafka.topics.identityEvents | default('identity.events') }}"
  KAFKA_TOPIC_USER_EVENTS: "{{ kafka.topics.userEvents | default('user.events') }}"
{% endif %}
{% if kafka.eventHandlers is defined %}
  KAFKA_EVENT_HANDLERS: '{{ kafka.eventHandlers | replace("\n", "") | trim }}'
{% endif %}
{% else %}
  KAFKA_ENABLED: "false"
{% endif %}
```

### Step 6.3: Custom Resource with Kafka Configuration

**config/samples/userservice-sample.yaml:**

```yaml
apiVersion: apps.example.com/v1alpha1
kind: UserService
metadata:
  name: userprofile
  namespace: default
spec:
  serviceName: user-service
  image: user-service:v1.0.4
  replicas: 1
  port: 3001
  nodePort: 30084
  serviceType: NodePort
  postgres:
    enabled: true
    image: postgres:15-alpine
    database: userprofile
    user: userprofile
    password: userprofile123
    storageSize: 1Gi
  kafka:
    enabled: true
    brokers:
      - my-cluster-kafka-bootstrap.kafka:9092
    clientId: user-service
    consumerGroupId: user-consumer-group
    topics:
      identityEvents: identity.events
      userEvents: user.events
    eventHandlers: '{"identity.events":{"identity.created":"CreateProfileUseCase"}}'
```

**Critical:** The `eventHandlers` JSON tells the consumer which topics to subscribe to and which use case handles each event type.

### Step 6.4: Rebuilding and Deploying the Operator

```bash
cd operator

# Build operator image
eval $(minikube docker-env)
docker build -t platform-operator:v1.0.3 .

# Update operator deployment
kubectl set image deployment/webapp-operator-controller-manager \
  -n webapp-operator-system \
  manager=platform-operator:v1.0.3

# Wait for rollout
kubectl rollout status deployment/webapp-operator-controller-manager \
  -n webapp-operator-system --timeout=60s
```

---

## Part 7: Testing the Event Flow

### Step 7.1: Port Forwarding

```bash
# Terminal 1: Identity Service
kubectl port-forward svc/identity-service 3000:3000 -n default &

# Terminal 2: User Service
kubectl port-forward svc/user-service 3001:3001 -n default &

# Terminal 3: Blog Service
kubectl port-forward svc/blog-service 3002:3002 -n default &
```

### Step 7.2: Health Checks

```bash
# Verify all services are healthy
curl http://localhost:3000/identity/health
# {"status":"ok","service":"identity-service"}

curl http://localhost:3001/profiles/health
# {"status":"ok","service":"user-service"}

curl http://localhost:3002/api/v1/health
# {"status":"ok","service":"blog-service"}
```

### Step 7.3: Test Sign-Up Flow

```bash
# 1. Sign up a new user
curl -X POST http://localhost:3000/identity/sign-up \
  -H "Content-Type: application/json" \
  -d '{"email": "test@example.com", "password": "Test123!@#"}'

# Response:
# {"identityId":"c55b0082-e7a3-4567-a2d2-5e4ad9b44607","email":"test@example.com"}
```

### Step 7.4: Verify Kafka Event Published

```bash
kubectl logs deployment/identity-service-deployment -n default --tail=20 | grep -i "kafka\|event"

# Expected output:
# [IdentityEventsPublisher] Emitted local event: identity.created [event-id]
# [IdentityEventsPublisher] Published to Kafka: identity.created on identity.events
# [SignUpUseCase] Published identity.created event for test@example.com
```

### Step 7.5: Verify Event Consumed by User Service

```bash
kubectl logs deployment/user-service-deployment -n default --tail=20 | grep -i "kafka\|event\|profile"

# Expected output:
# [IdentityCreatedHandler] [Kafka] Received identity.created event [event-id]
# [CreateProfileUseCase] Profile created successfully for identity c55b...: profile 55606...
# [KafkaConsumerService] Handled identity.created with CreateProfileUseCase
```

### Step 7.6: Verify Profile Was Created

```bash
# Use the identityId from sign-up response
curl http://localhost:3001/profiles/identity/c55b0082-e7a3-4567-a2d2-5e4ad9b44607 | jq .

# Response:
# {
#   "id": "55606a58-a76e-4839-ab85-a36935b609af",
#   "identityId": "c55b0082-e7a3-4567-a2d2-5e4ad9b44607",
#   "displayName": "test",
#   "firstName": null,
#   "lastName": null,
#   "avatarUrl": null,
#   "bio": null,
#   "preferences": {}
# }
```

### Step 7.7: Test Sign-In

```bash
curl -X POST http://localhost:3000/identity/sign-in \
  -H "Content-Type: application/json" \
  -d '{"email": "test@example.com", "password": "Test123!@#"}' | jq .

# Response:
# {
#   "message": "Sign-in successful",
#   "identityId": "c55b0082-e7a3-4567-a2d2-5e4ad9b44607",
#   "accessToken": "eyJhbGciOiJIUzI1NiIs...",
#   "refreshToken": "eyJhbGciOiJIUzI1NiIs..."
# }
```

---

## Part 8: Frontend Integration

### Step 8.1: API Service Layer

**Nest-auth/frontend/next-auth/app/lib/api.ts:**

```typescript
const IDENTITY_SERVICE_URL = process.env.NEXT_PUBLIC_IDENTITY_SERVICE_URL || 'http://localhost:3000';
const USER_SERVICE_URL = process.env.NEXT_PUBLIC_USER_SERVICE_URL || 'http://localhost:3001';
const BLOG_SERVICE_URL = process.env.NEXT_PUBLIC_BLOG_SERVICE_URL || 'http://localhost:3002';

// Profile API
export async function getProfileByIdentityId(identityId: string): Promise<Profile> {
  const response = await fetch(`${USER_SERVICE_URL}/profiles/identity/${identityId}`, {
    headers: getAuthHeaders(),
  });
  if (!response.ok) throw new Error('Profile not found');
  return response.json();
}

// Auth helpers
function getAuthHeaders(): HeadersInit {
  if (typeof window === 'undefined') return {};
  const token = localStorage.getItem('accessToken');
  return token ? { Authorization: `Bearer ${token}` } : {};
}
```

### Step 8.2: Auth Context

**Nest-auth/frontend/next-auth/app/lib/auth-context.tsx:**

```typescript
export function AuthProvider({ children }: { children: ReactNode }) {
  const [state, setState] = useState<AuthState>({
    isAuthenticated: false,
    isLoading: true,
    identityId: null,
    email: null,
    profile: null,
    accessToken: null,
  });

  // Check for existing tokens on mount
  useEffect(() => {
    const initAuth = async () => {
      const token = localStorage.getItem('accessToken');
      if (token) {
        const decoded = jwtDecode<JwtPayload>(token);
        if (decoded.exp * 1000 > Date.now()) {
          // Token valid - fetch profile
          const profile = await getProfileByIdentityId(decoded.sub);
          setState({
            isAuthenticated: true,
            isLoading: false,
            identityId: decoded.sub,
            email: decoded.email,
            profile,
            accessToken: token,
          });
        }
      }
    };
    initAuth();
  }, []);

  // ... login, logout, refreshProfile methods
}
```

### Step 8.3: Sign-Up Action (Server Action)

**Nest-auth/frontend/next-auth/app/(auth)/sign-up/actions.tsx:**

```typescript
'use server'

const IDENTITY_SERVICE_URL = process.env.IDENTITY_SERVICE_URL || 'http://localhost:3000';

export const signUpAndSignInAction = async (email: string, password: string) => {
  // Sign up
  const signUpResponse = await fetch(`${IDENTITY_SERVICE_URL}/identity/sign-up`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password }),
  });

  if (!signUpResponse.ok) {
    const error = await signUpResponse.json();
    throw new Error(error.message || 'Failed to sign up');
  }

  // Sign in to get tokens
  const signInResponse = await fetch(`${IDENTITY_SERVICE_URL}/identity/sign-in`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password }),
  });

  if (!signInResponse.ok) {
    throw new Error('Failed to sign in after signup');
  }

  return signInResponse.json();
};
```

### Step 8.4: Running the Frontend

```bash
cd Nest-auth/frontend/next-auth

# Install dependencies
npm install --legacy-peer-deps

# Run on port 3003 (to avoid conflicts with identity-service on 3000)
PORT=3003 npm run dev
```

Access the frontend at: http://localhost:3003

---

## Troubleshooting Guide

### Issue 1: Module not found - @nestjs/common (in @platform/kafka)

**Symptom:**
```
Error: Cannot find module '@nestjs/common'
Require stack:
- /workspace/.../node_modules/@platform/kafka/dist/...
```

**Root Cause:** Node.js can't resolve dependencies from the kafka library's location.

**Solution:** Add `NODE_PATH` to Dockerfile:
```dockerfile
ENV NODE_PATH=/workspace/services/identity-service/node_modules
```

---

### Issue 2: Cannot find module './main.js'

**Symptom:**
```
Error: Cannot find module '/workspace/services/identity-service/dist/main.js'
```

**Root Cause:** Different tsconfig.json output paths between services.

**Solution:** Check the actual tsconfig.json:
```bash
# identity-service uses:
CMD ["node", "dist/src/main.js"]

# user-service/blog-service use:
CMD ["node", "dist/main.js"]
```

---

### Issue 3: No topics configured for consumption

**Symptom:**
```
[KafkaConsumerService] No topics configured for consumption
```

**Root Cause:** Missing `KAFKA_EVENT_HANDLERS` environment variable.

**Solution:** 
1. Add to ConfigMap: `KAFKA_EVENT_HANDLERS: '{"identity.events":{"identity.created":"CreateProfileUseCase"}}'`
2. Restart the pod to pick up new config

---

### Issue 4: Operator Forbidden errors

**Symptom:**
```
failed to list *v1alpha1.BlogService: blogservices.apps.example.com is forbidden
```

**Root Cause:** Operator RBAC missing permissions for new CRDs.

**Solution:** Add rules to `operator/config/rbac/role.yaml` and redeploy.

---

### Issue 5: Kafka consumer not receiving messages

**Symptom:** Events published but not consumed.

**Root Cause:** Consumer joined group after message was published; no partition assignment.

**Solution:** 
1. Check logs for `memberAssignment` - should show topic partitions
2. Wait for rebalance to complete, then send another event
3. Events sent before partition assignment will be consumed from last committed offset

---

### Issue 6: Docker build fails with "file:../../libs/kafka not found"

**Root Cause:** Building from wrong directory.

**Solution:** Always build from `microservices-platform` root:
```bash
cd microservices-platform
docker build -f services/identity-service/Dockerfile -t identity-service:v1.0.0 .
```

---

## Lessons Learned

### 1. Shared Library Distribution
- Compile shared libraries before building service images
- Copy only `dist/` and `package.json` to keep images small
- Use `NODE_PATH` for runtime module resolution

### 2. Event-Driven Design Patterns
- Use config-driven routing (`KAFKA_EVENT_HANDLERS`) for flexibility
- Implement both EventEmitter2 (local) and Kafka (distributed) for dual-mode operation
- Always include event metadata (eventId, occurredAt, correlationId)

### 3. Operator Development
- Test operator locally with `ansible-playbook` before containerizing
- Use `from_yaml` filter in templates to validate YAML
- Watch for template rendering issues with multiline strings

### 4. Kafka on Kubernetes
- KRaft mode (no ZooKeeper) simplifies deployment
- Use ephemeral storage for dev, persistent for production
- Set realistic `replicas` for dev (1) vs production (3+)

### 5. Container Debugging
- `kubectl exec` to inspect running containers
- Check actual `dist/` structure: `kubectl exec pod -- ls -la dist/`
- Verify environment variables are applied correctly

### 6. Frontend-Backend Integration
- Use environment variables for service URLs (not hardcoded localhost)
- Handle JWT in HTTP-only cookies (SSR) or localStorage (SPA)
- Implement proper error handling for failed API calls

---

## Quick Reference Commands

```bash
# Kafka
kubectl get kafka,kafkatopic -n kafka
kubectl logs -n kafka -l strimzi.io/name=my-cluster-kafka

# Services
kubectl get pods -n default -l app=identity-service
kubectl logs deployment/identity-service-deployment --tail=50

# Operator
kubectl logs deployment/webapp-operator-controller-manager -n webapp-operator-system --tail=50

# Port forwarding
kubectl port-forward svc/identity-service 3000:3000 &
kubectl port-forward svc/user-service 3001:3001 &
kubectl port-forward svc/blog-service 3002:3002 &

# Testing
curl -X POST http://localhost:3000/identity/sign-up -H "Content-Type: application/json" -d '{"email":"test@example.com","password":"Test123!"}'
curl http://localhost:3001/profiles/identity/{identityId}

# Rebuilding
eval $(minikube docker-env)
docker build -f services/identity-service/Dockerfile -t identity-service:v1.0.5 .
kubectl patch identityservice identity -n default --type=merge -p '{"spec":{"image":"identity-service:v1.0.5"}}'
```

---

## Summary

This implementation demonstrates a production-ready pattern for event-driven microservices:

1. **Strimzi Kafka** provides managed Kafka on Kubernetes with declarative configuration
2. **Shared @platform/kafka library** ensures consistent event handling across services
3. **Config-driven routing** enables flexible event subscription without code changes
4. **Ansible Operator** provides GitOps-friendly declarative deployment
5. **NestJS services** implement clean DDD architecture with proper separation of concerns

The key insight is that cross-service communication via events enables true bounded context independence - the identity-service knows nothing about user profiles, yet profile creation happens automatically through the event bus.

---

*Document created: December 30, 2025*
*Platform: Minikube on macOS with Docker driver*
*Kafka: Strimzi 0.44+ with KRaft mode*
