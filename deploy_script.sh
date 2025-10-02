#!/bin/bash

# Deployment script for AI-Powered CloudFormation to Terraform Pipeline
# Usage: ./deploy-pipeline.sh [deploy|destroy]

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info() { echo -e "${BLUE}ℹ ${NC}$1"; }
print_success() { echo -e "${GREEN}✓ ${NC}$1"; }
print_warning() { echo -e "${YELLOW}⚠ ${NC}$1"; }
print_error() { echo -e "${RED}✗ ${NC}$1"; }

usage() {
    echo "Usage: $0 [deploy|destroy]"
    echo "  deploy  - Deploy the pipeline (default)"
    echo "  destroy - Destroy all resources"
    exit 1
}

# Function to check prerequisites
check_prerequisites() {
    print_info "Checking prerequisites..."
    
    # Check AWS CLI
    if ! command -v aws &> /dev/null; then
        print_error "AWS CLI is not installed. Please install it first."
        exit 1
    fi
    print_success "AWS CLI found"
    
    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        print_error "AWS credentials not configured. Please run 'aws configure'"
        exit 1
    fi
    print_success "AWS credentials configured"
    
    # Check required files
    print_info "Checking required files..."
    REQUIRED_FILES=(
        "pipeline-bedrock.yaml"
        "bedrock-ai-converter.py"
        "buildspec-bedrock-convert.yml"
        "buildspec-deploy.yml"
        "buildspec-apply.yml"
    )
    
    for FILE in "${REQUIRED_FILES[@]}"; do
        if [ ! -f "$FILE" ]; then
            print_error "Required file not found: $FILE"
            print_info "Make sure all files are in the current directory"
            exit 1
        fi
    done
    print_success "All required files found"
    
    # Check jq (optional but helpful)
    if ! command -v jq &> /dev/null; then
        print_warning "jq is not installed. Install it for better output formatting."
    fi
    
    # Get AWS account ID and region
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    AWS_REGION=$(aws configure get region || echo "us-east-1")
    
    print_success "AWS Account ID: ${AWS_ACCOUNT_ID}"
    print_success "AWS Region: ${AWS_REGION}"
}

# Function to enable Bedrock model access
enable_bedrock_model() {
    print_info "Checking Bedrock Nova Pro model access..."
    
    # Check if model is already accessible
    if aws bedrock list-foundation-models --region ${AWS_REGION} --query "modelSummaries[?modelId=='us.amazon.nova-pro-v1:0'].modelId" --output text 2>/dev/null | grep -q "nova-pro"; then
        print_success "Bedrock Nova Pro model is accessible"
    else
        print_warning "Bedrock Nova Pro model may not be enabled in your account"
        print_info "Please enable it through the AWS Console:"
        print_info "1. Go to AWS Bedrock console"
        print_info "2. Navigate to Model access"
        print_info "3. Enable 'Nova Pro' model"
        print_info ""
        read -p "Have you enabled the model? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_error "Please enable Bedrock Nova Pro model and run this script again"
            exit 1
        fi
    fi
}

# Function to get user input
get_user_input() {
    print_info "Please provide the following information:"
    echo ""
    
    # Stack name
    read -p "Stack Name [cft-terraform-ai-pipeline]: " STACK_NAME
    STACK_NAME=${STACK_NAME:-cft-terraform-ai-pipeline}
    
    # Terraform state bucket (must be unique)
    DEFAULT_STATE_BUCKET="${STACK_NAME}-tfstate-${AWS_ACCOUNT_ID}"
    read -p "Terraform State Bucket [${DEFAULT_STATE_BUCKET}]: " TF_STATE_BUCKET
    TF_STATE_BUCKET=${TF_STATE_BUCKET:-$DEFAULT_STATE_BUCKET}
    
    # Repository name
    read -p "CodeCommit Repository Name [cft-to-terraform-ai-repo]: " REPO_NAME
    REPO_NAME=${REPO_NAME:-cft-to-terraform-ai-repo}
    
    # Notification email
    read -p "Notification Email (optional, press Enter to skip): " NOTIFICATION_EMAIL
    
    echo ""
    print_info "Configuration Summary:"
    echo "  Stack Name: ${STACK_NAME}"
    echo "  Terraform State Bucket: ${TF_STATE_BUCKET}"
    echo "  Repository Name: ${REPO_NAME}"
    echo "  Notification Email: ${NOTIFICATION_EMAIL:-<none>}"
    echo "  AWS Region: ${AWS_REGION}"
    echo "  AWS Account: ${AWS_ACCOUNT_ID}"
    echo ""
    
    read -p "Proceed with deployment? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_error "Deployment cancelled"
        exit 1
    fi
}

# Function to deploy CloudFormation stack
deploy_stack() {
    print_info "Deploying CloudFormation stack: ${STACK_NAME}..."
    
    # Build parameters
    PARAMETERS="ParameterKey=TerraformStateBucket,ParameterValue=${TF_STATE_BUCKET}"
    PARAMETERS="${PARAMETERS} ParameterKey=RepositoryName,ParameterValue=${REPO_NAME}"
    
    if [ -n "${NOTIFICATION_EMAIL}" ]; then
        PARAMETERS="${PARAMETERS} ParameterKey=NotificationEmail,ParameterValue=${NOTIFICATION_EMAIL}"
    fi
    
    # Deploy stack
    aws cloudformation create-stack \
        --stack-name ${STACK_NAME} \
        --template-body file://pipeline-bedrock.yaml \
        --parameters ${PARAMETERS} \
        --capabilities CAPABILITY_IAM \
        --region ${AWS_REGION}
    
    print_info "Stack creation initiated. Waiting for completion..."
    
    aws cloudformation wait stack-create-complete \
        --stack-name ${STACK_NAME} \
        --region ${AWS_REGION}
    
    print_success "Stack deployed successfully!"
}

# Function to get stack outputs
get_stack_outputs() {
    print_info "Retrieving stack outputs..."
    
    REPO_URL=$(aws cloudformation describe-stacks \
        --stack-name ${STACK_NAME} \
        --query 'Stacks[0].Outputs[?OutputKey==`RepositoryCloneUrlHttp`].OutputValue' \
        --output text \
        --region ${AWS_REGION})
    
    PIPELINE_URL=$(aws cloudformation describe-stacks \
        --stack-name ${STACK_NAME} \
        --query 'Stacks[0].Outputs[?OutputKey==`PipelineUrl`].OutputValue' \
        --output text \
        --region ${AWS_REGION})
    
    ARTIFACT_BUCKET=$(aws cloudformation describe-stacks \
        --stack-name ${STACK_NAME} \
        --query 'Stacks[0].Outputs[?OutputKey==`ArtifactBucketName`].OutputValue' \
        --output text \
        --region ${AWS_REGION})
    
    print_success "Repository URL: ${REPO_URL}"
    print_success "Pipeline URL: ${PIPELINE_URL}"
    print_success "Artifact Bucket: ${ARTIFACT_BUCKET}"
}

# Function to configure git credentials for CodeCommit
configure_git_credentials() {
    print_info "Configuring Git credentials for CodeCommit..."
    
    # Check if credential helper is already configured
    if git config --global credential.helper | grep -q "aws"; then
        print_success "AWS credential helper already configured"
        return 0
    fi
    
    print_info "Configuring AWS CodeCommit credential helper..."
    git config --global credential.helper '!aws codecommit credential-helper $@'
    git config --global credential.UseHttpPath true
    
    print_success "Git credential helper configured"
}

# Function to setup repository
setup_repository() {
    print_info "Setting up repository..."
    
    # Configure git credentials first
    configure_git_credentials
    
    # Create temporary directory
    TEMP_DIR=$(mktemp -d)
    cd ${TEMP_DIR}
    
    # Clone repository
    print_info "Cloning repository (this may take a moment)..."
    if ! git clone ${REPO_URL} repo 2>&1; then
        print_error "Failed to clone repository"
        print_info "Troubleshooting steps:"
        print_info "1. Ensure AWS CLI is configured: aws sts get-caller-identity"
        print_info "2. Check IAM permissions for CodeCommit"
        print_info "3. Verify git credential helper: git config --global credential.helper"
        exit 1
    fi
    cd repo
    
    # Create directory structure
    mkdir -p cloudformation
    
    # Copy files from parent directory
    print_info "Copying pipeline files..."
    
    if [ -f "../bedrock-ai-converter.py" ]; then
        cp ../bedrock-ai-converter.py .
    else
        print_error "bedrock-ai-converter.py not found in parent directory"
        exit 1
    fi
    
    if [ -f "../buildspec-bedrock-convert.yml" ]; then
        cp ../buildspec-bedrock-convert.yml .
    else
        print_error "buildspec-bedrock-convert.yml not found"
        exit 1
    fi
    
    if [ -f "../buildspec-deploy.yml" ]; then
        cp ../buildspec-deploy.yml .
    else
        print_error "buildspec-deploy.yml not found"
        exit 1
    fi
    
    if [ -f "../buildspec-apply.yml" ]; then
        cp ../buildspec-apply.yml .
    else
        print_error "buildspec-apply.yml not found"
        exit 1
    fi
    
    # Create README
    cat > README.md << 'README_EOF'
# AI-Powered CloudFormation to Terraform Pipeline

This repository contains an automated pipeline that converts CloudFormation templates to Terraform using AWS Bedrock Nova Pro.

## Usage

1. Add your CloudFormation templates to the `cloudformation/` directory
2. Commit and push to trigger the pipeline
3. Review the AI-generated Terraform code
4. Approve the deployment when ready

## Directory Structure

```
.
├── cloudformation/              # Place your CFT templates here
├── bedrock-ai-converter.py     # AI conversion script
├── buildspec-bedrock-convert.yml
├── buildspec-deploy.yml
├── buildspec-apply.yml
└── README.md
```

## Features

- **AI-Powered Conversion**: Uses AWS Bedrock Nova Pro for intelligent conversion
- **Automatic Validation**: Multiple validation passes ensure accuracy
- **Test Generation**: Automated test cases created for each conversion
- **Manual Approval**: Review before deployment
- **Full Audit Trail**: All conversions tracked and logged

## Getting Started

```bash
# Add a CloudFormation template
cp /path/to/your/template.yaml cloudformation/

# Commit and push
git add cloudformation/template.yaml
git commit -m "Add infrastructure template"
git push origin main
```

The pipeline will automatically:
1. Convert your template using AI
2. Validate the Terraform code
3. Create an execution plan
4. Wait for your approval
5. Deploy the infrastructure
README_EOF
    
    # Create .gitignore
    cat > .gitignore << 'GITIGNORE_EOF'
*.tfstate
*.tfstate.backup
.terraform/
*.tar.gz
terraform-output/
__pycache__/
*.pyc
.DS_Store
GITIGNORE_EOF
    
    # Commit and push
    git add .
    git commit -m "Initial commit: AI-powered pipeline setup"
    git push origin main
    
    print_success "Repository setup complete!"
    
    # Cleanup
    cd ../..
    rm -rf ${TEMP_DIR}
}

# Function to create sample test case
create_test_case() {
    print_info "Creating sample test case..."
    
    TEST_DIR="test-case"
    mkdir -p ${TEST_DIR}
    
    # Create sample CloudFormation template
    cat > ${TEST_DIR}/sample-s3-vpc.yaml << 'SAMPLE_EOF'
AWSTemplateFormatVersion: '2010-09-09'
Description: 'Sample CloudFormation template for testing AI conversion - S3 bucket and VPC'

Parameters:
  Environment:
    Type: String
    Default: dev
    Description: Environment name
    AllowedValues:
      - dev
      - staging
      - prod
  
  BucketPrefix:
    Type: String
    Default: my-app
    Description: Prefix for S3 bucket name
  
  VpcCidr:
    Type: String
    Default: 10.0.0.0/16
    Description: CIDR block for VPC

Resources:
  # S3 Bucket
  ApplicationBucket:
    Type: AWS::S3::Bucket
    Properties:
      BucketName: !Sub '${BucketPrefix}-${Environment}-${AWS::AccountId}'
      VersioningConfiguration:
        Status: Enabled
      BucketEncryption:
        ServerSideEncryptionConfiguration:
          - ServerSideEncryptionByDefault:
              SSEAlgorithm: AES256
      PublicAccessBlockConfiguration:
        BlockPublicAcls: true
        BlockPublicPolicy: true
        IgnorePublicAcls: true
        RestrictPublicBuckets: true
      Tags:
        - Key: Environment
          Value: !Ref Environment
        - Key: ManagedBy
          Value: CloudFormation

  # S3 Bucket Policy
  ApplicationBucketPolicy:
    Type: AWS::S3::BucketPolicy
    Properties:
      Bucket: !Ref ApplicationBucket
      PolicyDocument:
        Statement:
          - Sid: DenyInsecureConnections
            Effect: Deny
            Principal: '*'
            Action: 's3:*'
            Resource:
              - !GetAtt ApplicationBucket.Arn
              - !Sub '${ApplicationBucket.Arn}/*'
            Condition:
              Bool:
                'aws:SecureTransport': false

  # VPC
  ApplicationVPC:
    Type: AWS::EC2::VPC
    Properties:
      CidrBlock: !Ref VpcCidr
      EnableDnsHostnames: true
      EnableDnsSupport: true
      Tags:
        - Key: Name
          Value: !Sub '${AWS::StackName}-vpc'
        - Key: Environment
          Value: !Ref Environment

  # Internet Gateway
  InternetGateway:
    Type: AWS::EC2::InternetGateway
    Properties:
      Tags:
        - Key: Name
          Value: !Sub '${AWS::StackName}-igw'
        - Key: Environment
          Value: !Ref Environment

  # Attach IGW to VPC
  AttachGateway:
    Type: AWS::EC2::VPCGatewayAttachment
    Properties:
      VpcId: !Ref ApplicationVPC
      InternetGatewayId: !Ref InternetGateway

  # Public Subnet
  PublicSubnet:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref ApplicationVPC
      CidrBlock: !Select [0, !Cidr [!Ref VpcCidr, 4, 8]]
      AvailabilityZone: !Select 
        - 0
        - !GetAZs ''
      MapPublicIpOnLaunch: true
      Tags:
        - Key: Name
          Value: !Sub '${AWS::StackName}-public-subnet'
        - Key: Environment
          Value: !Ref Environment

  # Route Table
  PublicRouteTable:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref ApplicationVPC
      Tags:
        - Key: Name
          Value: !Sub '${AWS::StackName}-public-rt'

  # Public Route
  PublicRoute:
    Type: AWS::EC2::Route
    DependsOn: AttachGateway
    Properties:
      RouteTableId: !Ref PublicRouteTable
      DestinationCidrBlock: 0.0.0.0/0
      GatewayId: !Ref InternetGateway

  # Subnet Route Table Association
  SubnetRouteTableAssociation:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PublicSubnet
      RouteTableId: !Ref PublicRouteTable

  # Security Group
  ApplicationSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupName: !Sub '${AWS::StackName}-sg'
      GroupDescription: Security group for application
      VpcId: !Ref ApplicationVPC
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 443
          ToPort: 443
          CidrIp: 0.0.0.0/0
          Description: Allow HTTPS
      SecurityGroupEgress:
        - IpProtocol: -1
          CidrIp: 0.0.0.0/0
          Description: Allow all outbound
      Tags:
        - Key: Name
          Value: !Sub '${AWS::StackName}-sg'
        - Key: Environment
          Value: !Ref Environment

Outputs:
  BucketName:
    Description: Name of the S3 bucket
    Value: !Ref ApplicationBucket
    Export:
      Name: !Sub '${AWS::StackName}-bucket-name'

  BucketArn:
    Description: ARN of the S3 bucket
    Value: !GetAtt ApplicationBucket.Arn
    Export:
      Name: !Sub '${AWS::StackName}-bucket-arn'

  VpcId:
    Description: VPC ID
    Value: !Ref ApplicationVPC
    Export:
      Name: !Sub '${AWS::StackName}-vpc-id'

  PublicSubnetId:
    Description: Public Subnet ID
    Value: !Ref PublicSubnet
    Export:
      Name: !Sub '${AWS::StackName}-public-subnet-id'

  SecurityGroupId:
    Description: Security Group ID
    Value: !Ref ApplicationSecurityGroup
    Export:
      Name: !Sub '${AWS::StackName}-sg-id'
SAMPLE_EOF
    
    # Create test instructions
    cat > ${TEST_DIR}/TEST_INSTRUCTIONS.md << 'TEST_EOF'
# Test Case Instructions

This test case demonstrates the AI-powered CloudFormation to Terraform conversion.

## Test Template

The `sample-s3-vpc.yaml` template includes:
- S3 bucket with versioning and encryption
- S3 bucket policy
- VPC with public subnet
- Internet Gateway
- Route table and routes
- Security group
- Multiple parameters and outputs
- CloudFormation intrinsic functions (Ref, GetAtt, Sub, Select, Cidr)

## Running the Test

### Option 1: Through the Pipeline

```bash
# Copy test template to repository
cp sample-s3-vpc.yaml /path/to/repo/cloudformation/

# Commit and push
cd /path/to/repo
git add cloudformation/sample-s3-vpc.yaml
git commit -m "Add test template"
git push origin main

# Monitor pipeline in AWS Console
```

### Option 2: Standalone Conversion

```bash
# Run converter directly
python3 bedrock-ai-converter.py sample-s3-vpc.yaml terraform-output

# Review output
cd terraform-output
cat sample-s3-vpc.tf
cat CONVERSION_REPORT.md

# Test Terraform
terraform init -backend=false
terraform validate
terraform fmt
```

## Expected Results

The AI converter should:
1. ✓ Convert all 10 resources correctly
2. ✓ Handle all CloudFormation intrinsic functions
3. ✓ Preserve all parameters as variables
4. ✓ Convert all outputs
5. ✓ Maintain resource dependencies
6. ✓ Include proper tags
7. ✓ Generate valid Terraform syntax
8. ✓ Pass validation checks
9. ✓ Create test cases
10. ✓ Generate comprehensive report

## Validation Checklist

- [ ] All resources converted
- [ ] No syntax errors
- [ ] Intrinsic functions properly converted
- [ ] Dependencies preserved
- [ ] Security settings maintained
- [ ] Tags included
- [ ] Outputs match CloudFormation
- [ ] terraform validate passes
- [ ] Plan generates without errors

## Common Issues and Solutions

**Issue**: Bedrock API errors
**Solution**: Ensure Bedrock Nova Pro model is enabled in your account

**Issue**: Terraform validation fails
**Solution**: Review conversion report for specific errors

**Issue**: Missing resources in output
**Solution**: Check CloudFormation template syntax, run validation

## Next Steps After Successful Test

1. Review generated Terraform code quality
2. Compare with original CloudFormation
3. Test with your own templates
4. Customize converter for your specific needs
5. Deploy to production pipeline
TEST_EOF
    
    print_success "Test case created in: ${TEST_DIR}/"
    print_info "Review TEST_INSTRUCTIONS.md for testing steps"
}

# Function to print next steps
print_next_steps() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║                    Deployment Successful!                      ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
    print_success "Pipeline deployed and ready to use!"
    echo ""
    print_info "Next Steps:"
    echo ""
    echo "1. Clone your repository:"
    echo "   git clone ${REPO_URL}"
    echo ""
    echo "2. Add CloudFormation templates:"
    echo "   cd ${REPO_NAME}"
    echo "   cp your-template.yaml cloudformation/"
    echo ""
    echo "3. Push to trigger the pipeline:"
    echo "   git add cloudformation/your-template.yaml"
    echo "   git commit -m \"Add infrastructure template\""
    echo "   git push origin main"
    echo ""
    echo "4. Monitor the pipeline:"
    echo "   ${PIPELINE_URL}"
    echo ""
    echo "5. Run the test case:"
    echo "   cd test-case"
    echo "   cat TEST_INSTRUCTIONS.md"
    echo ""
    
    if [ -n "${NOTIFICATION_EMAIL}" ]; then
        print_warning "Check your email (${NOTIFICATION_EMAIL}) to confirm SNS subscription"
    fi
    
    echo ""
    print_info "Resources created:"
    echo "  - CodeCommit Repository: ${REPO_NAME}"
    echo "  - CodePipeline: ${STACK_NAME}-pipeline"
    echo "  - S3 Bucket (artifacts): ${ARTIFACT_BUCKET}"
    echo "  - S3 Bucket (terraform state): ${TF_STATE_BUCKET}"
    echo "  - Bedrock access: Nova Pro model"
    echo ""
}

# Main execution
main() {
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║  AI-Powered CloudFormation to Terraform Pipeline Deployment   ║"
    echo "║  Using AWS Bedrock Nova Pro                                    ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
    
    check_prerequisites
    enable_bedrock_model
    get_user_input
    deploy_stack
    get_stack_outputs
    setup_repository
    create_test_case
    print_next_steps
    
    print_success "Deployment complete!"
}

# Run main function
main