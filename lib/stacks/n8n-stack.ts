import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';
import { Construct } from 'constructs';
import * as fs from 'fs';
import * as path from 'path';

export interface N8nStackProps extends cdk.StackProps {
  domainName?: string;
  instanceType?: ec2.InstanceType;
  allowedSSHCidr?: string;
}

export class N8nStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: N8nStackProps) {
    super(scope, id, props);

    const domainName = props?.domainName || 'n8n.keysely.com';
    const instanceType =
      props?.instanceType || ec2.InstanceType.of(ec2.InstanceClass.T3, ec2.InstanceSize.MICRO);
    const allowedSSHCidr = props?.allowedSSHCidr || '0.0.0.0/0'; // Restrict this in production

    // Use default VPC for free tier compatibility
    // In tests, create a VPC instead of looking it up (to avoid AWS API calls)
    let vpc: ec2.IVpc;
    const useDefaultVpc = this.node.tryGetContext('useDefaultVpc');
    if (useDefaultVpc === false) {
      vpc = new ec2.Vpc(this, 'VPC', {
        maxAzs: 2,
        natGateways: 0, // Free tier: no NAT gateway
      });
    } else {
      vpc = ec2.Vpc.fromLookup(this, 'DefaultVPC', {
        isDefault: true,
      });
    }

    // Security Group for EC2 instance
    const ec2SecurityGroup = new ec2.SecurityGroup(this, 'N8nEC2SecurityGroup', {
      vpc,
      description: 'Security group for n8n EC2 instance',
      allowAllOutbound: true,
    });

    // Allow HTTP from internet
    ec2SecurityGroup.addIngressRule(
      ec2.Peer.anyIpv4(),
      ec2.Port.tcp(80),
      'Allow HTTP from internet'
    );

    // Allow HTTPS from internet
    ec2SecurityGroup.addIngressRule(
      ec2.Peer.anyIpv4(),
      ec2.Port.tcp(443),
      'Allow HTTPS from internet'
    );

    // Allow SSH from specified CIDR
    ec2SecurityGroup.addIngressRule(
      ec2.Peer.ipv4(allowedSSHCidr),
      ec2.Port.tcp(22),
      'Allow SSH from specified CIDR'
    );

    // Create EC2 Key Pair
    const keyPair = new ec2.CfnKeyPair(this, 'N8nKeyPair', {
      keyName: `n8n-keypair-${this.stackName}`,
      keyType: 'rsa',
      keyFormat: 'pem',
    });

    // Create Secrets Manager secret to store the private key
    // Use stack name in secret name to avoid conflicts when recreating stack
    const privateKeySecret = new secretsmanager.Secret(this, 'N8nPrivateKeySecret', {
      secretName: `/n8n/ec2/private-key`,
      description: 'Private key for n8n EC2 instance SSH access',
      removalPolicy: cdk.RemovalPolicy.RETAIN, // Retain secret even if stack is deleted
    });

    // Custom Resource Lambda to retrieve and store the private key
    // Note: When using CfnKeyPair with keyFormat: 'pem', the private key is available
    // immediately via the KeyMaterial attribute, but we need to wait for the KeyPair
    // to be created before we can retrieve it via API
    const keyRetrieverLambda = new lambda.Function(this, 'KeyRetrieverFunction', {
      runtime: lambda.Runtime.PYTHON_3_12,
      handler: 'index.handler',
      code: lambda.Code.fromInline(`
import boto3
import cfnresponse
import json

def handler(event, context):
    try:
        ec2 = boto3.client('ec2')
        secretsmanager = boto3.client('secretsmanager')
        
        if event['RequestType'] == 'Delete':
            cfnresponse.send(event, context, cfnresponse.SUCCESS, {})
            return
        
        key_pair_id = event['ResourceProperties']['KeyPairId']
        secret_arn = event['ResourceProperties']['SecretArn']
        
        # Get the private key using GetKeyPair API
        # This API is available when keyFormat is 'pem'
        response = ec2.get_key_pair(
            KeyPairId=key_pair_id,
            IncludePublicKey=False
        )
        private_key = response['KeyMaterial']
        
        # Store in Secrets Manager
        secretsmanager.put_secret_value(
            SecretId=secret_arn,
            SecretString=private_key
        )
        
        cfnresponse.send(event, context, cfnresponse.SUCCESS, {
            'PrivateKeySecretArn': secret_arn
        })
    except Exception as e:
        print(f"Error: {str(e)}")
        import traceback
        traceback.print_exc()
        cfnresponse.send(event, context, cfnresponse.FAILED, {})
`),
      timeout: cdk.Duration.minutes(5),
    });

    // Grant permissions to the Lambda
    keyRetrieverLambda.addToRolePolicy(
      new iam.PolicyStatement({
        effect: iam.Effect.ALLOW,
        actions: ['ec2:GetKeyPair'],
        resources: ['*'],
      })
    );

    privateKeySecret.grantWrite(keyRetrieverLambda);

    // Custom Resource to trigger the Lambda after KeyPair is created
    const keyRetriever = new cdk.CustomResource(this, 'KeyRetriever', {
      serviceToken: keyRetrieverLambda.functionArn,
      properties: {
        KeyPairId: keyPair.attrKeyPairId,
        SecretArn: privateKeySecret.secretArn,
      },
    });

    // Ensure KeyPair is created before the Custom Resource runs
    keyRetriever.node.addDependency(keyPair);

    // Elastic IP
    const elasticIP = new ec2.CfnEIP(this, 'N8nElasticIP', {
      domain: 'vpc',
    });

    // IAM Role for EC2 instance
    const ec2Role = new iam.Role(this, 'N8nEC2Role', {
      assumedBy: new iam.ServicePrincipal('ec2.amazonaws.com'),
      description: 'IAM role for n8n EC2 instance',
      managedPolicies: [iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonSSMManagedInstanceCore')],
    });

    // Grant permissions to read SSM parameters for secrets
    ec2Role.addToPolicy(
      new iam.PolicyStatement({
        effect: iam.Effect.ALLOW,
        actions: ['ssm:GetParameter', 'ssm:GetParameters'],
        resources: [`arn:aws:ssm:${this.region}:${this.account}:parameter/n8n/*`],
      })
    );

    // Read user data script
    let userDataScript = fs.readFileSync(
      path.join(__dirname, '../../scripts/user-data.sh'),
      'utf8'
    );

    // Replace DOMAIN_NAME placeholder in user data script
    // Using string replacement since CDK Fn.sub doesn't work well with heredoc
    userDataScript = userDataScript.replace(/\$\{DOMAIN_NAME\}/g, domainName);

    const userData = ec2.UserData.custom(userDataScript);

    // EC2 Instance
    const instance = new ec2.Instance(this, 'N8nInstance', {
      vpc,
      instanceType,
      machineImage: ec2.MachineImage.latestAmazonLinux2023({
        cpuType: ec2.AmazonLinuxCpuType.X86_64,
      }),
      securityGroup: ec2SecurityGroup,
      role: ec2Role,
      userData,
      keyName: keyPair.keyName,
      vpcSubnets: {
        subnetType: ec2.SubnetType.PUBLIC,
      },
    });

    // Associate Elastic IP with instance
    new ec2.CfnEIPAssociation(this, 'N8nElasticIPAssociation', {
      eip: elasticIP.ref,
      instanceId: instance.instanceId,
    });

    // Outputs
    new cdk.CfnOutput(this, 'InstanceId', {
      value: instance.instanceId,
      description: 'EC2 Instance ID',
    });

    new cdk.CfnOutput(this, 'ElasticIP', {
      value: elasticIP.ref,
      description: 'Elastic IP address for n8n instance',
    });

    new cdk.CfnOutput(this, 'PublicIP', {
      value: instance.instancePublicIp,
      description: 'Public IP address of the instance',
    });

    new cdk.CfnOutput(this, 'DomainName', {
      value: domainName,
      description: 'Domain name for n8n (configure DNS A record pointing to Elastic IP)',
    });

    new cdk.CfnOutput(this, 'SSHCommand', {
      value: `ssh -i <your-key.pem> ec2-user@${elasticIP.ref}`,
      description: 'SSH command to connect to the instance',
    });

    new cdk.CfnOutput(this, 'KeyPairName', {
      value: keyPair.keyName,
      description: 'Name of the EC2 Key Pair',
    });

    new cdk.CfnOutput(this, 'PrivateKeySecretArn', {
      value: privateKeySecret.secretArn,
      description: 'ARN of the Secrets Manager secret containing the private key',
    });

    new cdk.CfnOutput(this, 'GetPrivateKeyCommand', {
      value: `aws secretsmanager get-secret-value --secret-id ${privateKeySecret.secretArn} --query SecretString --output text > n8n-key.pem && chmod 400 n8n-key.pem`,
      description: 'Command to retrieve and save the private key from Secrets Manager',
    });

    new cdk.CfnOutput(this, 'SSMSessionCommand', {
      value: `aws ssm start-session --target ${instance.instanceId}`,
      description: 'Alternative: Connect using AWS Systems Manager Session Manager (no key needed)',
    });
  }
}
