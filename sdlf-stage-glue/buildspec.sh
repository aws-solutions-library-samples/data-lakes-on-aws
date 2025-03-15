#!/usr/bin/env bash

CFN_ENDPOINT="https://cloudformation.$AWS_REGION.amazonaws.com"

# external dependencies are stored on S3 to avoid getting rate-limited - and also to be nice
deps=(
    "https://github.com/aws/aws-sam-cli/releases/latest/download/aws-sam-cli-linux-x86_64.zip"
)
for u in "${deps[@]}"; do
    aws s3api get-object --bucket "$ARTIFACTS_BUCKET" --key "${u##*/}" "${u##*/}" || {
    curl -L -O "$u"
    aws s3api put-object --bucket "$ARTIFACTS_BUCKET" --key "${u##*/}" --body "${u##*/}"
    }
done

# let's assume we're inside a full sdlf repository clone for the moment (which is true if using sdlf-cicd/deploy.sh)
cp ../sdlf-cicd/template-generic-cfn-template.yaml .
cp ../sdlf-cicd/template-generic-cfn-module.yaml .

pip uninstall -y aws-sam-cli && unzip -q aws-sam-cli-linux-x86_64.zip -d sam-installation
./sam-installation/install && sam --version
pip install "cfn-lint<1" cloudformation-cli

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
    pipeline_template_url=$(aws ssm --endpoint-url "$SSM_ENDPOINT" get-parameter --name "/sdlf/pipeline/main" --query "Parameter.Value" --outp
ut text)
    sed -i "s|{{resolve:ssm:/sdlf/pipeline/main}}|$pipeline_template_url|g" "./$MODULE.yaml"
    sam package --template-file "./$MODULE.yaml" --s3-bucket "$ARTIFACTS_BUCKET" --s3-prefix sdlf --output-template-file template.yaml || exit 1
    TEMPLATE_BASE_FILE_PATH="sdlf/modules/$MODULE"
    aws s3api put-object --bucket "$ARTIFACTS_BUCKET" --key "$TEMPLATE_BASE_FILE_PATH/template.yaml" --body template.yaml || exit 1

    TEMPLATE_URL="https://$ARTIFACTS_BUCKET.s3.$AWS_REGION.amazonaws.com/$TEMPLATE_BASE_FILE_PATH/template.yaml"
    aws cloudformation --endpoint-url "$CFN_ENDPOINT" validate-template --template-url "$TEMPLATE_URL"

    STACK_NAME="sdlf-cfn-module-$MODULE"
    aws cloudformation --endpoint-url "$CFN_ENDPOINT" deploy \
        --stack-name "$STACK_NAME" \
        --template-file ../template-generic-cfn-template.yaml \
        --parameter-overrides \
            pModuleName="$MODULE" \
            pModuleGitRef="main" \
            pModuleS3Url="$TEMPLATE_URL" \
        --tags Framework=sdlf || exit 1
    echo "done"
fi

if [ "$DEPLOYMENT_TYPE" = "cfn-module" ]; then
    # removing everything up to the first hyphen, then anything that isn't a letter/number, and lower-casing what's left
    module_name_without_prefix="${SDLF_CONSTRUCT#*-}"
    module_name_alnum="${module_name_without_prefix//[^[:alnum:]]/}"
    MODULE="${module_name_alnum,,}"

    : "${MODULE_ORG:=awslabs}" "${MODULE_FRAMEWORK:=sdlf}"
    cd src || exit
    sam package --template-file "./$MODULE.yaml" --s3-bucket "$ARTIFACTS_BUCKET" --s3-prefix sdlf --output-template-file template.yaml || exit 1
    python3 ../sam-translate.py --template-file=template.yaml --output-template=translated-template.json

    SSM_ENDPOINT="https://ssm.$AWS_REGION.amazonaws.com"
    TEMPLATE_BASE_FILE_PATH="sdlf/modules/$MODULE"
    aws s3api put-object --bucket "$ARTIFACTS_BUCKET" --key "$TEMPLATE_BASE_FILE_PATH/translated-template.json" --body translated-template.json || exit 1
    TEMPLATE_URL="https://$ARTIFACTS_BUCKET.s3.$AWS_REGION.amazonaws.com/$TEMPLATE_BASE_FILE_PATH/translated-template.json"
    aws cloudformation --endpoint-url "$CFN_ENDPOINT" validate-template --template-url "$TEMPLATE_URL"

    mkdir module
    cd module || exit
    cfn init --artifact-type MODULE --type-name "$MODULE_ORG::$MODULE_FRAMEWORK::$MODULE::MODULE" && rm fragments/sample.json
    cp -i -a ../translated-template.json fragments/
    cfn generate
    zip -q -r "../$MODULE.zip" .rpdk-config fragments/ schema.json

    NEW_MODULE="$(sha256sum "../$MODULE.zip" | cut -c1-12)"
    aws s3api put-object --bucket "$ARTIFACTS_BUCKET" --key "$TEMPLATE_BASE_FILE_PATH-$NEW_MODULE.zip" --body "../$MODULE.zip" || exit 1

    if CURRENT_MODULE=$(aws ssm --endpoint-url "$SSM_ENDPOINT" get-parameter --name "/SDLF/CFN/$MODULE_ORG-$MODULE_FRAMEWORK-$MODULE-MODULE" --query "Parameter.Value" --output text); then
        echo "Current module hash: $CURRENT_MODULE / New module hash: $NEW_MODULE"
        if [ "$NEW_MODULE" == "$CURRENT_MODULE" ]; then
            echo "No change since last build, exiting module creation."
            exit 0
        fi
    fi

    STACK_NAME="sdlf-cfn-module-$MODULE_FRAMEWORK-$MODULE"
    aws cloudformation --endpoint-url "$CFN_ENDPOINT" deploy \
        --stack-name "$STACK_NAME" \
        --template-file ../../template-generic-cfn-module.yaml \
        --parameter-overrides \
            pArtifactsBucket="$ARTIFACTS_BUCKET" \
            pLibraryOrg="$MODULE_ORG" \
            pLibraryFramework="$MODULE_FRAMEWORK" \
            pLibraryModule="$MODULE" \
            pModuleGitRef="$NEW_MODULE" \
        --tags Framework=sdlf || exit 1
    echo "done"
    cd .. && rm -Rf module
fi