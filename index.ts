/*!
 * Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
 * SPDX-License-Identifier: MIT-0
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy of this
 * software and associated documentation files (the "Software"), to deal in the Software
 * without restriction, including without limitation the rights to use, copy, modify,
 * merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
 * permit persons to whom the Software is furnished to do so.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 * INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
 * PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 * HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
 * OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
 * SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */

import * as cdk from '@aws-cdk/core';
import * as ec2 from '@aws-cdk/aws-ec2';
import * as ssm from '@aws-cdk/aws-ssm';
import * as iam from '@aws-cdk/aws-iam';
import * as kms from '@aws-cdk/aws-kms';
import { ManagedPolicy } from '@aws-cdk/aws-iam';
import { Tags } from '@aws-cdk/core';
const fs = require('fs');
const path = require('path');

const app = new cdk.App();
const region = app.node.tryGetContext("region")
const account = app.node.tryGetContext("account")
const vpcConfig = app.node.tryGetContext("vpc")
const ssmConfig = app.node.tryGetContext("ssm")
const installSampleData = app.node.tryGetContext("installSampleData")
const ec2Config = app.node.tryGetContext("ec2")
const stackName = app.node.tryGetContext("stackName")


if (!region || !account) {
  console.error('Please specify target account and region in the cdk.json file')
  process.exit(1)
}

export class RVizInfraStack extends cdk.Stack {
  constructor(scope: cdk.Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);
    const named = (name: String) => `${id}_${name}`

    let vpc = null
    if (vpcConfig && vpcConfig.useExisting && vpcConfig.id) {
      vpc = ec2.Vpc.fromLookup(this, named('Vpc'), {
        vpcId: vpcConfig.id
      })
    } else {
      vpc = new ec2.Vpc(this, named('Vpc'), {
        maxAzs: 1,
        subnetConfiguration: [
          {
            name: 'public',
            subnetType: ec2.SubnetType.PUBLIC
          },
          {
          name: 'private',
          subnetType: ec2.SubnetType.PRIVATE
        }]
      });
    }

    const vncPass = ssm.StringParameter.fromSecureStringParameterAttributes(this, named("VncPass"), {
      parameterName: ssmConfig.parameterPath,
      version: ssmConfig.parameterVersion
    })

    const userDataScript = fs.readFileSync(path.join(__dirname, 'user-data', 'rviz-setup.sh')).toString()
      .replace("$CDK_PROJECT_CONFIG_VNC_PASSWORD_PARAMETER_NAME", `${vncPass.parameterName}`)
      .replace("$CDK_PROJECT_CONFIG_INSTALL_SAMPLE_DATA", installSampleData)

    const ubuntuAmi = ec2.MachineImage.fromSSMParameter(ssmConfig.ubuntuAmi, ec2.OperatingSystemType.LINUX)

    const role = new iam.Role(this, named('RVizVncRole'), {
      assumedBy: new iam.ServicePrincipal('ec2.amazonaws.com'),
    });

    role.addManagedPolicy(ManagedPolicy.fromAwsManagedPolicyName('AmazonSSMManagedInstanceCore'));
    
    const kmsKeyForSecureString = kms.Alias.fromAliasName(this, named('VncPasswordKey'), 'alias/' + ssmConfig.kmsKeyAlias);

    const ssmPolicy = new iam.PolicyStatement({
      resources: [vncPass.parameterArn],
      actions: ["ssm:Describe*",
        "ssm:Get*",
        "ssm:List*"]
    })

    const kmsPolicy = new iam.PolicyStatement({
      resources: [kmsKeyForSecureString.keyArn],
      actions: ["kms:Decrypt"]
    })

    role.addToPolicy(ssmPolicy)
    role.addToPolicy(kmsPolicy)

    role.addManagedPolicy(ManagedPolicy.fromAwsManagedPolicyName('AmazonS3ReadOnlyAccess'))

    const vncInstance = new ec2.Instance(this, named('RVizVnc'), {
      vpc,
      instanceType: new ec2.InstanceType(ec2Config.instanceType),
      userData: ec2.UserData.custom(userDataScript),
      machineImage: ubuntuAmi,
      instanceName: ec2Config.instanceName,
      role,
      blockDevices: [
        {
          deviceName: '/dev/sda1',
          volume: ec2.BlockDeviceVolume.ebs(ec2Config.blockDevices.rootVolumeSize),
        }
      ],
      vpcSubnets: vpc.selectSubnets({
        subnetType: ec2.SubnetType.PRIVATE
      })
    })

    const vncPasswordParameterPath = new cdk.CfnOutput(this, "VncPasswordParameterPath", {
      value: `https://${region}.console.aws.amazon.com/systems-manager/parameters${ssmConfig.parameterPath}/description`
    })
  }
}

const stack = new RVizInfraStack(app, stackName, {
  env: {
    account,
    region
  }
});

Tags.of(app).add("tfc:solution:project", "AvDataLakeIndustryKit")
Tags.of(app).add("tfc:solution:module", "RVIZ-Infra")
Tags.of(app).add("tfc:solution:source", "https://code.amazon.com/packages/Rviz-infra/trees/mainline")

app.synth()