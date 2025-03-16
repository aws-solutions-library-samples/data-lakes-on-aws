#!/usr/bin/env bash

CFN_ENDPOINT="https://cloudformation.$AWS_REGION.amazonaws.com"

pip uninstall -y aws-sam-cli && unzip -q aws-sam-cli-linux-x86_64.zip -d sam-installation
./sam-installation/install && sam --version
pip install "cfn-lint<1" cloudformation-cli

# removing everything up to the first hyphen, then anything that isn't a letter/number, and lower-casing what's left
module_name_without_prefix="${SDLF_CONSTRUCT#*-}"
module_name_alnum="${module_name_without_prefix//[^[:alnum:]]/}"
MODULE="${module_name_alnum,,}"
MODULE="DatalakeLibrary" # TODO

mkdir artifacts
zip -r artifacts/datalake_library.zip ./python -x \*__pycache__\*
LAYER_HASH="$(sha256sum artifacts/datalake_library.zip | cut -c1-12)"
aws s3api put-object --bucket "$ARTIFACTS_BUCKET" \
    --key "sdlf/layers/$MODULE-$LAYER_HASH.zip" \
    --body artifacts/datalake_library.zip

STACK_NAME="sdlf-lambdalayers-$MODULE"
aws cloudformation --endpoint-url "$CFN_ENDPOINT" deploy \
    --stack-name "$STACK_NAME" \
    --template-file ./template-lambda-layer.yaml \
    --parameter-overrides \
        pArtifactsBucket="$ARTIFACTS_BUCKET" \
        pLayerName="$MODULE" \
        pGitRef="$LAYER_HASH" \
    --tags Framework=sdlf \
    --capabilities "CAPABILITY_NAMED_IAM" "CAPABILITY_AUTO_EXPAND" || exit 1

echo "done"
