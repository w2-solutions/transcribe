# A stand-in for the AWS CLI, for scripts/tests/release-scripts-test.sh: only the calls publish-mac.sh makes, on a
# local folder (FAKE_AWS_ROOT/<key>, its content type and metadata in <key>.meta.json). No network.
#   FAKE_AWS_FAIL_GET=<key>   get-object of that key writes half the bytes, then fails as a 5xx that outlasted the
#                             retries would (the object itself is there: head-object succeeds)
#   FAKE_AWS_LOG=<file>       one line per call ("<command> <key>")
import json
import os
import shutil
import sys

root = os.environ["FAKE_AWS_ROOT"]
args = sys.argv[1:]
if args and args[0] == "--no-cli-pager":
    args = args[1:]


def opt(name, default=None):
    return args[args.index(name) + 1] if name in args else default


def path(key):
    return os.path.join(root, key)


def meta(key):
    try:
        with open(path(key) + ".meta.json") as f:
            return json.load(f)
    except FileNotFoundError:
        return {"ContentType": "binary/octet-stream", "Metadata": {}}


def log(command, key):
    if os.environ.get("FAKE_AWS_LOG"):
        with open(os.environ["FAKE_AWS_LOG"], "a") as f:
            f.write(f"{command} {key}\n")


def not_found(operation):
    sys.stderr.write(f"An error occurred (404) when calling the {operation} operation: Not Found\n")
    sys.exit(254)


def store(source, key, content_type, metadata):
    os.makedirs(os.path.dirname(path(key)), exist_ok=True)
    shutil.copyfile(source, path(key))
    with open(path(key) + ".meta.json", "w") as f:
        json.dump({"ContentType": content_type, "Metadata": metadata}, f)


if args[:2] == ["s3api", "head-object"]:
    key = opt("--key")
    log("head-object", key)
    if not os.path.isfile(path(key)):
        not_found("HeadObject")
    m = meta(key)
    print(json.dumps({"ContentLength": os.path.getsize(path(key)), "ContentType": m["ContentType"], "Metadata": m["Metadata"]}))
elif args[:2] == ["s3api", "get-object"]:
    key, out = opt("--key"), args[-1]
    log("get-object", key)
    if not os.path.isfile(path(key)):
        sys.stderr.write("An error occurred (NoSuchKey) when calling the GetObject operation: The specified key does not exist.\n")
        sys.exit(254)
    data = open(path(key), "rb").read()
    if os.environ.get("FAKE_AWS_FAIL_GET") == key:
        open(out, "wb").write(data[: len(data) // 2])
        sys.stderr.write("An error occurred (InternalError) when calling the GetObject operation (reached max retries: 2): We encountered an internal error. Please try again.\n")
        sys.exit(254)
    open(out, "wb").write(data)
    print(json.dumps({"ContentLength": len(data)}))
elif args[:2] == ["s3api", "put-object"]:
    key = opt("--key")
    log("put-object", key)
    store(opt("--body"), key, opt("--content-type", "binary/octet-stream"), {})
    print("{}")
elif args[:2] == ["s3", "cp"]:
    source, target = args[2], args[3]
    key = target.split("/", 3)[3]
    log("cp", key)
    store(source, key, opt("--content-type", "binary/octet-stream"), json.loads(opt("--metadata", "{}")))
elif args[:2] == ["s3api", "list-objects-v2"]:
    prefix = opt("--prefix", "")
    log("list-objects-v2", prefix)
    keys = []
    for directory, _, files in os.walk(root):
        for name in files:
            key = os.path.relpath(os.path.join(directory, name), root)
            if not key.endswith(".meta.json") and key.startswith(prefix):
                keys.append(key)
    print("\t".join(sorted(keys)) if keys else "None")
elif args[:2] == ["s3api", "delete-object"]:
    key = opt("--key")
    log("delete-object", key)
    for p in (path(key), path(key) + ".meta.json"):
        if os.path.exists(p):
            os.remove(p)
else:
    sys.stderr.write(f"fake-aws: unsupported call {args}\n")
    sys.exit(2)
