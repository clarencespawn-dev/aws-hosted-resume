"""
Contact form Lambda for the resume site.

Trigger: Lambda Function URL (POST)
Validates the submitted name/email/message and sends a notification
email to you via Amazon SES, with the visitor's address set as Reply-To
so you can reply directly from your inbox.

Environment variables (set these in the Lambda console):
  SENDER_EMAIL    - a verified SES identity, e.g. clarencepaulus777@gmail.com
  RECIPIENT_EMAIL - where you want to receive messages (can be the same address)
  SES_REGION      - AWS region your SES identity is verified in (e.g. ap-southeast-2)
  ALLOWED_ORIGIN  - your CloudFront domain, e.g. https://d123abc.cloudfront.net
                    (use "*" while testing, then lock it down)
"""

import json
import os
import re
import boto3

SES_REGION = os.environ.get("SES_REGION", "ap-southeast-2")
ses = boto3.client("ses", region_name=SES_REGION)

SENDER = os.environ.get("SENDER_EMAIL")
RECIPIENT = os.environ.get("RECIPIENT_EMAIL")
ALLOWED_ORIGIN = os.environ.get("ALLOWED_ORIGIN", "*")

EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")

CORS_HEADERS = {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": ALLOWED_ORIGIN,
}


def _response(status_code, body):
    return {
        "statusCode": status_code,
        "headers": CORS_HEADERS,
        "body": json.dumps(body),
    }


def lambda_handler(event, context):
    if not SENDER or not RECIPIENT:
        print("contact_form misconfigured: SENDER_EMAIL/RECIPIENT_EMAIL not set")
        return _response(500, {"error": "Contact form is not configured yet"})

    try:
        payload = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _response(400, {"error": "Invalid request body"})

    name = (payload.get("name") or "").strip()[:100]
    email = (payload.get("email") or "").strip()[:200]
    message = (payload.get("message") or "").strip()[:2000]

    if not name or not email or not message:
        return _response(400, {"error": "Name, email, and message are all required"})

    if not EMAIL_RE.match(email):
        return _response(400, {"error": "Please enter a valid email address"})

    try:
        ses.send_email(
            Source=SENDER,
            Destination={"ToAddresses": [RECIPIENT]},
            Message={
                "Subject": {"Data": f"Resume site contact from {name}"},
                "Body": {
                    "Text": {
                        "Data": f"Name: {name}\nEmail: {email}\n\nMessage:\n{message}"
                    }
                },
            },
            ReplyToAddresses=[email],
        )
    except Exception as exc:  # noqa: BLE001 - log and return a generic error
        print(f"contact_form SES error: {exc}")
        return _response(
            502, {"error": "Could not send your message right now, please try again later"}
        )

    return _response(200, {"message": "Message sent successfully"})
