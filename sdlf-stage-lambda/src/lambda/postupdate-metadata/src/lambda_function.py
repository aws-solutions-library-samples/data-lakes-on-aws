import os

from datalake_library.commons import init_logger
from datalake_library.sdlf import PipelineExecutionHistoryAPI


class MapPartialFailureException(Exception):
    pass


logger = init_logger(__name__)
deployment_instance = os.environ["DEPLOYMENT_INSTANCE"]
peh_table_instance = os.environ["DATASET_DEPLOYMENT_INSTANCE"]
manifests_table_instance = os.environ["DATASET_DEPLOYMENT_INSTANCE"]


def lambda_handler(event, context):
    """Updates the S3 objects metadata catalog

    Arguments:
        event {dict} -- Dictionary with details on previous processing step
        context {dict} -- Dictionary with details on Lambda context

    Returns:
        {dict} -- Dictionary with outcome of the process
    """
    try:
        logger.info("Initializing Octagon client")
        component = context.function_name.split("-")[-2].title()
        pipeline_execution = PipelineExecutionHistoryAPI(
            run_in_context="LAMBDA",
            region=os.getenv("AWS_REGION"),
            peh_table_instance=peh_table_instance,
            manifests_table_instance=manifests_table_instance,
        )
        peh_id = event["peh_id"]
        pipeline_execution.retrieve_pipeline_execution(peh_id)

        any_failure = False
        for record in event["map_output"]:
            if not record:
                any_failure = True
                break

        if not any_failure:
            pipeline_execution.update_pipeline_execution(
                status=f"{deployment_instance} {component} Processing", component=component
            )
            pipeline_execution.end_pipeline_execution_success()
        else:
            raise MapPartialFailureException("Failure: Processing failed for one or more record")

    except MapPartialFailureException:
        # this exception is caught in the state machine
        pipeline_execution.end_pipeline_execution_failed(
            component=component,
            issue_comment=f"{deployment_instance} {component} Processing failed for one or more record",
        )
        raise
    except Exception as e:
        logger.error("Fatal error", exc_info=True)
        pipeline_execution.end_pipeline_execution_failed(
            component=component, issue_comment=f"{deployment_instance} {component} Error: {repr(e)}"
        )
        raise e
