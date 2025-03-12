#!/usr/bin/env bash

deps=(
    "https://github.com/aws/aws-sam-cli/releases/latest/download/aws-sam-cli-linux-x86_64.zip"
    "https://raw.githubusercontent.com/awslabs/aws-serverless-data-lake-framework/crossaccount/sdlf-cicd/template-generic-cfn-module.yaml"
)
for u in "${deps[@]}"; do
    aws s3api get-object --bucket "$ARTIFACTS_BUCKET" --key "${u##*/}" "${u##*/}" || {
    curl -L -O "$u"
    aws s3api put-object --bucket "$ARTIFACTS_BUCKET" --key "${u##*/}" --body "${u##*/}"
    }
done

pip uninstall -y aws-sam-cli && unzip -q aws-sam-cli-linux-x86_64.zip -d sam-installation
./sam-installation/install && sam --version
pip install "cfn-lint<1" cloudformation-cli

CFN_ENDPOINT="https://cloudformation.$AWS_REGION.amazonaws.com"

# deployment-type possible values: cfn-template (current default), cfn-module, cdk-construct
# cfn-template hosts the CloudFormation template.yaml on S3, that can then be used in TemplateURL for AWS::CloudFormation::Stack
# cfn-module creates a CloudFormation Registry module out of template.yaml
# cdk-construct publishes a pip library out of template.py on CodeArtifact
echo "$DEPLOYMENT_TYPE"

if [ "$DEPLOYMENT_TYPE" = "cfn-template" ]; then
    # removing everything up to the first hyphen, then anything that isn't a letter/number, and lower-casing what's left
    module_name_without_prefix="${SDLF_CONSTRUCT#*-}"
    module_name_alnum="${module_name_without_prefix//[^[:alnum:]]/}"
    MODULE="${module_name_alnum,,}"

    cd src || exit
    # sam package doesn't play well with resolve: in TemplateURL fields
    SSM_ENDPOINT="https://ssm.$AWS_REGION.amazonaws.com"
    pipeline_template_url=$(aws ssm --endpoint-url "$SSM_ENDPOINT" get-parameter --name "/sdlf/pipeline/main" --query "Parameter.Value" --output text)
    sed -i "s|{{resolve:ssm:/sdlf/pipeline/main}}|$pipeline_template_url|g" "./$MODULE.yaml"
    sam package --template-file "./$MODULE.yaml" --s3-bucket "$ARTIFACTS_BUCKET" --s3-prefix sdlf --output-template-file template.yaml || exit 1
    TEMPLATE_BASE_FILE_PATH="sdlf/modules/$MODULE"
    aws s3api put-object --bucket "$ARTIFACTS_BUCKET" --key "$TEMPLATE_BASE_FILE_PATH/template.yaml" --body template.yaml || exit 1

    TEMPLATE_URL="https://$ARTIFACTS_BUCKET.s3.$AWS_REGION.amazonaws.com/$TEMPLATE_BASE_FILE_PATH/template.yaml"
    aws cloudformation --endpoint-url "$CFN_ENDPOINT" validate-template --template-url "$TEMPLATE_URL"

    STACK_NAME="sdlf-cfn-module-$MODULE"
    aws cloudformation --endpoint-url "$CFN_ENDPOINT" deploy \
        --stack-name "$STACK_NAME" \
        --template-file ../template-generic-cfn-module.yaml \
        --parameter-overrides \
            pModuleName="$MODULE" \
            pModuleGitRef="main" \
            pModuleS3Url="$TEMPLATE_URL" \
        --tags Framework=sdlf || exit 1
    echo "done"
fi
