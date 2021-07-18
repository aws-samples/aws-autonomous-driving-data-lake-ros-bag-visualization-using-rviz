// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0

const readline = require('readline');
const fs = require('fs')
const path = require('path')
const { exec } = require("child_process");

const getInput = (question, defaultValue) => {
    return new Promise((resolve, reject) => {
        const rl = readline.createInterface({
            input: process.stdin,
            output: process.stdout
        });

        let defaultText = defaultValue ? ` (default [${defaultValue}])` : ''

        rl.question(`${question}${defaultText}: `, (answer) => {
            rl.close()
            if (answer) {
                return resolve(answer.trim())
            } else if (defaultValue) {
                return resolve(defaultValue)
            }
            return reject("Expected non-null value, no default set. Please provide a proper input")
        })
    })
}

const execCommand = (command) => {
    return new Promise((resolve, reject) => {
        exec(command, (error, stdout, stderr) => {
            if (error) {
                console.log(`error: ${error.message}`);
                return reject(error)
            }
            if (stderr) {
                console.log(`stderr: ${stderr}`);
                return reject(stderr)
            }
            return resolve(stdout)
        })
    })
}

const bootstrap = async () => {
    try {
        let cdkJson = require('./cdk.json')
        console.log("Bootstrapping environment")
        const vncPassword = await getInput("VNC Password")
        const account = await getInput("AWS Account", cdkJson.context.account)
        const region = await getInput("AWS Region", cdkJson.context.region)
        const ssmParameterPath = await getInput("VNC Password parameter path in SSM", cdkJson.context.ssm.parameterPath)
        const vpcId = await getInput("VPC ID (Set to 'create' to generate a new one)", cdkJson.context.vpc.id)
        const stackName = await getInput("Stack Name", cdkJson.context.stackName)
        const instanceType = await getInput("EC2 Instance Type", cdkJson.context.ec2.instanceType)
        const rootVolumeSize = await getInput("EC2 Root volume size in GB", cdkJson.context.ec2.blockDevices.rootVolumeSize)
        const installSamepleData = await getInput("Install Sample data", cdkJson.context.installSampleData)

        if (!vncPassword) {
            throw new Error('Please specify a valid password')
        } else {
            cdkJson.context.account = account
            cdkJson.context.region = region
            cdkJson.context.ssm.parameterPath = ssmParameterPath
            cdkJson.context.stackName = stackName
            cdkJson.context.ec2.instanceType = instanceType
            cdkJson.context.ec2.blockDevices.rootVolumeSize = parseInt(rootVolumeSize, 10)
            cdkJson.context.installSampleData = !!installSamepleData

            if (vpcId.toLowerCase() === "create") {
                cdkJson.context.vpc.useExisting = false
                cdkJson.context.vpc.id = ""
            } else {
                cdkJson.context.vpc.useExisting = true
                cdkJson.context.vpc.id = vpcId
            }

            try {
                const output = JSON.parse(await execCommand(`aws ssm put-parameter --name "${ssmParameterPath}" --value "${vncPassword}" --type "SecureString" --overwrite`))
                cdkJson.context.ssm.parameterVersion = output["Version"]
                console.log(`Created ssm parameter version ${cdkJson.context.ssm.parameterVersion}: https://${region}.console.aws.amazon.com/systems-manager/parameters${ssmParameterPath}/description`)

            } catch (err) {
                console.error("Could not bootstrap. Please ensure you have the AWSCLI installed and have the appropriate permissions. Try running the following commands")
                console.log("$aws ssm put-parameter --name /test/ssm --value foo --type SecureString --overwrite")
            }

            fs.writeFileSync('./cdk.json', JSON.stringify(cdkJson, null, 2))
            console.log("The cdk.json file has been updated with your bootstrapped values")
        }
    } catch (err) {
        console.error("Bootstrapping Failed: ", err)
    }
}

bootstrap()
