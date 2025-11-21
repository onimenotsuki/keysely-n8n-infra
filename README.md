# n8n AWS Infrastructure

AWS CDK infrastructure for deploying n8n (workflow automation platform) on EC2 using Docker Compose, PostgreSQL, and Traefik with automatic SSL/TLS certificates.

## Features

- 🚀 **Free Tier Compatible**: Uses t3.micro EC2 instance (750 hours/month free)
- 🔒 **Automatic SSL**: Traefik with Let's Encrypt for HTTPS
- 🐳 **Docker Compose**: Easy service management with n8n, PostgreSQL, and Traefik
- 🔄 **CI/CD Pipeline**: Automated deployment via GitHub Actions
- 📊 **PostgreSQL Backend**: Robust database for n8n workflows
- 🛡️ **Security Best Practices**: IAM roles, security groups, and secrets management

## Prerequisites

- Node.js 22.x
- AWS CLI configured with appropriate credentials
- AWS CDK CLI installed (`npm install -g aws-cdk`)
- GitHub repository with OIDC configured for AWS
- Domain name with DNS management access (Netlify)

## Quick Start

### 1. Clone and Install

```bash
git clone https://github.com/onimenotsuki/keysely-n8n-infra.git
cd keysely-n8n-infra
npm install
```

### 2. Configure GitHub Secrets

Add the following secrets to your GitHub repository:

- `AWS_ROLE_ARN`: ARN of the IAM role for GitHub Actions (e.g., `arn:aws:iam::123456789012:role/github-actions-deploy-role`)
- `AWS_ACCOUNT_ID`: Your AWS account ID

### 3. Bootstrap CDK (First Time Only)

```bash
cdk bootstrap aws://YOUR_ACCOUNT_ID/us-west-2
```

### 4. Deploy Infrastructure

#### Option A: Manual Deployment

```bash
# Synthesize CloudFormation template
npm run build
cdk synth

# Deploy stack
cdk deploy
```

#### Option B: Automated Deployment (Recommended)

Push to the `main` branch. The GitHub Actions workflow will automatically:
1. Run linting and tests
2. Synthesize CDK stack
3. Deploy to AWS
4. Output deployment information

### 5. Configure DNS

After deployment, you'll receive an Elastic IP address. Configure DNS in Netlify:

1. Go to your Netlify DNS settings
2. Add an A record:
   - **Name**: `n8n`
   - **Value**: `<Elastic IP from stack output>`
   - **TTL**: 3600 (or default)

3. Wait for DNS propagation (usually 5-15 minutes)

### 6. Access n8n

Once DNS has propagated and Traefik has obtained the SSL certificate:
- Navigate to: `https://n8n.keysely.com`
- Default credentials are generated and stored in `/opt/n8n/docker/.env` on the EC2 instance

## Project Structure

```
keysely-n8n-infra/
├── .github/
│   └── workflows/
│       └── infra.yml          # CI/CD pipeline
├── bin/
│   └── app.ts                 # CDK app entry point
├── lib/
│   └── stacks/
│       └── n8n-stack.ts       # Main infrastructure stack
├── scripts/
│   └── user-data.sh           # EC2 initialization script
├── docker/
│   ├── docker-compose.yml     # n8n + PostgreSQL + Traefik
│   └── .env.example           # Environment variables template
├── test/
│   └── n8n-stack.test.ts      # Jest test suite
├── .husky/                    # Git hooks
├── .eslintrc.js               # ESLint configuration
├── .prettierrc                # Prettier configuration
├── jest.config.js             # Jest configuration
├── tsconfig.json              # TypeScript configuration
├── cdk.json                   # CDK configuration
├── package.json               # Dependencies
├── AGENTS.md                  # Agent instructions
└── README.md                  # This file
```

## Infrastructure Components

### AWS Resources

- **EC2 Instance**: t3.micro (free tier eligible)
- **Elastic IP**: Reserved static IP address
- **Security Groups**: 
  - HTTP (80) and HTTPS (443) from internet
  - SSH (22) from specified CIDR
- **IAM Role**: Minimal permissions for EC2 instance
- **VPC**: Default VPC (no additional cost)

### Docker Services

- **n8n**: Latest n8n image with PostgreSQL backend
- **PostgreSQL**: PostgreSQL 15 Alpine for data persistence
- **Traefik**: Reverse proxy with Let's Encrypt SSL

## Configuration

### Stack Properties

You can customize the stack by modifying `bin/app.ts`:

```typescript
new N8nStack(app, 'N8nStack', {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: 'us-west-2',
  },
  domainName: 'n8n.keysely.com',        // Your domain
  instanceType: ec2.InstanceType.of(    // Instance type
    ec2.InstanceClass.T3,
    ec2.InstanceSize.MICRO
  ),
  allowedSSHCidr: 'YOUR_IP/32',         // Restrict SSH access
});
```

### Environment Variables

The Docker Compose setup uses environment variables stored in `/opt/n8n/docker/.env` on the EC2 instance. These are automatically generated during instance initialization.

To update credentials, SSH into the instance and edit `/opt/n8n/docker/.env`, then restart services:

```bash
ssh ec2-user@<elastic-ip>
cd /opt/n8n/docker
docker-compose down
docker-compose up -d
```

## Development

### Code Quality

```bash
# Run linter
npm run lint

# Fix linting issues
npm run lint:fix

# Check code formatting
npm run format:check

# Format code
npm run format
```

### Testing

```bash
# Run all tests
npm test

# Run tests in watch mode
npm test -- --watch

# Run tests with coverage
npm test -- --coverage
```

### Git Hooks

Husky is configured with pre-commit and pre-push hooks:
- **Pre-commit**: Runs linter and format check
- **Pre-push**: Runs test suite

## CI/CD Pipeline

The GitHub Actions workflow (`.github/workflows/infra.yml`) automatically:

1. Checks out code
2. Sets up Node.js 22
3. Installs dependencies
4. Runs linter and format checks
5. Runs test suite
6. Configures AWS credentials via OIDC
7. Bootstraps CDK (if needed)
8. Synthesizes and deploys stack
9. Outputs deployment summary

### OIDC Configuration

The pipeline uses OIDC for AWS authentication. Ensure your IAM role (`github-actions-deploy-role`) has:

- Trust relationship with GitHub OIDC provider
- Permissions to create/update CloudFormation stacks
- Permissions to create/update EC2 resources

## Monitoring and Maintenance

### Accessing the Instance

```bash
# SSH into the instance
ssh -i <your-key.pem> ec2-user@<elastic-ip>

# Or use AWS Systems Manager Session Manager (no key needed)
aws ssm start-session --target <instance-id>
```

### Verifying Traefik Configuration

A health check script is automatically installed on the EC2 instance during deployment. Use it to verify Traefik is configured correctly:

```bash
# SSH into the instance
ssh -i <your-key.pem> ec2-user@<elastic-ip>

# Run the health check script
check-traefik

# Or specify a custom domain
check-traefik n8n.keysely.com
```

The script checks:
- Docker container status
- Traefik logs and configuration
- Let's Encrypt certificate status
- DNS resolution
- HTTP/HTTPS connectivity
- SSL certificate validity
- Traefik routing configuration
- Port bindings

### Checking Container Status

```bash
# Check Docker containers
docker ps

# View n8n logs
docker logs n8n

# View Traefik logs
docker logs traefik

# View PostgreSQL logs
docker logs postgres
```

### Updating Services

```bash
# SSH into instance
ssh ec2-user@<elastic-ip>

# Navigate to Docker Compose directory
cd /opt/n8n/docker

# Pull latest images
docker-compose pull

# Restart services
docker-compose up -d
```

### Backup

The PostgreSQL data is stored in a Docker volume. To backup:

```bash
# SSH into instance
ssh ec2-user@<elastic-ip>

# Create backup
docker exec postgres pg_dump -U n8n n8n > backup.sql

# Or backup the entire volume
docker run --rm -v n8n_postgres_data:/data -v $(pwd):/backup alpine tar czf /backup/postgres-backup.tar.gz /data
```

## Cost Estimation

This setup is designed to stay within AWS Free Tier:

- **EC2 t3.micro**: 750 hours/month free (sufficient for 24/7 operation)
- **Elastic IP**: Free when attached to running instance
- **EBS Storage**: 30GB gp3 free tier
- **Data Transfer**: 1GB out per month free

**Estimated Monthly Cost**: $0 (within free tier limits)

## Security Considerations

- ✅ Security groups restrict access appropriately
- ✅ IAM roles follow least privilege principle
- ✅ Secrets are managed securely
- ⚠️ **Important**: Update `allowedSSHCidr` to restrict SSH access in production
- ⚠️ **Important**: Change default n8n credentials after first login
- ⚠️ **Important**: Regularly update Docker images and system packages

## Troubleshooting

### Deployment Issues

- **CDK Bootstrap Error**: Ensure AWS credentials are configured and you have permissions
- **Stack Creation Fails**: Check CloudFormation events in AWS Console for detailed errors
- **Instance Not Starting**: Check EC2 instance logs and security group rules

### DNS and SSL Issues

- **DNS Not Resolving**: Verify A record in Netlify points to correct Elastic IP
- **SSL Certificate Fails**: Ensure port 80 is accessible (required for Let's Encrypt validation)
- **Traefik Not Starting**: Check Docker logs and ensure domain name is correctly configured

### n8n Access Issues

- **Cannot Access n8n**: Verify security groups allow HTTPS (443)
- **502 Bad Gateway**: Check if n8n container is running: `docker ps`
- **Database Connection Error**: Verify PostgreSQL container is healthy: `docker ps`

## Support

For issues and questions:
- Check [n8n documentation](https://docs.n8n.io/)
- Review [AWS CDK documentation](https://docs.aws.amazon.com/cdk/)
- Open an issue in this repository

## License

This project is licensed under the MIT License.

