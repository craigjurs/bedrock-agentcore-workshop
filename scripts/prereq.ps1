#!/usr/bin/env pwsh

# Enable strict error handling
$ErrorActionPreference = "Stop"

# ----- Config -----
$BucketName = "redcross"
$InfraStackName = "RedCrossStackInfra"
$CognitoStackName = "RedCrossStackCognito"

$InfraTemplateFile = "prerequisite/infrastructure.yaml"
$CognitoTemplateFile = "prerequisite/cognito.yaml"

try {
    $Region = aws configure get region 2>$null
    if (-not $Region) { $Region = "us-west-2" }
} catch {
    $Region = "us-west-2"
}

# Get AWS Account ID with proper error handling
Write-Host "Getting AWS Account ID..." -ForegroundColor Cyan
try {
    $AccountId = aws sts get-caller-identity --query Account --output text 2>&1
    if ($LASTEXITCODE -ne 0 -or -not $AccountId -or $AccountId -eq "None") {
        throw "Failed to get AWS Account ID"
    }
} catch {
    Write-Host "Failed to get AWS Account ID. Please check your AWS credentials and network connectivity." -ForegroundColor Red
    Write-Host "Error: $_" -ForegroundColor Red
    exit 1
}

$FullBucketName = "$BucketName-$AccountId-$Region"
$ZipFile = "lambda.zip"
$LayerZipFile = "ddgs-layer.zip"
$LayerSource = "prerequisite/lambda/python"
$S3LayerKey = $LayerZipFile
$LambdaSrc = "prerequisite/lambda/python"
$S3Key = $ZipFile

Write-Host "Region: $Region" -ForegroundColor Green
Write-Host "Account ID: $AccountId" -ForegroundColor Green

# ----- 1. Create S3 bucket -----
Write-Host "Using S3 bucket: $FullBucketName" -ForegroundColor Cyan
try {
    if ($Region -eq "us-east-1") {
        aws s3api create-bucket --bucket $FullBucketName 2>$null
    } else {
        aws s3api create-bucket --bucket $FullBucketName --region $Region --create-bucket-configuration LocationConstraint=$Region 2>$null
    }
} catch {
    Write-Host "Bucket may already exist or be owned by you." -ForegroundColor Yellow
}

# ----- 2. Zip Lambda code -----
Write-Host "Zipping contents of $LambdaSrc into $ZipFile..." -ForegroundColor Cyan
Push-Location $LambdaSrc
try {
    Compress-Archive -Path "." -DestinationPath "../../../$ZipFile" -Force
} catch {
    Write-Host "Failed to create zip file. Ensure you have PowerShell 5.0+ or install 7-Zip." -ForegroundColor Red
    exit 1
}
Pop-Location

# ----- 3. Upload to S3 -----
Write-Host "Uploading $ZipFile to s3://$FullBucketName/$S3Key..." -ForegroundColor Cyan
aws s3 cp $ZipFile "s3://$FullBucketName/$S3Key"

Write-Host "Uploading $LayerZipFile to s3://$FullBucketName/$S3LayerKey..." -ForegroundColor Cyan
Push-Location $LambdaSrc
aws s3 cp $LayerZipFile "s3://$FullBucketName/$S3LayerKey"
Pop-Location

# ----- 4. Deploy CloudFormation -----
function Describe-FailedEvents {
    param([string]$StackName)
    Write-Host "Diagnosing failure for $StackName..." -ForegroundColor Yellow
    Write-Host ""
    
    # First, try to get change set status (works even if stack doesn't exist yet)
    try {
        $latestCs = aws cloudformation list-change-sets `
            --stack-name $StackName `
            --region $Region `
            --query "Summaries | sort_by(@, &CreationTime) | [-1].ChangeSetName" `
            --output text 2>$null
        if ($latestCs -and $latestCs -ne "None" -and $latestCs -ne "null") {
            Write-Host "Latest change set: $latestCs" -ForegroundColor Yellow
            aws cloudformation describe-change-set `
                --stack-name $StackName `
                --change-set-name $latestCs `
                --region $Region `
                --query "{Status:Status,StatusReason:StatusReason,ExecutionStatus:ExecutionStatus}" `
                --output table 2>$null
            Write-Host ""
        }
    } catch { }
    
    # Then try to get stack events (only if stack exists)
    Write-Host "Stack events (if stack exists):" -ForegroundColor Yellow
    try {
        $null = aws cloudformation describe-stacks --stack-name $StackName --region $Region 2>$null
        if ($LASTEXITCODE -eq 0) {
            aws cloudformation describe-stack-events `
                --stack-name $StackName `
                --region $Region `
                --query "reverse(@)[0:25].[Timestamp,ResourceType,LogicalResourceId,ResourceStatus,ResourceStatusReason]" `
                --output table 2>$null
        } else {
            Write-Host "  (Stack does not exist - check change set StatusReason above)" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  (Could not fetch events)" -ForegroundColor Yellow
    }
}

function Deploy-Stack {
    param(
        [string]$StackName,
        [string]$TemplateFile,
        [string[]]$Parameters
    )
    
    Write-Host "Deploying CloudFormation stack: $StackName" -ForegroundColor Cyan
    
    $deployArgs = @(
        "cloudformation", "deploy",
        "--stack-name", $StackName,
        "--template-file", $TemplateFile,
        "--s3-bucket", $FullBucketName,
        "--capabilities", "CAPABILITY_NAMED_IAM",
        "--region", $Region
    )
    
    if ($Parameters) {
        $deployArgs += "--parameter-overrides"
        $deployArgs += $Parameters
    }
    
    $output = & aws @deployArgs 2>&1
    Write-Host "AWS CLI Exit Code: $LASTEXITCODE" -ForegroundColor Yellow
    Write-Host "AWS CLI Output: $output" -ForegroundColor Yellow
    
    # If stack is in ROLLBACK_COMPLETE, delete and retry once
    if ($output -match "is in ROLLBACK_COMPLETE state and can not be updated") {
        Write-Host ""
        Write-Host "Stack $StackName is in ROLLBACK_COMPLETE; deleting before redeploy..." -ForegroundColor Yellow
        aws cloudformation delete-stack --stack-name $StackName --region $Region
        aws cloudformation wait stack-delete-complete --stack-name $StackName --region $Region
        Write-Host "Retrying deployment of $StackName..." -ForegroundColor Cyan
        $output = & aws @deployArgs 2>&1
        Write-Host "AWS CLI Output: $output" -ForegroundColor Yellow
    }
    
    if ($LASTEXITCODE -ne 0) {
        if ($output -match "No changes to deploy") {
            Write-Host "No updates for stack $StackName, continuing..." -ForegroundColor Yellow
            return $true
        } else {
            Write-Host ""
            Write-Host "Error deploying stack ${StackName}:" -ForegroundColor Red
            Write-Host $output -ForegroundColor Red
            Write-Host ""
            Describe-FailedEvents -StackName $StackName
            return $false
        }
    } else {
        Write-Host "Stack $StackName deployed successfully." -ForegroundColor Green
        return $true
    }
}

# ----- Run both stacks -----
# If infrastructure stack is in ROLLBACK_COMPLETE, it cannot be updated—delete it first
try {
    $infraStatus = (aws cloudformation describe-stacks --stack-name $InfraStackName --query "Stacks[0].StackStatus" --output text 2>$null)
    if ($infraStatus -eq "ROLLBACK_COMPLETE") {
        Write-Host "Stack $InfraStackName is in ROLLBACK_COMPLETE; deleting before redeploy..." -ForegroundColor Yellow
        aws cloudformation delete-stack --stack-name $InfraStackName --region $Region
        aws cloudformation wait stack-delete-complete --stack-name $InfraStackName --region $Region
        Write-Host "Stack $InfraStackName deleted." -ForegroundColor Green
    }
} catch { }

Write-Host "Starting deployment of infrastructure stack with LambdaS3Bucket = $FullBucketName..." -ForegroundColor Cyan
$infraParams = @("LambdaS3Bucket=$FullBucketName", "LambdaS3Key=$S3Key", "LayerS3Key=$S3LayerKey")
$infraSuccess = Deploy-Stack -StackName $InfraStackName -TemplateFile $InfraTemplateFile -Parameters $infraParams

# If Cognito stack is in ROLLBACK_COMPLETE, it cannot be updated—delete it first
try {
    $cognitoStatus = (aws cloudformation describe-stacks --stack-name $CognitoStackName --query "Stacks[0].StackStatus" --output text 2>$null)
    if ($cognitoStatus -eq "ROLLBACK_COMPLETE") {
        Write-Host "Stack $CognitoStackName is in ROLLBACK_COMPLETE; deleting before redeploy..." -ForegroundColor Yellow
        aws cloudformation delete-stack --stack-name $CognitoStackName --region $Region
        aws cloudformation wait stack-delete-complete --stack-name $CognitoStackName --region $Region
        Write-Host "Stack $CognitoStackName deleted." -ForegroundColor Green
    }
} catch { }

Write-Host "Starting deployment of Cognito stack..." -ForegroundColor Cyan
$cognitoParams = @("UserPoolName=RedCrossGatewayPool", "MachineAppClientName=RedCrossMachineClient", "WebAppClientName=RedCrossWebClient")
$cognitoSuccess = Deploy-Stack -StackName $CognitoStackName -TemplateFile $CognitoTemplateFile -Parameters $cognitoParams

if ($infraSuccess -and $cognitoSuccess) {
    Write-Host "Deployment complete." -ForegroundColor Green
} else {
    Write-Host "Deployment failed." -ForegroundColor Red
    exit 1
}
