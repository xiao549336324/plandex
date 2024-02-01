#!/bin/bash

# Enhanced error handling and logging
set -e
set -o pipefail

log() {
  echo "[$(date +%Y-%m-%dT%H:%M:%S%z)]: $*"
}

handle_error() {
  local exit_code=$?
  log "An error occurred. Exiting with status ${exit_code}"
  exit $exit_code
}

trap 'handle_error' ERR

log() {
  echo "[$(date +%Y-%m-%dT%H:%M:%S%z)]: $*"
}

handle_error() {
  local exit_code=$?
  log "An error occurred. Exiting with status ${exit_code}"
  exit $exit_code
}

trap 'handle_error' ERR

log "Deploying the infrastructure..."

export AWS_PROFILE=plandex

# Generate a unique tag for the deployment
# Path to the file where the STACK_TAG is stored
STACK_TAG_FILE="stack-tag.txt"

# Function to generate a new STACK_TAG and save it to the file
generate_and_save_stack_tag() {
  export STACK_TAG=$(uuidgen | cut -d '-' -f1)
  echo $STACK_TAG > $STACK_TAG_FILE
  log "Generated new STACK_TAG: $STACK_TAG"
}

# Function to load the existing STACK_TAG from the file
load_stack_tag() {
  export STACK_TAG=$(cat $STACK_TAG_FILE)
  log "Loaded existing STACK_TAG: $STACK_TAG"
}

# Check if the STACK_TAG file exists and load it, otherwise generate a new one
if [ -f "$STACK_TAG_FILE" ]; then
  log "Loading existing STACK_TAG from file..."
  load_stack_tag
else
  log "Generating new STACK_TAG and saving to file..."
  generate_and_save_stack_tag
fi



# Function to ensure the ECR repository exists
ensure_ecr_repository_exists() {
  # Check if the ECR repository exists
  log "Checking if the ECR repository 'plandex-ecr-repository' exists..."
  if ! aws ecr describe-repositories --repository-names plandex-ecr-repository 2>/dev/null; then
    log "ECR repository does not exist. Creating repository..."
    aws ecr create-repository --repository-name plandex-ecr-repository
    log "ECR repository 'plandex-ecr-repository' created."
  else
    log "ECR repository 'plandex-ecr-repository' already exists."
  fi
}

log "Checking if the ECR repository exists..."

# Ensure the ECR repository exists before proceeding
ensure_ecr_repository_exists

# Set variables for the ECR repository and image tag
ECR_REPOSITORY=$(aws ecr describe-repositories --repository-names plandex-ecr-repository | jq -r '.repositories[0].repositoryUri')
IMAGE_TAG=$(git rev-parse --short HEAD)

# Function to deploy or update the CloudFormation stack using AWS CDK
deploy_or_update_stack() {
  # Check if the stack exists
  STACK_NAME=$(aws cloudformation list-stacks --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE | jq -r '.StackSummaries[] | select(.StackName | startswith("plandex-stack-")) | .StackName')

  if [ -z "$STACK_NAME" ]; then
    # Deploy the stack if it does not exist
    npx cdk deploy --require-approval never --app "npx ts-node src/main.ts" --context stackTag=$STACK_TAG "plandex-stack-$STACK_TAG"
  else
    # Update the stack if it exists
    npx cdk deploy "$STACK_NAME" --require-approval never --app "npx ts-node src/main.ts"
  fi
}

# Function to build and push the Docker image to ECR
build_and_push_image() {
  # Login to ECR
  aws ecr get-login-password --region $(aws configure get region) | docker login --username AWS --password-stdin $ECR_REPOSITORY

  # Build the Docker image
  docker build -t plandex-server:$IMAGE_TAG -f app/Dockerfile.server .

  # Tag the image for the ECR repository
  docker tag plandex-server:$IMAGE_TAG $ECR_REPOSITORY:$IMAGE_TAG

  # Push the image to ECR
  docker push $ECR_REPOSITORY:$IMAGE_TAG
}

# Function to update the ECS service with the new Docker image
update_ecs_service() {
  # Extract the tag from the ECR repository URI
  TAG=$(echo $ECR_REPOSITORY | grep -oE 'plandex-ecr-repository-[a-zA-Z0-9]+' | sed 's/plandex-ecr-repository-//')

  # Use the extracted tag to find the ECS cluster and service names
  CLUSTER_NAME=$(aws ecs list-clusters | jq -r --arg TAG "$TAG" '.clusterArns[] | select(contains("plandex-ecs-cluster-" + $TAG)) | split("/")[1]')
  SERVICE_NAME=$(aws ecs list-services --cluster "$CLUSTER_NAME" | jq -r --arg TAG "$TAG" '.serviceArns[] | select(contains("plandex-fargate-service-" + $TAG)) | split("/")[1]')

  # Replace placeholders in ecs-container-definitions.json with actual values
  sed -i "s|\${ECR_REPOSITORY_URI}|$ECR_REPOSITORY|g" ecs-container-definitions.json
  sed -i "s|\${IMAGE_TAG}|$IMAGE_TAG|g" ecs-container-definitions.json
  sed -i "s|\${AWS_REGION}|$(aws configure get region)|g" ecs-container-definitions.json

  # Register a new task definition with the new image
  TASK_DEF_ARN=$(aws ecs register-task-definition --family "plandex-task-definition-$TAG" --container-definitions file://ecs-container-definitions.json | jq -r '.taskDefinition.taskDefinitionArn')

  # Update the ECS service to use the new task definition
  aws ecs update-service --cluster "$CLUSTER_NAME" --service "$SERVICE_NAME" --task-definition $TASK_DEF_ARN
}

log "Building and pushing the Docker image to ECR..."
build_and_push_image

log "Building and pushing the Docker image to ECR..."
build_and_push_image

# Deploy or update the CloudFormation stack
log "Deploying or updating the CloudFormation stack..."
deploy_or_update_stack

# Update the ECS service with the new Docker image
log "Updating the ECS service with the new Docker image..."
update_ecs_service

log "Infrastructure deployed successfully"