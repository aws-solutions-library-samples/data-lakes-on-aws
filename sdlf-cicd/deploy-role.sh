#!/bin/bash

bold=$(tput bold)
underline=$(tput smul)
notunderline=$(tput rmul)
notbold=$(tput sgr0)

die() {
    printf '%s\n' "$1" >&2
    exit 1
}

version () { echo "awssdlf/2.8.0"; }

usage () { echo "
Serverless Data Lake Framework (SDLF) is a collection of infrastructure-as-code artifacts to deploy data architectures on AWS.
This script creates an IAM role with the set of permissions required to deploy the specified SDLF constructs.
This role can be used by CodeBuild projects hosted in the same, or a different AWS account.

Usage: ./deploy-role.sh [-V | --version] [-h | --help] [-p | --profile <aws-profile>] [-b | --codebuild-account-id <account-id>] [-c sdlf-construct1 | --construct sdlf-construct1] [-c sdlf-construct...] <name>

Options
  -V, --version -- Print the SDLF version
  -h, --help -- Show this help message
  -p -- Name of the AWS profile to use
  -b -- AWS account ID of the CodeBuild project
  -c -- Name of the SDLF construct that will be used
  <name> -- Name to uniquely identify this deployment

  ${underline}-c sdlf${notunderline} can be used as a shorthand for "all SDLF constructs"
  ${underline}-c sdlf-stage${notunderline} can be used as a shorthand for "all SDLF Stage constructs"

Examples
  Create an IAM role named sdlf-cicd-codebuild-ACCOUNT_ID-main able to deploy any SDLF construct:
  ${bold}./deploy-role.sh${notbold} ${underline}main${notunderline} ${bold}-c${notbold} ${underline}sdlf${notunderline}

  Create an IAM role named sdlf-cicd-codebuild-ACCOUNT_ID-data-team able to deploy technical catalogs, data processing workflows and consumption tools:
  ${bold}./deploy-role.sh${notbold} ${underline}data-team${notunderline} ${bold}-c${notbold} ${underline}sdlf-dataset${notunderline} ${bold}-c${notbold} ${underline}sdlf-stage${notunderline} ${bold}-c${notbold} ${underline}sdlf-team${notunderline}

More details and examples on https://sdlf.readthedocs.io/en/latest/constructs/cicd/
"; }

pflag=false
rflag=false
bflag=false
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
        -b|--codebuild-account-id)
            if [ "$2" ]; then
                bflag=true;
                CODEBUILD_ACCOUNT_ID=$2
                shift
            else
                die 'ERROR: "--codebuild-account-id" requires a non-empty option argument.'
            fi
            ;;
        --codebuild-account-id=?*)
            bflag=true;
            CODEBUILD_ACCOUNT_ID=${1#*=} # delete everything up to "=" and assign the remainder
            ;;
        --codebuild-account-id=) # handle the case of an empty --codebuild-account-id=
            die 'ERROR: "--codebuild-account-id" requires a non-empty option argument.'
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
        --construct=) # handle the case of an empty --construct=
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

if [ -z ${1+x} ]; then die 'ERROR: "./deploy-role.sh" requires a non-option argument.'; fi

if "$pflag"
then
    echo "using AWS profile $PROFILE..." >&2
fi
if "$rflag"
then
    echo "using AWS region $REGION..." >&2
fi
if ! "$bflag"
then
    echo "CodeBuild project is assumed to be in the same AWS account" >&2
    CODEBUILD_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text ${REGION:+--region "$REGION"} ${PROFILE:+--profile "$PROFILE"})

    CODEBUILD_ROLE=$(aws codebuild batch-get-projects --names "sdlf-cicd-$1" --query "projects[0].serviceRole" --output text ${REGION:+--region "$REGION"} ${PROFILE:+--profile "$PROFILE"} | cut -d'/' -f2)
    CODEBUILD_ROLE_BOOTSTRAP=$(aws codebuild batch-get-projects --names "sdlf-cicd-bootstrap" --query "projects[0].serviceRole" --output text ${REGION:+--region "$REGION"} ${PROFILE:+--profile "$PROFILE"} | cut -d'/' -f2)
else
    if [ -z ${2+x} ]; then die 'ERROR: "./deploy-role.sh" requires a second non-option argument providing the CodeBuild project IAM role name.'; fi
    if [ -z ${3+x} ]; then die 'ERROR: "./deploy-role.sh" requires a third non-option argument providing the boostrap CodeBuild project IAM role name.'; fi

    CODEBUILD_ROLE=$2
    CODEBUILD_ROLE_BOOTSTRAP=$3
fi

STACK_NAME="sdlf-cicd-role-$CODEBUILD_ACCOUNT_ID-$1"
echo "CloudFormation stack name: $STACK_NAME"
aws cloudformation deploy \
    --stack-name "$STACK_NAME" \
    --template-file "$DIRNAME"/template-cicd-generic-role.yaml \
    --parameter-overrides \
        pCodeBuildAccountId="$CODEBUILD_ACCOUNT_ID" \
        pCodeBuildSuffix="$1" \
        pCodeBuildBootstrapRole="$CODEBUILD_ROLE_BOOTSTRAP" \
        pCodeBuildUserRepositoryRole="$CODEBUILD_ROLE" \
    --tags Framework=sdlf \
    --capabilities "CAPABILITY_NAMED_IAM" "CAPABILITY_AUTO_EXPAND" \
    ${REGION:+--region "$REGION"} \
    ${PROFILE:+--profile "$PROFILE"} || exit 1

if "$cflag"
then
    echo "The list ${CONSTRUCTS[*]} will be used in a future release to restrict CodeBuild permissions to the set of permissions required by the constructs it can deploy."
fi
