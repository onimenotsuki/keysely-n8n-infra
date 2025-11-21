#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { N8nStack } from '../lib/stacks/n8n-stack';

const app = new cdk.App();

new N8nStack(app, 'N8nStack', {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: process.env.CDK_DEFAULT_REGION || 'us-west-2',
  },
  description: 'n8n infrastructure stack with EC2, Docker Compose, PostgreSQL, and Traefik',
});

