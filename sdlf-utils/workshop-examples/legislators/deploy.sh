#!/bin/bash
pflag=false

DIRNAME=$(dirname "$0")

usage () { echo "
    -h -- Opens up this help message
    -p -- Name of the AWS profile to use
"; }
options=':p:h'
while getopts "$options" option
do
    case "$option" in
        p  ) pflag=true; PROFILE=$OPTARG;;
        h  ) usage; exit;;
        \? ) echo "Unknown option: -$OPTARG" >&2; exit 1;;
        :  ) echo "Missing option argument for -$OPTARG" >&2; exit 1;;
        *  ) echo "Unimplemented option: -$OPTARG" >&2; exit 1;;
    esac
done

if "$pflag"
then
    echo "using AWS profile $PROFILE..." >&2
fi
REGION=$(aws configure get region ${PROFILE:+--profile "$PROFILE"})

ARTIFACTS_BUCKET=$(aws --region "$REGION" ssm get-parameter --name "/sdlf/storage/rArtifactsBucket/dev" --query "Parameter.Value" --output text ${PROFILE:+--profile "$PROFILE"})
aws s3 cp "$DIRNAME/scripts/legislators-glue-job.py" "s3://$ARTIFACTS_BUCKET/artifacts/" ${PROFILE:+--profile "$PROFILE"}

mkdir "$DIRNAME"/output

function send_legislators() 
{
  ORIGIN="$DIRNAME/data/"
  
  RAW_BUCKET=$(aws --region "$REGION" ssm get-parameter --name "/sdlf/storage/rRawBucket/dev" --query "Parameter.Value" --output text ${PROFILE:+--profile "$PROFILE"})
  KMS_KEY=$(aws --region "$REGION" ssm get-parameter --name "/sdlf/dataset/rKMSDataKey/dev" --query "Parameter.Value" --output text ${PROFILE:+--profile "$PROFILE"})

  S3_DESTINATION=s3://$RAW_BUCKET/
  COUNT=0
  for FILE in "$ORIGIN"/*.json;
  do
    (( COUNT++ )) || true
    aws s3 cp "$FILE" "${S3_DESTINATION}legislators/" --sse aws:kms --sse-kms-key-id "$KMS_KEY" ${PROFILE:+--profile "$PROFILE"}
    echo "transferred $COUNT files"
  done
}

VPC_SUPPORT=$(aws --region "$REGION" ssm get-parameter --name "/SDLF/VPC/Enabled" --query "Parameter.Value" --output text ${PROFILE:+--profile "$PROFILE"} 2>/dev/null)
if [ -z "$VPC_SUPPORT" ]
then
  aws --region "$REGION" ssm put-parameter --name "/SDLF/VPC/Enabled" --value "false" --type String ${PROFILE:+--profile "$PROFILE"}
fi

aws cloudformation package --template-file "$DIRNAME"/scripts/legislators-glue-job.yaml \
  --s3-bucket "$ARTIFACTS_BUCKET" \
  ${PROFILE:+--profile "$PROFILE"} \
  --output-template-file "$DIRNAME"/output/packaged-template.yaml

STACK_NAME="sdlf-legislators-glue-job"
aws cloudformation deploy \
    --s3-bucket "$ARTIFACTS_BUCKET" --s3-prefix sdlf-utils \
    --stack-name "$STACK_NAME" \
    --template-file "$DIRNAME"/output/packaged-template.yaml \
    --tags Framework=sdlf \
    --capabilities "CAPABILITY_NAMED_IAM" "CAPABILITY_AUTO_EXPAND" \
    --region "$REGION" \
    ${PROFILE:+--profile "$PROFILE"} || exit 1

send_legislators
