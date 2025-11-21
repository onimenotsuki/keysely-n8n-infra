import * as cdk from 'aws-cdk-lib';
import { Template } from 'aws-cdk-lib/assertions';
import { N8nStack } from '../lib/stacks/n8n-stack';

describe('N8nStack', () => {
  let app: cdk.App;
  let stack: N8nStack;
  let template: Template;

  beforeEach(() => {
    app = new cdk.App({
      context: {
        useDefaultVpc: false, // Use created VPC instead of lookup for tests
      },
    });
    stack = new N8nStack(app, 'TestStack', {
      env: {
        account: '123456789012',
        region: 'us-west-2',
      },
      domainName: 'n8n.keysely.com',
    });
    template = Template.fromStack(stack);
  });

  test('creates EC2 instance with correct instance type', () => {
    template.hasResourceProperties('AWS::EC2::Instance', {
      InstanceType: 't3.micro',
    });
  });

  test('creates Elastic IP', () => {
    template.resourceCountIs('AWS::EC2::EIP', 1);
  });

  test('associates Elastic IP with EC2 instance', () => {
    template.resourceCountIs('AWS::EC2::EIPAssociation', 1);
  });

  test('creates security group with correct ingress rules', () => {
    template.hasResourceProperties('AWS::EC2::SecurityGroup', {
      SecurityGroupIngress: [
        {
          IpProtocol: 'tcp',
          FromPort: 80,
          ToPort: 80,
          CidrIp: '0.0.0.0/0',
        },
        {
          IpProtocol: 'tcp',
          FromPort: 443,
          ToPort: 443,
          CidrIp: '0.0.0.0/0',
        },
        {
          IpProtocol: 'tcp',
          FromPort: 22,
          ToPort: 22,
        },
      ],
    });
  });

  test('creates VPC when useDefaultVpc is false', () => {
    template.resourceCountIs('AWS::EC2::VPC', 1);
  });

  test('creates IAM role for EC2 instance', () => {
    template.hasResourceProperties('AWS::IAM::Role', {
      AssumeRolePolicyDocument: {
        Statement: [
          {
            Action: 'sts:AssumeRole',
            Effect: 'Allow',
            Principal: {
              Service: 'ec2.amazonaws.com',
            },
          },
        ],
      },
    });
  });

  test('IAM role has SSM permissions', () => {
    template.hasResourceProperties('AWS::IAM::Policy', {
      PolicyDocument: {
        Statement: [
          {
            Effect: 'Allow',
            Action: [
              'ssm:UpdateInstanceInformation',
              'ssmmessages:CreateControlChannel',
              'ssmmessages:CreateDataChannel',
              'ssmmessages:OpenControlChannel',
              'ssmmessages:OpenDataChannel',
            ],
          },
        ],
      },
    });
  });

  test('creates required outputs', () => {
    template.hasOutput('InstanceId', {});
    template.hasOutput('ElasticIP', {});
    template.hasOutput('PublicIP', {});
    template.hasOutput('DomainName', {});
    template.hasOutput('SSHCommand', {});
  });

  test('EC2 instance uses Amazon Linux 2023', () => {
    template.hasResourceProperties('AWS::EC2::Instance', {
      ImageId: {
        'Fn::FindInMap': [
          'AWSRegion2AMI',
          {
            Ref: 'AWS::Region',
          },
          'AL2023x86_64',
        ],
      },
    });
  });

  test('security group allows all outbound traffic', () => {
    template.hasResourceProperties('AWS::EC2::SecurityGroup', {
      SecurityGroupEgress: [
        {
          IpProtocol: '-1',
          CidrIp: '0.0.0.0/0',
        },
      ],
    });
  });
});

