#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import 'source-map-support/register';
import { N8nStack } from '../lib/stacks/n8n-stack';

const app = new cdk.App();

// Stack is registered with app via constructor side effect
// eslint-disable-next-line @typescript-eslint/no-unused-vars
const stack = new N8nStack(app, `keysely-n8n-stack-${process.env.CDK_DEFAULT_REGION}`, {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: process.env.CDK_DEFAULT_REGION || 'us-west-2',
  },
  description: 'n8n infrastructure stack with EC2, Docker Compose, PostgreSQL, and Traefik',
});
