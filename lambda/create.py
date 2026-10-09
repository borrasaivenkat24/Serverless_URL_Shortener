import json
import os
import random
import string
import boto3

table = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])

def handler(event, context):
    body = json.loads(event.get("body") or "{}")
    url = body.get("url", "")
    if not url.startswith(("http://", "https://")):
        return {"statusCode": 400, "body": json.dumps({"error": "A valid url is required"})}

    code = "".join(random.choices(string.ascii_letters + string.digits, k=6))
    table.put_item(Item={"code": code, "url": url})
    return {"statusCode": 200, "body": json.dumps({"short": code})}