# AGENTS.md

## Project Overview

This repository contains AWS CDK infrastructure code for deploying n8n (workflow automation platform) on EC2 using Docker Compose. The stack includes:

- EC2 instance (t3.micro, free tier eligible)
- Elastic IP reservation
- Docker Compose setup with n8n, PostgreSQL, and Traefik
- SSL/TLS certificates via Let's Encrypt
- Security groups and IAM roles
- CI/CD pipeline with GitHub Actions

## Setup Commands

- Install dependencies: `npm install`
- Build TypeScript: `npm run build`
- Watch mode: `npm run watch`
- Run CDK commands: `npm run cdk -- <command>`

## Code Style

- TypeScript strict mode enabled
- ESLint with Airbnb configuration
- Prettier for code formatting
- Single quotes, semicolons required
- 100 character line width
- 2 space indentation

## Testing Instructions

- Run all tests: `npm test`
- Run tests in watch mode: `npm test -- --watch`
- Run tests with coverage: `npm test -- --coverage`
- Tests are located in `test/` directory
- All tests must pass before committing

## Linting and Formatting

- Run linter: `npm run lint`
- Fix linting issues: `npm run lint:fix`
- Check formatting: `npm run format:check`
- Format code: `npm run format`

## Git Hooks

- Pre-commit: Runs linter and format check
- Pre-push: Runs test suite
- Hooks are managed by Husky

## CDK Development

- Synthesize CloudFormation template: `cdk synth`
- Deploy stack: `cdk deploy`
- Destroy stack: `cdk destroy`
- List stacks: `cdk list`
- Diff changes: `cdk diff`

## Infrastructure Details

- **Region**: us-west-2
- **Domain**: n8n.keysely.com
- **Instance Type**: t3.micro (free tier)
- **VPC**: Default VPC
- **Database**: PostgreSQL 15 (Docker container)
- **Reverse Proxy**: Traefik v2.11
- **SSL**: Let's Encrypt (automatic)

## Environment Variables

The stack uses AWS Systems Manager Parameter Store for secrets:
- `/n8n/postgres/user`
- `/n8n/postgres/password`
- `/n8n/postgres/database`
- `/n8n/basic-auth/user`
- `/n8n/basic-auth/password`

## Deployment

Deployment is automated via GitHub Actions workflow (`.github/workflows/infra.yml`):
- Triggered on push to `main` branch
- Uses OIDC authentication with AWS
- Requires `AWS_ROLE_ARN` and `AWS_ACCOUNT_ID` secrets in GitHub

## DNS Configuration

After deployment, configure DNS in Netlify:
1. Get Elastic IP from stack outputs
2. Create A record: `n8n.keysely.com` → Elastic IP
3. Wait for DNS propagation (5-15 minutes)
4. Traefik will automatically obtain SSL certificate

## File Structure

- `bin/app.ts` - CDK app entry point
- `lib/stacks/n8n-stack.ts` - Main infrastructure stack
- `scripts/user-data.sh` - EC2 initialization script
- `docker/docker-compose.yml` - Docker Compose configuration
- `test/` - Jest test suite
- `.github/workflows/infra.yml` - CI/CD pipeline

## Common Tasks

### Adding a new resource
1. Add resource to `lib/stacks/n8n-stack.ts`
2. Add corresponding test in `test/n8n-stack.test.ts`
3. Run tests: `npm test`
4. Run linter: `npm run lint`

### Updating Docker Compose
1. Edit `docker/docker-compose.yml`
2. Update `scripts/user-data.sh` if needed
3. Test locally with Docker Compose
4. Deploy via CDK

### Debugging
- Check CloudFormation events in AWS Console
- View EC2 instance logs: `ssh ec2-user@<elastic-ip>`
- Check Docker containers: `docker ps` and `docker logs <container>`
- View Traefik logs: `docker logs traefik`

## Security Notes

- Never commit secrets or credentials
- Use AWS Systems Manager Parameter Store for sensitive data
- Restrict SSH access in production (update `allowedSSHCidr` in stack props)
- Regularly update Docker images and system packages
- Review security group rules before production deployment

## Troubleshooting

- If CDK bootstrap fails, ensure AWS credentials are configured
- If deployment fails, check CloudFormation events in AWS Console
- If n8n is not accessible, verify DNS configuration and security groups
- If SSL certificate fails, ensure DNS is properly configured and port 80 is accessible

