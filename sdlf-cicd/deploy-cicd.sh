#!/bin/bash

bold=$(tput bold)
underline=$(tput smul)
notunderline=$(tput rmul)
notbold=$(tput sgr0)

die() {
    printf '%s\n' "$1" >&2
    exit 1
}

version () { echo "awssdlf/2.9.0"; }

usage () { echo "
Serverless Data Lake Framework (SDLF) is a collection of infrastructure-as-code artifacts to deploy data architectures on AWS.
This script creates a CodeBuild project with the set of permissions required to deploy the specified SDLF constructs.

Usage: ./deploy-cicd.sh [-V | --version] [-h | --help] [-p | --profile <aws-profile>] [-d | --data-account-id <account-id>] [-c sdlf-construct1 | --construct sdlf-construct1] [-c sdlf-construct...] <name>

Options
  -V, --version -- Print the SDLF version
  -h, --help -- Show this help message
  -p -- Name of the AWS profile to use
  -c -- Name of the SDLF construct that will be used
  <name> -- Name to uniquely identify this deployment

  ${underline}-c sdlf${notunderline} can be used as a shorthand for "all SDLF constructs"
  ${underline}-c sdlf-stage${notunderline} can be used as a shorthand for "all SDLF Stage constructs"

Examples
  Create a CodeBuild project named sdlf-main able to deploy any SDLF construct:
  ${bold}./deploy-cicd.sh${notbold} ${underline}sdlf-main${notunderline} ${bold}-c${notbold} ${underline}sdlf${notunderline}

  Create a CodeBuild project named sdlf-data-team able to deploy technical catalogs, data processing workflows and consumption tools:
  ${bold}./deploy-cicd.sh${notbold} ${underline}sdlf-data-team${notunderline} ${bold}-c${notbold} ${underline}sdlf-dataset${notunderline} ${bold}-c${notbold} ${underline}sdlf-stage${notunderline} ${bold}-c${notbold} ${underline}sdlf-team${notunderline}

More details and examples on https://sdlf.readthedocs.io/en/latest/constructs/cicd/
"; }

pflag=false
rflag=false
dflag=false
cflag=false

DIRNAME=$(dirname "$0")

while :
do
    case $1 in
        -h|-\?|--help)
            usage
            exit
            ;;
        -V|--version)
            version
            exit
            ;;
        -p|--profile)
            if [ "$2" ]; then
                pflag=true;
                PROFILE=$2
                shift
            else
                die 'ERROR: "--profile" requires a non-empty option argument.'
            fi
            ;;
        --profile=?*)
            pflag=true;
            PROFILE=${1#*=} # delete everything up to "=" and assign the remainder
            ;;
        --profile=) # handle the case of an empty --profile=
            die 'ERROR: "--profile" requires a non-empty option argument.'
            ;;
        -r|--region)
            if [ "$2" ]; then
                rflag=true;
                REGION=$2
                shift
            else
                die 'ERROR: "--region" requires a non-empty option argument.'
            fi
            ;;
        --region=?*)
            rflag=true;
            REGION=${1#*=} # delete everything up to "=" and assign the remainder
            ;;
        --region=) # handle the case of an empty --region=
            die 'ERROR: "--region" requires a non-empty option argument.'
            ;;
        -d|--data-account-id)
            if [ "$2" ]; then
                dflag=true;
                DATA_ACCOUNT_ID=$2
                shift
            else
                die 'ERROR: "--data-account-id" requires a non-empty option argument.'
            fi
            ;;
        --data-account-id=?*)
            dflag=true;
            DATA_ACCOUNT_ID=${1#*=} # delete everything up to "=" and assign the remainder
            ;;
        --data-account-id=) # handle the case of an empty --data-account-id=
            die 'ERROR: "--data-account-id" requires a non-empty option argument.'
            ;;
        -c|--construct)
            if [ "$2" ]; then
                cflag=true;
                CONSTRUCTS+=("$2")
                shift
            else
                die 'ERROR: "--construct" requires a non-empty option argument.'
            fi
            ;;
        --construct=?*)
            cflag=true;
            CONSTRUCTS+=("${1#*=}") # delete everything up to "=" and assign the remainder
            ;;
        --construct=) # handle the case of an empty --profile=
            die 'ERROR: "--construct" requires a non-empty option argument.'
            ;;
        --) # end of all options
            shift
            break
            ;;
        -?*)
            printf 'WARN: Unknown option (ignored): %s\n' "$1" >&2
            ;;
        *) # default case: no more options, so break out of the loop
            break
    esac

    shift
done

if [ -z ${1+x} ]; then die 'ERROR: "./deploy-cicd.sh" requires a non-option argument.'; fi

if "$pflag"
then
    echo "using AWS profile $PROFILE..." >&2
fi
if "$rflag"
then
    echo "using AWS region $REGION..." >&2
fi
if ! "$dflag"
then
    echo "Data account id not provided, assuming it is the same as the CodeBuild project" >&2
    DATA_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text ${REGION:+--region "$REGION"} ${PROFILE:+--profile "$PROFILE"})
fi

STACK_NAME="sdlf-cicd-$1"
DEPLOY_CODEBUILD_BOOTSTRAP=true
# it is not expected to have that many of these stacks created, so pagination is not handled for now.
stacks=$(aws cloudformation list-stacks --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE --query "StackSummaries[?starts_with(StackName, 'sdlf-cicd-')].StackName" --output text)
for stack in $stacks
do
    if aws cloudformation describe-stack-resource --stack-name "$stack" --logical-resource-id rSdlfBootstrapCodeBuildProject > /dev/null 2>&1
    then
        if [ "$stack" != "$STACK_NAME" ]
        then
            DEPLOY_CODEBUILD_BOOTSTRAP=false
        fi
        echo "SDLF CodeBuild bootstrap project found in stack $stack."
        break
    fi
done

echo "CloudFormation stack name: $STACK_NAME"
aws cloudformation deploy \
    --stack-name "$STACK_NAME" \
    --template-file "$DIRNAME"/template-cicd-generic-git.yaml \
    --parameter-overrides \
        pDataAccountId="$DATA_ACCOUNT_ID" \
        pCodebuildBootstrap="$DEPLOY_CODEBUILD_BOOTSTRAP" \
        pCodeBuildSuffix="$1" \
        pDeploymentType="cfn-template" \
        pTemplatePrefixes="foundations dataset pipeline team" \
    --tags Framework=sdlf \
    --capabilities "CAPABILITY_NAMED_IAM" "CAPABILITY_AUTO_EXPAND" \
    ${REGION:+--region "$REGION"} \
    ${PROFILE:+--profile "$PROFILE"} || exit 1

if ! "$dflag"
then
    CODEBUILD_ROLE=$(aws codebuild batch-get-projects --names "sdlf-cicd-$1" --query "projects[0].serviceRole" --output text ${REGION:+--region "$REGION"} ${PROFILE:+--profile "$PROFILE"} | cut -d'/' -f2)
    CODEBUILD_ROLE_BOOTSTRAP=$(aws codebuild batch-get-projects --names "sdlf-cicd-bootstrap" --query "projects[0].serviceRole" --output text ${REGION:+--region "$REGION"} ${PROFILE:+--profile "$PROFILE"} | cut -d'/' -f2)
    echo "Role names to provide to ./deploy-role.sh:"
    echo "$CODEBUILD_ROLE $CODEBUILD_ROLE_BOOTSTRAP"
fi

if "$cflag"
then
    echo "The list ${CONSTRUCTS[*]} will be used in a future release to restrict CodeBuild permissions to the set of permissions required by the constructs it can deploy."
fi
