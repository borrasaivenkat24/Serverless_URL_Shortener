import os
import boto3

table = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])

def handler(event, context):
    code = event["pathParameters"]["code"]
    item = table.get_item(Key={"code": code}).get("Item")
    if not item:
        return {"statusCode": 404, "body": "Not found"}
    return {"statusCode": 302, "headers": {"Location": item["url"]}, "body": ""}