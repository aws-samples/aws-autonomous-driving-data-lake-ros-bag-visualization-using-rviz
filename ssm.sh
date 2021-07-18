#!/bin/bash

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

ACTION="${1:-'UNDEFINED'}"
if [ $ACTION != 'ssh' ] && [ $ACTION != 'vnc' ]
then
 echo "Invalid action. Please specify either ssh or vnc"
 exit 1
fi


INSTANCE_NAME="$(node -pe 'JSON.parse(process.argv[1]).context.ec2.instanceName' "$(cat cdk.json)")"
STACK_NAME="$(node -pe 'JSON.parse(process.argv[1]).context.stackName' "$(cat cdk.json)")"
REGION_NAME="$(node -pe 'JSON.parse(process.argv[1]).context.region' "$(cat cdk.json)")"
echo "Looking up ID for instance $INSTANCE_NAME"
INSTANCE_ID=$(aws ec2 --region $REGION_NAME describe-instances \
               --filter "Name=tag:Name,Values=$INSTANCE_NAME" \
               --filter "Name=tag:aws:cloudformation:stack-name,Values=$STACK_NAME" \
               --query "Reservations[].Instances[?State.Name == 'running'].InstanceId[]" \
               --output text
               )
echo "Found instance ID: $INSTANCE_ID"

if [ $ACTION = 'ssh' ]
then
  echo "Starting new SSH session"
  aws ssm --region $REGION_NAME start-session --target $INSTANCE_ID 
elif [ $ACTION = 'vnc' ]
then
 echo "Port forwarding via SSH to local port 5901"
 aws ssm --region $REGION_NAME start-session --target $INSTANCE_ID \
                       --document-name AWS-StartPortForwardingSession \
                       --parameters '{"portNumber":["5901"],"localPortNumber":["5901"]}'
fi

