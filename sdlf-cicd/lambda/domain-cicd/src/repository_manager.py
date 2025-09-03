import json
import logging
import os
import ssl
from urllib.request import HTTPError, Request, URLError, urlopen

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()

ssm_endpoint_url = "https://ssm." + os.getenv("AWS_REGION") + ".amazonaws.com"
ssm = boto3.client("ssm", endpoint_url=ssm_endpoint_url)
codecommit_endpoint_url = "https://codecommit." + os.getenv("AWS_REGION") + ".amazonaws.com"
codecommit = boto3.client("codecommit", endpoint_url=codecommit_endpoint_url)
cloudformation_endpoint_url = "https://cloudformation." + os.getenv("AWS_REGION") + ".amazonaws.com"
cloudformation = boto3.client("cloudformation", endpoint_url=cloudformation_endpoint_url)


def _create_team_repository_cicd_stack(domain, team_name, template_body_url, cloudformation_role):
    response = {}
    cloudformation_waiter_type = None
    stack_name = f"sdlf-cicd-teams-{domain}-{team_name}-repository"
    stack_parameters = [
        {
            "ParameterKey": "pDomain",
            "ParameterValue": domain,
            "UsePreviousValue": False,
        },
        {
            "ParameterKey": "pTeamName",
            "ParameterValue": team_name,
            "UsePreviousValue": False,
        },
    ]
    stack_arguments = dict(
        StackName=stack_name,
        TemplateURL=template_body_url,
        Parameters=stack_parameters,
        Capabilities=[
            "CAPABILITY_AUTO_EXPAND",
        ],
        RoleARN=cloudformation_role,
        Tags=[
            {"Key": "Framework", "Value": "sdlf"},
        ],
    )

    try:
        response = cloudformation.create_stack(**stack_arguments)
        cloudformation_waiter_type = "stack_create_complete"
    except cloudformation.exceptions.AlreadyExistsException:
        try:
            response = cloudformation.update_stack(**stack_arguments)
            cloudformation_waiter_type = "stack_update_complete"
        except ClientError as err:
            if "No updates are to be performed" in err.response["Error"]["Message"]:
                pass
            else:
                raise err

    logger.info("RESPONSE: %s", response)
    return (stack_name, cloudformation_waiter_type)


def _create_codecommit_repositories(
    domain_details, domain, template_cicd_team_repository_url, cloudformation_role, main_repository_prefix
):
    """Create CodeCommit repositories and branches for teams"""
    cloudformation_waiters = {
        "stack_create_complete": [],
        "stack_update_complete": [],
    }
    for team in domain_details["teams"]:
        stack_details = _create_team_repository_cicd_stack(
            domain,
            team,
            template_cicd_team_repository_url,
            cloudformation_role,
        )
        if stack_details[1]:
            cloudformation_waiters[stack_details[1]].append(stack_details[0])

    cloudformation_create_waiter = cloudformation.get_waiter("stack_create_complete")
    cloudformation_update_waiter = cloudformation.get_waiter("stack_update_complete")
    for stack in cloudformation_waiters["stack_create_complete"]:
        cloudformation_create_waiter.wait(StackName=stack, WaiterConfig={"Delay": 30, "MaxAttempts": 10})
    for stack in cloudformation_waiters["stack_update_complete"]:
        cloudformation_update_waiter.wait(StackName=stack, WaiterConfig={"Delay": 30, "MaxAttempts": 10})

    # Create branches for each team repository
    for team in domain_details["teams"]:
        repository_name = f"{main_repository_prefix}{domain}-{team}"
        env_branches = ["dev", "test"]
        for env_branch in env_branches:
            try:
                codecommit.create_branch(
                    repositoryName=repository_name,
                    branchName=env_branch,
                    commitId=codecommit.get_branch(
                        repositoryName=repository_name,
                        branchName="main",
                    )["branch"]["commitId"],
                )
                logger.info(
                    "Branch %s created in repository %s",
                    env_branch,
                    repository_name,
                )
            except codecommit.exceptions.BranchNameExistsException:
                logger.info(
                    "Branch %s already created in repository %s",
                    env_branch,
                    repository_name,
                )


def _create_gitlab_repositories(domain_details, domain, template_cicd_team_repository_url, cloudformation_role):
    """Create GitLab repositories for teams"""
    for team in domain_details["teams"]:
        # Create GitLab repository via API
        # !Sub ${pMainRepositoriesPrefix}${pDomain}-${pTeamName}
        repository = f"sdlf-main-{domain}-{team}"
        gitlab_url = ssm.get_parameter(Name="/SDLF/GitLab/Url", WithDecryption=True)["Parameter"]["Value"]
        gitlab_accesstoken = ssm.get_parameter(Name="/SDLF/GitLab/AccessToken", WithDecryption=True)["Parameter"][
            "Value"
        ]
        namespace_id = ssm.get_parameter(Name="/SDLF/GitLab/NamespaceId", WithDecryption=True)["Parameter"]["Value"]

        url = f"{gitlab_url}api/v4/projects/"
        headers = {"Content-Type": "application/json", "PRIVATE-TOKEN": gitlab_accesstoken}
        data = {
            "name": repository,
            "description": repository,
            "path": repository,
            "namespace_id": namespace_id,
            "initialize_with_readme": "false",
        }
        json_data = json.dumps(data).encode("utf-8")
        req = Request(url, data=json_data, headers=headers, method="POST")
        unverified_context = ssl._create_unverified_context()
        try:
            with urlopen(req, context=unverified_context) as response:
                response_body = response.read().decode("utf-8")
                logger.info(response_body)
        except HTTPError as e:
            logger.warning(
                f"HTTP error occurred: {e.code} {e.reason}. Most likely the repository {repository} already exists"
            )
        except URLError as e:
            logger.error(f"URL error occurred: {e.reason}")

    # Create CloudFormation stacks for GitLab repositories
    cloudformation_waiters = {
        "stack_create_complete": [],
        "stack_update_complete": [],
    }
    for team in domain_details["teams"]:
        stack_details = _create_team_repository_cicd_stack(
            domain,
            team,
            template_cicd_team_repository_url,
            cloudformation_role,
        )
        if stack_details[1]:
            cloudformation_waiters[stack_details[1]].append(stack_details[0])

    cloudformation_create_waiter = cloudformation.get_waiter("stack_create_complete")
    cloudformation_update_waiter = cloudformation.get_waiter("stack_update_complete")
    for stack in cloudformation_waiters["stack_create_complete"]:
        cloudformation_create_waiter.wait(StackName=stack, WaiterConfig={"Delay": 30, "MaxAttempts": 10})
    for stack in cloudformation_waiters["stack_update_complete"]:
        cloudformation_update_waiter.wait(StackName=stack, WaiterConfig={"Delay": 30, "MaxAttempts": 10})


def _create_github_repositories(domain_details, domain, template_cicd_team_repository_url, cloudformation_role):
    """Create GitHub repositories for teams"""
    # GitHub repositories are created via CloudFormation template
    cloudformation_waiters = {
        "stack_create_complete": [],
        "stack_update_complete": [],
    }
    for team in domain_details["teams"]:
        stack_details = _create_team_repository_cicd_stack(
            domain,
            team,
            template_cicd_team_repository_url,
            cloudformation_role,
        )
        if stack_details[1]:
            cloudformation_waiters[stack_details[1]].append(stack_details[0])

    cloudformation_create_waiter = cloudformation.get_waiter("stack_create_complete")
    cloudformation_update_waiter = cloudformation.get_waiter("stack_update_complete")
    for stack in cloudformation_waiters["stack_create_complete"]:
        cloudformation_create_waiter.wait(StackName=stack, WaiterConfig={"Delay": 30, "MaxAttempts": 10})
    for stack in cloudformation_waiters["stack_update_complete"]:
        cloudformation_update_waiter.wait(StackName=stack, WaiterConfig={"Delay": 30, "MaxAttempts": 10})


def create_repositories(
    git_platform,
    domain_details,
    domain,
    template_cicd_team_repository_url,
    cloudformation_role,
    main_repository_prefix=None,
):
    """Create team repositories based on git platform"""
    if git_platform == "CodeCommit":
        _create_codecommit_repositories(
            domain_details, domain, template_cicd_team_repository_url, cloudformation_role, main_repository_prefix
        )
    elif git_platform == "GitHub":
        _create_github_repositories(domain_details, domain, template_cicd_team_repository_url, cloudformation_role)
    elif git_platform == "GitLab":
        _create_gitlab_repositories(domain_details, domain, template_cicd_team_repository_url, cloudformation_role)
    else:
        raise logging.exception("Git provider {} is not supported".format(git_platform))
