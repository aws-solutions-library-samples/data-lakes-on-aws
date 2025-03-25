#!/usr/bin/env bash

STORAGE_DEPLOYMENT_INSTANCE=dev
DATASET_DEPLOYMENT_INSTANCE=dev
TEAM_NAME=engineering
#PRINCIPAL=

# echo "Granting Drop on Glue DBs"
# SDLF_ORG=$(aws ssm get-parameter --name "/sdlf/storage/rOrganization/$STORAGE_DEPLOYMENT_INSTANCE" --query "Parameter.Value" --output text)
# for DB in $(aws glue get-databases | jq -r '.[][].Name')
# do
#   case "$DB" in 
#     $SDLF_ORG*) aws lakeformation grant-permissions --principal DataLakePrincipalIdentifier="$PRINCIPAL" --permissions DROP --resource $(echo \'{\"Database\":{\"Name\":\"$DB\"}}\' | tr -d \');; 
#     *) echo "Skipping non-SDLF database" ;; 
#   esac
# done

echo "Fetch KMS keys ARN - SSM parameters won't be available once stacks have been deleted"
declare -a KEYS=("/sdlf/storage/rKMSKey/$STORAGE_DEPLOYMENT_INSTANCE"
                  "/sdlf/dataset/rKMSInfraKey/$DATASET_DEPLOYMENT_INSTANCE"
                  "/sdlf/dataset/rKMSDataKey/$DATASET_DEPLOYMENT_INSTANCE"
                  "/SDLF/KMS/$TEAM_NAME/InfraKeyId"
                )
KEYS_ARN=()
for KEY in "${KEYS[@]}"
do
  echo "Finding $KEY ARN"
  if KEY_ARN=$(aws ssm get-parameter --name "$KEY" --query "Parameter.Value" --output text); then
    KEYS_ARN+=("$KEY_ARN")
  else
    echo "Key does not exist, skipping"
  fi
done

echo "Emptying SDLF buckets..."
declare -a BUCKETS=("/sdlf/storage/rArtifactsBucket/$STORAGE_DEPLOYMENT_INSTANCE"
                    "/sdlf/storage/rRawBucket/$STORAGE_DEPLOYMENT_INSTANCE"
                    "/sdlf/storage/rStageBucket/$STORAGE_DEPLOYMENT_INSTANCE"
                    "/sdlf/storage/rAnalyticsBucket/$STORAGE_DEPLOYMENT_INSTANCE"
                    "/sdlf/storage/rAthenaBucket/$STORAGE_DEPLOYMENT_INSTANCE"
                    "/sdlf/storage/rS3AccessLogsBucket/$STORAGE_DEPLOYMENT_INSTANCE"
                    )
for BUCKET in "${BUCKETS[@]}"
do
  echo "Finding $BUCKET bucket name"
  if S3_BUCKET=$(aws ssm get-parameter --name "$BUCKET" --query "Parameter.Value" --output text); then
    echo "Emptying $S3_BUCKET"
    aws s3 rm "s3://$S3_BUCKET" --recursive
    if [ "$(aws s3api get-bucket-versioning --bucket "$S3_BUCKET" --output text)" == "Enabled" ]; then
      objects_versions=$(aws s3api list-object-versions --bucket "$S3_BUCKET" --output=json --query='{Objects: Versions[].{Key:Key,VersionId:VersionId}}')
      if [ "$(jq -r ".Objects" <<< "$objects_versions")" != "null" ]; then
        aws s3api delete-objects --bucket "$S3_BUCKET" --delete "$objects_versions"
      fi
    fi
  else
    echo "Bucket does not exist, skipping"
  fi
done

echo "Deleting SDLF stacks..."
STACKS=$(aws cloudformation list-stacks --query "StackSummaries[?starts_with(StackName,'sdlf-') && StackStatus!='DELETE_COMPLETE']" | jq -r "sort_by(.CreationTime) | reverse[] | select(.ParentId == null) | .StackName")
for STACK in $STACKS
do
  echo "Deleting stack $STACK"
  aws cloudformation delete-stack --stack-name "$STACK"
done
for STACK in $STACKS
do
  echo "Waiting for $STACK stack delete to complete ..." && aws cloudformation wait stack-delete-complete --stack-name "$STACK" && echo "Finished delete successfully!"
done

echo "Deleting KMS keys"
for KEY_ARN in "${KEYS_ARN[@]}"
do
  echo "Deleting $KEY_ARN"
    aws kms schedule-key-deletion --key-id "$KEY_ARN" --pending-window-in-days 7 2>&1
done
