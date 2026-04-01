# CLaaS AWS Deployment Guide

Deploy a CLaaS fleet on AWS EC2 using CloudFormation templates.

## Architecture

```
Internet → Nginx (HTTPS, t3.micro) → Dispatcher (t3.medium) → Workers (t3.medium spot ×N)
```

All resources in a single VPC with public subnets. Workers communicate with the dispatcher over private IPs.

## Prerequisites

- AWS CLI configured with a profile (e.g., `aws configure --profile claas`)
- SSH key pair for EC2 instances
- Docker + ECR access for building images
- Claude OAuth credentials + GitHub PAT

## Step 1: Deploy Network Stack

Creates VPC, subnets, security groups, and internet gateway.

```bash
aws cloudformation deploy \
  --profile claas \
  --region us-east-2 \
  --stack-name claas-network \
  --template-file cloudformation/hackathon26-network.yaml \
  --tags Key=Project,Value=claas \
  --capabilities CAPABILITY_NAMED_IAM
```

## Step 2: Deploy Storage Stack

Creates S3 bucket for state and ECR repository for Docker images.

```bash
aws cloudformation deploy \
  --profile claas \
  --region us-east-2 \
  --stack-name claas-storage \
  --template-file cloudformation/hackathon26-storage.yaml \
  --tags Key=Project,Value=claas
```

## Step 3: Build and Push Docker Images

### Dispatcher Image

```bash
# Login to ECR
aws ecr get-login-password --profile claas --region us-east-2 | \
  docker login --username AWS --password-stdin <account-id>.dkr.ecr.us-east-2.amazonaws.com

# Build dispatcher
docker build -t claas-dispatcher -f cloudformation/Dockerfile.dispatcher .

# Tag and push
docker tag claas-dispatcher:latest <account-id>.dkr.ecr.us-east-2.amazonaws.com/claas/dispatcher:latest
docker push <account-id>.dkr.ecr.us-east-2.amazonaws.com/claas/dispatcher:latest
```

### Worker (Golden) Image

```bash
docker build -t claas-worker \
  --build-arg CLAUDE_CODE_VERSION=2.1.77 \
  -f cloudformation/Dockerfile.golden .

docker tag claas-worker:latest <account-id>.dkr.ecr.us-east-2.amazonaws.com/claas/worker:latest
docker push <account-id>.dkr.ecr.us-east-2.amazonaws.com/claas/worker:latest
```

## Step 4: Store Secrets

```bash
# Claude OAuth token
aws secretsmanager create-secret \
  --profile claas --region us-east-2 \
  --name claas/claude-oauth \
  --secret-string '{"token": "sk-ant-oat01-..."}'

# GitHub token
aws secretsmanager create-secret \
  --profile claas --region us-east-2 \
  --name claas/github-token \
  --secret-string '{"token": "ghp_..."}'
```

## Step 5: Deploy Worker Stack

Launches N EC2 spot instances from the golden image.

```bash
aws cloudformation deploy \
  --profile claas \
  --region us-east-2 \
  --stack-name claas-workers \
  --template-file cloudformation/hackathon26-worker.yaml \
  --parameter-overrides \
    WorkerCount=5 \
    InstanceType=t3.medium \
    KeyName=your-ssh-key \
  --tags Key=Project,Value=claas \
  --capabilities CAPABILITY_NAMED_IAM
```

## Step 6: Deploy Nginx (HTTPS Proxy)

```bash
aws cloudformation deploy \
  --profile claas \
  --region us-east-2 \
  --stack-name claas-nginx \
  --template-file cloudformation/hackathon26-nginx.yaml \
  --parameter-overrides \
    DispatcherIP=<dispatcher-private-ip> \
  --tags Key=Project,Value=claas
```

## Step 7: Register Workers

After workers launch, register them with the dispatcher:

```bash
# Using the fleet script
bash scripts/fleet/reregister-workers.sh

# Or manually for each worker
curl -X POST http://<dispatcher-ip>:8080/worker/register \
  -H "Content-Type: application/json" \
  -d '{"worker_id": "worker-1", "ip": "<worker-private-ip>", "role": "worker"}'
```

## Step 8: Verify

```bash
# Check fleet health
curl https://<nginx-ip>/api/v1/health \
  -H "Authorization: Bearer hackathon26"

# Should show fleet_size matching your worker count
```

## Operational Scripts

All scripts are in `scripts/fleet/`:

| Script | Purpose |
|--------|---------|
| `api-submit.sh` | Submit a task via CLI |
| `api-status.sh` | Check fleet/task status |
| `claas-client.sh` | Full CLI client (submit, wait, list) |
| `claas-client.py` | Python client library |
| `reregister-workers.sh` | Re-register all workers |
| `refresh-worker-creds.sh` | Push fresh OAuth to workers |
| `fleet-heal.sh` | Self-healing monitor |
| `recover-dispatcher.sh` | Full dispatcher recovery |
| `deploy-dashboard.sh` | Deploy web dashboard |

## Cost Optimization

- **Spot instances** for workers — 60-70% savings over on-demand
- **Fleet monitor** auto-stops idle workers after configurable timeout
- **Re-registration** resets stopped workers without relaunching
- Dispatcher and nginx are on-demand (small instances, always-on)

## CloudFormation Templates

| Template | Resources |
|----------|-----------|
| `hackathon26-network.yaml` | VPC, subnets, security groups, IGW |
| `hackathon26-storage.yaml` | S3 bucket, ECR repository |
| `hackathon26-worker.yaml` | EC2 spot fleet, IAM roles, launch template |
| `hackathon26-nginx.yaml` | Nginx EC2 instance, TLS config |
| `Dockerfile.dispatcher` | Dispatcher container image |
| `Dockerfile.golden` | Worker golden image (Claude 2.1.77 pinned) |

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Workers stuck in "stopping" | Run `reregister-workers.sh` to reset state |
| Dispatcher container restarted | Run `recover-dispatcher.sh` for full recovery |
| OAuth tokens expired | Run `refresh-worker-creds.sh` to push fresh tokens |
| Worker can't create PRs | Check GitHub token in Secrets Manager |
| No idle workers | Check `api-status.sh workers` — may need to re-register |
