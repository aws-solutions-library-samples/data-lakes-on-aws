# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT

from aws_cdk import (
    Stack,
    CfnParameter,
    CfnOutput,
    aws_glue as glue,
    aws_glue_alpha as glue_a,
    aws_lakeformation as lakeformation,
    aws_ssm as ssm,
)
from constructs import Construct

class SdlfDataset(Stack):

    def __init__(self, scope: Construct, construct_id: str, **kwargs) -> None:
        super().__init__(scope, construct_id, **kwargs)

        run_in_vpc = False

        # using context values would be better(?) for CDK but we haven't decided yet what the story is around ServiceCatalog and CloudFormation modules
        # perhaps both (context values feeding into CfnParameter) would be a nice-enough solution. Not sure though. TODO
        p_pipelinereference = CfnParameter(self, "pPipelineReference",
            type="String",
            default="none",
        )
        p_org = CfnParameter(self, "pOrg",
            description="Name of the organization owning the datalake",
            type="String",
            default="{{resolve:ssm:/SDLF/Misc/pOrg:1}}"
        )
        p_domain = CfnParameter(self, "pDomain",
            description="Data domain name",
            type="String",
            default="{{resolve:ssm:/SDLF/Misc/pDomain:1}}"
        )
        p_environment = CfnParameter(self, "pEnvironment",
            description="Environment name",
            type="String",
            default="{{resolve:ssm:/SDLF/Misc/pEnv:1}}"
        )
        p_teamname = CfnParameter(self, "pTeamName",
            description="Name of the team (all lowercase, no symbols or spaces)",
            type="String",
            allowed_pattern="[a-z0-9]{2,12}"
        )
        p_datasetname = CfnParameter(self, "pDatasetName",
            description="The name of the dataset (all lowercase, no symbols or spaces)",
            type="String",
            allowed_pattern="[a-z0-9]{2,14}"
        )
        p_stagebucket = CfnParameter(self, "pStageBucket",
            description="The stage bucket for the solution",
            type="String",
            default="{{resolve:ssm:/SDLF/S3/StageBucket:2}}"
        )
        p_pipelinedetails = CfnParameter(self, "pPipelineDetails",
            type="String",
            default="""
                {
                    "main": {
                    "B": {
                        "glue_capacity": {
                            "NumberOfWorkers": 10,
                            "WorkerType": "G.1X"
                        },
                        "glue_extra_arguments": {
                            "--enable-auto-scaling": "true"
                        }
                    }
                    }
                }
            """
        )

        ######## GLUE #########
        glue_catalog = glue_a.Database(self, "rGlueDataCatalog",
            database_name=f"{p_org.value_as_string}_{p_domain.value_as_string}_{p_environment.value_as_string}_{p_teamname.value_as_string}_{p_datasetname.value_as_string}_db",
            description=f"{p_teamname.value_as_string} team {p_datasetname.value_as_string} metadata catalog"
        )
        ssm.StringParameter(self, "rGlueDataCatalogSsm",
            description=f"{p_teamname.value_as_string} team {p_datasetname.value_as_string} metadata catalog",
            parameter_name=f"/SDLF/Glue/{p_teamname.value_as_string}/{p_datasetname.value_as_string}/DataCatalog",
            simple_name=False, # parameter name is a token
            string_value=glue_catalog.database_arn
        )

        glue_crawler = glue.CfnCrawler(self, "rGlueCrawler",
            name=f"sdlf-{p_teamname.value_as_string}-{p_datasetname.value_as_string}-post-stage-crawler",
            role=f"{{{{resolve:ssm:/SDLF/IAM/{p_teamname.value_as_string}/CrawlerRoleArn}}}}",
            crawler_security_configuration=f"{{{{resolve:ssm:/SDLF/Glue/{p_teamname.value_as_string}/SecurityConfigurationId:1}}}}",
            database_name=glue_catalog.database_name,
            targets=glue.CfnCrawler.TargetsProperty(
                s3_targets=[glue.CfnCrawler.S3TargetProperty(
                    path=f"s3://{p_stagebucket.value_as_string}/post-stage/{p_teamname.value_as_string}/{p_datasetname.value_as_string}",
                )]
            ),
        )

        ssm.StringParameter(self, "rGlueCrawlerSsm",
            description=f"{p_teamname.value_as_string} team {p_datasetname.value_as_string} Glue crawler",
            parameter_name=f"/SDLF/Glue/{p_teamname.value_as_string}/{p_datasetname.value_as_string}/GlueCrawler",
            simple_name=False, # parameter name is a token
            string_value=glue_crawler.name
        )

#   rGlueDataCatalogLakeFormationTag:
#       Type: AWS::LakeFormation::TagAssociation
#       Properties:
#         Resource:
#           Database:
#             CatalogId: !Ref AWS::AccountId
#             Name: !Ref rGlueDataCatalog
#         LFTags:
#           - CatalogId: !Ref AWS::AccountId
#             TagKey: !Sub "sdlf:team:${pTeamName}"
#             TagValues:
#               - !Sub ${pTeamName}


#   rGlueCrawlerLakeFormationPermissions:
#     Type: AWS::LakeFormation::Permissions
#     Properties:
#       DataLakePrincipal:
#         DataLakePrincipalIdentifier: !Sub "{{resolve:ssm:/SDLF/IAM/${pTeamName}/CrawlerRoleArn}}"
#       Permissions:
#         - CREATE_TABLE
#         - ALTER
#         - DROP
#       Resource:
#         DatabaseResource:
#           Name: !Ref rGlueDataCatalog

  ######## SSM #########

        ssm.StringParameter(self, "rDatasetSsm",
            description=f"Placeholder {p_teamname.value_as_string} {p_datasetname.value_as_string}",
            parameter_name=f"/SDLF/Datasets/{p_teamname.value_as_string}/{p_datasetname.value_as_string}",
            simple_name=False, # parameter name is a token
            string_value=p_pipelinedetails.value_as_string # bit of a hack for datasets lambda
        )

        # CloudFormation Outputs TODO
        CfnOutput(self, "oPipelineReference",
            description="CodePipeline reference this stack has been deployed with",
            value=p_pipelinereference.value_as_string
        )
        CfnOutput(self, "oPipelineTransforms",
            description="Transforms to put in DynamoDB",
            value=p_pipelinedetails.value_as_string
        )
