"""
Visitor counter Lambda for the resume site.

Trigger: Lambda Function URL (GET)
Reads/increments a single item in DynamoDB and returns the new total.

Environment variables (set these in the Lambda console):
  TABLE_NAME      - DynamoDB table name (default: ResumeVisitorCounter)
  ALLOWED_ORIGIN  - your CloudFront domain, e.g. https://d123abc.cloudfront.net
                    (use "*" while testing, then lock it down)
"""

import json
import os
import boto3

dynamodb = boto3.resource("dynamodb")
TABLE_NAME = os.environ.get("TABLE_NAME", "ResumeVisitorCounter")
ALLOWED_ORIGIN = os.environ.get("ALLOWED_ORIGIN", "*")
table = dynamodb.Table(TABLE_NAME)


def lambda_handler(event, context):
    headers = {
        "Content-Type": "application/json",
        "Access-Control-Allow-Origin": ALLOWED_ORIGIN,
    }

    try:
        response = table.update_item(
            Key={"id": "total_visits"},
            UpdateExpression="ADD visit_count :inc",
            ExpressionAttributeValues={":inc": 1},
            ReturnValues="UPDATED_NEW",
        )
        count = int(response["Attributes"]["visit_count"])

        return {
            "statusCode": 200,
            "headers": headers,
            "body": json.dumps({"count": count}),
        }

    except Exception as exc:  # noqa: BLE001 - log and return a generic error
        print(f"visitor_counter error: {exc}")
        return {
            "statusCode": 500,
            "headers": headers,
            "body": json.dumps({"error": "Could not update visitor count"}),
        }
