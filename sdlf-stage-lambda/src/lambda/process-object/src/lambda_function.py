import json
import os
from pathlib import PurePath

from datalake_library.commons import init_logger
from datalake_library.interfaces.s3_interface import S3Interface
from datalake_library.sdlf import (
    KMSConfiguration,
    S3Configuration,
)

logger = init_logger(__name__)
s3_interface = S3Interface()
s3_prefix = os.environ["S3_PREFIX"]
deployment_instance = os.environ["DEPLOYMENT_INSTANCE"]
storage_deployment_instance = os.environ["STORAGE_DEPLOYMENT_INSTANCE"]


def pull_object_from_s3(bucket, key):
    # Download S3 object locally to /tmp directory
    # s3_interface.download_object returns the local path where the file was saved
    return s3_interface.download_object(bucket, key)


def push_object_to_s3(bucket, file_path):
    # Uploading file to bucket at appropriate path
    # IMPORTANT: Build the output s3_path without the s3://stage-bucket/
    s3_path = f"{s3_prefix}/{deployment_instance}/{PurePath(file_path).name}"
    kms_key = KMSConfiguration(instance=storage_deployment_instance).data_kms_key
    s3_interface.upload_object(file_path, bucket, s3_path, kms_key=kms_key)

    return f"{bucket}{s3_path}"


def transform_object(local_path):
    # Apply business business logic:
    # Below example is opening a JSON file and
    # extracting fields, then saving the file
    # locally and re-uploading to Stage bucket
    def parse(json_data):
        l = []  # noqa: E741
        for d in json_data:
            o = d.copy()
            for k in d:
                if type(d[k]) in [dict, list]:
                    o.pop(k)
            l.append(o)

        return l

    # Reading file locally
    with open(local_path, "r") as raw_file:
        data = raw_file.read()

    json_data = json.loads(data)

    # Saving file locally to /tmp after parsing
    output_path = f"{PurePath(local_path).with_suffix('')}_parsed.json"
    with open(output_path, "w", encoding="utf-8") as write_file:
        json.dump(parse(json_data), write_file, ensure_ascii=False, indent=4)

    return output_path


def lambda_handler(event, context):
    """Calls custom transform developed by user

    Arguments:
        event {dict} -- Dictionary with details on previous processing step
        context {dict} -- Dictionary with details on Lambda context

    Returns:
        {dict} -- Dictionary with Processed Bucket and Key(s)
    """
    try:
        # this default Lambda expects records to be S3 events
        stage_bucket = S3Configuration(instance=storage_deployment_instance).stage_bucket
        for record in event:
            logger.info(f"Processing file: {record['object']['key']} in {record['bucket']['name']}")
            local_path = pull_object_from_s3(record["bucket"]["name"], record["object"]["key"])
            output_path = transform_object(local_path)
            s3_uri = push_object_to_s3(stage_bucket, output_path)
            logger.info(f"Result stored at {s3_uri}")

    except Exception as e:
        logger.error("Fatal error", exc_info=True)
        raise e

    return event
