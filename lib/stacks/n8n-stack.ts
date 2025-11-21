import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as iam from 'aws-cdk-lib/aws-iam';
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
    const instanceType = props?.instanceType || ec2.InstanceType.of(ec2.InstanceClass.T3, ec2.InstanceSize.MICRO);
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

    // Elastic IP
    const elasticIP = new ec2.CfnEIP(this, 'N8nElasticIP', {
      domain: 'vpc',
    });

    // IAM Role for EC2 instance
    const ec2Role = new iam.Role(this, 'N8nEC2Role', {
      assumedBy: new iam.ServicePrincipal('ec2.amazonaws.com'),
      description: 'IAM role for n8n EC2 instance',
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonSSMManagedInstanceCore'),
      ],
    });

    // Grant permissions to read SSM parameters for secrets
    ec2Role.addToPolicy(
      new iam.PolicyStatement({
        effect: iam.Effect.ALLOW,
        actions: ['ssm:GetParameter', 'ssm:GetParameters'],
        resources: [
          `arn:aws:ssm:${this.region}:${this.account}:parameter/n8n/*`,
        ],
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
      userData: ec2.UserData.custom(userData),
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
  }
}

